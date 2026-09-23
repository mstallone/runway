import Foundation

@MainActor
final class MuseProvider: ProviderRuntime {
    let provider = Provider(
        id: "muse",
        displayName: "Muse",
        icon: .providerMark("muse"),
        links: [
            ProviderLink(label: "Dashboard", url: "https://dev.meta.ai"),
            ProviderLink(label: "Usage", url: "https://dev.meta.ai/usage/")
        ]
    )

    let authStore: MuseAuthStore
    let usageClient: MuseUsageClient
    let logUsageScanner: MuseLogUsageScanner
    let now: @Sendable () -> Date
    let pricing: @Sendable () async -> ModelPricing

    private let localSourceNote = "From your Muse logs (estimated)"

    /// A provider floor applies to automatic and manual reads. Local history still refreshes.
    static let minimumRefreshInterval: TimeInterval = 15 * 60
    private var sessionToken: String?
    private var rejectedTokens: Set<String> = []
    private var lastGood: ProviderSnapshot?
    private var cachedSubscription: ProviderSnapshot?
    private var nextFetchAt: Date?
    private var rateLimitedUntil: Date?
    private var refreshTask: Task<ProviderSnapshot, Never>?

    init(
        authStore: MuseAuthStore = MuseAuthStore(),
        usageClient: MuseUsageClient = MuseUsageClient(),
        logUsageScanner: MuseLogUsageScanner = MuseLogUsageScanner(),
        now: @escaping @Sendable () -> Date = Date.init,
        pricing: @escaping @Sendable () async -> ModelPricing = ModelPricingStore.livePricing
    ) {
        self.authStore = authStore
        self.usageClient = usageClient
        self.logUsageScanner = logUsageScanner
        self.now = now
        self.pricing = pricing
    }

    var widgetDescriptors: [WidgetDescriptor] {
        [
            .percent(
                id: "muse.session",
                provider: provider,
                title: "Five-Hour Usage",
                metricLabel: "Five-Hour Usage",
                isSessionWindow: true
            )
            .exportingLimit("session", unit: "percent"),
            .percent(
                id: "muse.weekly",
                provider: provider,
                title: "Weekly Usage",
                metricLabel: "Weekly Usage"
            )
            .exportingLimit("weekly", unit: "percent"),
            .usageTrend(provider: provider)
                .exportingHistory(
                    scope: .machineLocal,
                    estimatedCost: true,
                    sourceNote: localSourceNote
                )
        ] + WidgetDescriptor.spendTiles(provider: provider)
    }

    func hasLocalCredentials() async -> Bool {
        // Detection inspects cookie metadata and local logs, without requesting a secret.
        await loadOffMainActor { [authStore, logUsageScanner] in
            authStore.hasCredentialFootprint() || logUsageScanner.hasSessionFootprint()
        }
    }

    func refresh() async -> ProviderSnapshot {
        if let refreshTask { return await refreshTask.value }
        let task = Task { await refreshOnce() }
        refreshTask = task
        defer { refreshTask = nil }
        return await withTaskCancellationHandler {
            await task.value
        } onCancel: {
            task.cancel()
        }
    }

    private func refreshOnce() async -> ProviderSnapshot {
        let refreshedAt = now()
        let pricingSnapshot = await pricing()
        async let localScanTask = logUsageScanner.scan(now: refreshedAt, pricing: pricingSnapshot)
        let subscription = await refreshSubscription(at: refreshedAt)
        return finishing(subscription, scan: await localScanTask, now: refreshedAt)
    }

    private func refreshSubscription(at now: Date) async -> ProviderSnapshot {
        do {
            let allowInteraction = ProviderRefreshContext.isManual
            let session = try await loadOffMainActor { [authStore, rejectedTokens] in
                try authStore.loadSession(allowInteraction: allowInteraction, excludingTokens: rejectedTokens)
            }
            if sessionToken != session.token {
                clearSubscription()
                sessionToken = session.token
            }
            if let nextFetchAt, now < nextFetchAt, let cachedSubscription {
                return cachedSubscription
            }
            // Failed reads also obey the floor; menu clicks cannot create a request storm.
            nextFetchAt = now.addingTimeInterval(Self.minimumRefreshInterval)
            let response = try await usageClient.fetchUsage(sessionToken: session.token)
            if response.statusCode == 401 || response.statusCode == 403
                || (300..<400).contains(response.statusCode) {
                rejectedTokens.insert(session.token)
                clearSubscription()
                AppLog.info(LogTag.auth("muse"), "Meta rejected a session from \(session.browserName); trying another profile")
                return await refreshSubscription(at: now)
            }
            if response.statusCode == 429 {
                let seconds = max(
                    Self.minimumRefreshInterval,
                    Double(ClaudeUsageMapper.parseRetryAfterSeconds(response, now: now) ?? 0)
                )
                rateLimitedUntil = now.addingTimeInterval(seconds)
                nextFetchAt = rateLimitedUntil
                throw MuseUsageError.requestFailed(429)
            }
            guard (200..<300).contains(response.statusCode) else {
                throw MuseUsageError.requestFailed(response.statusCode)
            }
            let mapped = try MuseUsageMapper.map(response.body)
            let snapshot = ProviderSnapshot.make(
                provider: provider, plan: mapped.plan, lines: mapped.lines,
                refreshedAt: mapped.observedAt.map { min($0, now) } ?? now
            )
            AppLog.info(LogTag.auth("muse"), "subscription usage loaded from \(session.browserName)")
            lastGood = snapshot
            cachedSubscription = snapshot
            rateLimitedUntil = nil
            return snapshot
        } catch {
            AppLog.warn(LogTag.auth("muse"), "dashboard usage unavailable: \(error.localizedDescription)")
            if let authError = error as? MuseAuthError {
                if authError == .notLoggedIn || authError == .sessionExpired {
                    clearSubscription()
                }
                // Hide meters while credentials are unreadable, but retain the session-bound
                // cache and cooldown. They are reused only after the same cookie is verified;
                // a different cookie clears them before any cache hit or network request.
                if authError == .keychainConnectRequired {
                    return ProviderSnapshot.connectPrompt(provider: provider, error: authError)
                }
                return ProviderSnapshot.error(provider: provider, error: authError)
            }
            let snapshot: ProviderSnapshot
            if var stale = lastGood {
                stale.warning = "Last reported usage: " + error.localizedDescription
                stale.warningAction = .wait
                stale.loginRequired = nil
                snapshot = stale
            } else {
                snapshot = ProviderSnapshot.error(provider: provider, error: error)
            }
            cachedSubscription = snapshot
            return snapshot
        }
    }

    private func clearSubscription() {
        sessionToken = nil
        lastGood = nil
        cachedSubscription = nil
        nextFetchAt = nil
        rateLimitedUntil = nil
    }

    /// Attach local journals onto whatever the dashboard read produced. Spend still loads when meters
    /// cannot (Connect, 429 with no last-good, expired session) as long as the logs have usage.
    private func finishing(
        _ snapshot: ProviderSnapshot,
        scan: LogUsageScan?,
        now: Date
    ) -> ProviderSnapshot {
        guard let scan else { return snapshot }

        let meters = snapshot.lines.filter { !$0.isError && !$0.isConnectPrompt }
        var lines = meters
        SpendTileMapper.appendTokenUsage(
            scan.series,
            to: &lines,
            now: now,
            unknownModelsByDay: scan.unknownModelsByDay,
            modelUsage: scan.modelUsage,
            modelSourceNote: localSourceNote
        )
        SpendTileMapper.appendUsageTrend(
            scan.series,
            to: &lines,
            now: now,
            note: localSourceNote
        )
        guard !lines.isEmpty else { return snapshot }

        let isConnectPrompt = snapshot.lines.contains(where: \.isConnectPrompt)
            || snapshot.warningIsConnectPrompt == true
        let rateLimited = rateLimitedUntil.map { now < $0 } == true
        let lostMeters = meters.isEmpty && (snapshot.lines.contains(where: \.isError) || isConnectPrompt)
        if lostMeters {
            AppLog.warn(
                LogTag.plugin("muse"),
                "subscription meters unavailable; showing local Muse history: \(snapshot.warning ?? museErrorText(snapshot) ?? "unknown")"
            )
        }
        MetricLine.appendNoDataIfNeeded(&lines)
        let warning: String?
        let warningAction: ProviderSnapshot.WarningAction?
        if lostMeters, rateLimited {
            warning = "Meta dashboard updates are temporarily rate limited. Runway will retry after the cooldown."
            warningAction = .wait
        } else if lostMeters {
            warning = isConnectPrompt
                ? MuseAuthError.keychainConnectRequired.localizedDescription
                : "Subscription meters unavailable: \(museErrorText(snapshot) ?? snapshot.warning ?? "")"
            warningAction = snapshot.warningAction
        } else {
            warning = snapshot.warning
            warningAction = snapshot.warningAction
        }
        return ProviderSnapshot.make(
            provider: provider,
            plan: snapshot.plan,
            lines: lines,
            refreshedAt: snapshot.refreshedAt,
            usageHistory: ProviderUsageHistory(
                series: scan.series,
                modelUsage: scan.modelUsage,
                unknownModelsByDay: scan.unknownModelsByDay
            ),
            warning: warning,
            warningAction: warningAction,
            warningIsConnectPrompt: isConnectPrompt ? true : snapshot.warningIsConnectPrompt,
            loginRequired: snapshot.loginRequired
        )
    }

    private func museErrorText(_ snapshot: ProviderSnapshot) -> String? {
        snapshot.lines.compactMap { line -> String? in
            guard case .badge(_, let text, _, _) = line else { return nil }
            return text
        }.first
    }
}
