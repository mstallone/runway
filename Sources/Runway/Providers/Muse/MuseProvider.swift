import Foundation

@MainActor
final class MuseProvider: ProviderRuntime {
    let provider = Provider(
        id: "muse",
        displayName: "Muse",
        icon: .providerMark("muse"),
        links: [
            ProviderLink(label: "Dashboard", url: "https://dev.meta.ai"),
            ProviderLink(label: "Usage", url: "https://accountscenter.meta.com/muse_code")
        ]
    )

    let authStore: MuseAuthStore
    let usageClient: MuseUsageClient
    let logUsageScanner: MuseLogUsageScanner
    let now: @Sendable () -> Date
    let pricing: @Sendable () async -> ModelPricing

    private let localSourceNote = "From your Muse logs (estimated)"

    /// `/muse-code/key` mints a Model API key. Polling it every refresh cycle trips Meta's rate
    /// limit and can fail Muse Code's own `credential.refresh`. On 429, serve last-good meters and
    /// skip the network until this cooldown ends.
    private var lastGood: (usage: MuseMappedUsage, refreshedAt: Date, accessToken: String)?
    private var rateLimitedUntil: Date?
    static let rateLimitCooldown: TimeInterval = 15 * 60

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
        // Same sources as `refresh()`: the Muse Keychain item, a legacy auth.json access token, or
        // local session journals. A protected Keychain item counts — only a manual refresh may ask
        // to load it.
        await loadOffMainActor { [authStore, logUsageScanner] in
            authStore.hasCredentialFootprint() || logUsageScanner.hasSessionFootprint()
        }
    }

    func refresh() async -> ProviderSnapshot {
        let refreshedAt = now()
        let pricingSnapshot = await pricing()
        async let localScanTask = logUsageScanner.scan(now: refreshedAt, pricing: pricingSnapshot)
        let subscription = await refreshSubscription(at: refreshedAt)
        return finishing(subscription, scan: await localScanTask, now: refreshedAt)
    }

    private func refreshSubscription(at now: Date) async -> ProviderSnapshot {
        let allowInteraction = ProviderRefreshContext.isManual
        let load = await loadOffMainActor { [authStore] in
            authStore.loadCredentials(allowKeychainInteraction: allowInteraction)
        }

        switch load {
        case .token(let auth):
            if lastGood?.accessToken != auth.accessToken {
                lastGood = nil
                rateLimitedUntil = nil
            }
            if let until = rateLimitedUntil, now < until {
                AppLog.info(LogTag.auth("muse"), "mint endpoint cooldown; skipping network")
                return rateLimitedSnapshot(retryAfterSeconds: Int(ceil(until.timeIntervalSince(now))))
            }
            return await fetchSnapshot(auth: auth, allowInteraction: allowInteraction, allowRetry: true, now: now)
        case .connectRequired:
            return ProviderSnapshot.connectPrompt(provider: provider, error: MuseAuthError.keychainConnectRequired)
        case .keychainPermissionRequired:
            return ProviderSnapshot.error(provider: provider, error: MuseAuthError.keychainPermissionRequired)
        case .unreadable:
            return ProviderSnapshot.error(provider: provider, error: MuseAuthError.credentialStoreUnreadable)
        case .invalid:
            lastGood = nil
            rateLimitedUntil = nil
            return ProviderSnapshot.error(provider: provider, error: MuseAuthError.invalidCredentialData)
        case .none:
            lastGood = nil
            rateLimitedUntil = nil
            return ProviderSnapshot.error(provider: provider, error: MuseAuthError.notLoggedIn)
        }
    }

    private func fetchSnapshot(
        auth: MuseAuth,
        allowInteraction: Bool,
        allowRetry: Bool,
        now: Date
    ) async -> ProviderSnapshot {
        do {
            let response = try await usageClient.fetchKey(accessToken: auth.accessToken)
            let status = MuseUsageMapper.effectiveStatus(of: response)
            if status == 401 || status == 403 {
                if allowRetry {
                    let reloaded = await loadOffMainActor { [authStore] in
                        authStore.loadCredentials(allowKeychainInteraction: allowInteraction)
                    }
                    if case .token(let latest) = reloaded, latest.accessToken != auth.accessToken {
                        AppLog.info(LogTag.auth("muse"), "access token rotated locally; retrying mint")
                        return await fetchSnapshot(
                            auth: latest,
                            allowInteraction: allowInteraction,
                            allowRetry: false,
                            now: now
                        )
                    }
                }
                throw MuseAuthError.sessionExpired
            }
            if status == 429 {
                let retryAfter = retryAfterSeconds(from: response)
                rateLimitedUntil = now.addingTimeInterval(TimeInterval(retryAfter))
                AppLog.warn(LogTag.auth("muse"), "mint endpoint rate-limited; backing off \(retryAfter)s")
                return rateLimitedSnapshot(retryAfterSeconds: retryAfter)
            }
            guard (200..<300).contains(status) else {
                throw MuseUsageError.requestFailed(status)
            }
            let mapped = try MuseUsageMapper.map(response.body)
            lastGood = (mapped, now, auth.accessToken)
            rateLimitedUntil = nil
            return ProviderSnapshot.make(
                provider: provider,
                plan: mapped.plan,
                lines: mapped.lines,
                refreshedAt: now
            )
        } catch {
            return ProviderSnapshot.error(provider: provider, error: error)
        }
    }

    private func rateLimitedSnapshot(retryAfterSeconds: Int) -> ProviderSnapshot {
        if let lastGood {
            return ProviderSnapshot.make(
                provider: provider,
                plan: lastGood.usage.plan,
                lines: lastGood.usage.lines,
                refreshedAt: lastGood.refreshedAt,
                warning: rateLimitedWarning(retryAfterSeconds: retryAfterSeconds),
                warningAction: .wait
            )
        }
        return ProviderSnapshot.error(provider: provider, error: MuseUsageError.requestFailed(429))
    }

    /// Attach local journals onto whatever the mint path produced. Spend still loads when meters
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
        let rateLimited = museErrorText(snapshot) == MuseUsageError.requestFailed(429).errorDescription
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
            warning = "Updates blocked by Meta. Be patient — manual refreshes will make it worse."
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
            warningIsConnectPrompt: isConnectPrompt ? true : snapshot.warningIsConnectPrompt
        )
    }

    private func rateLimitedWarning(retryAfterSeconds: Int) -> String {
        let minutes = max(1, Int(ceil(Double(retryAfterSeconds) / 60)))
        return "Updates blocked by Meta. Be patient — manual refreshes will make it worse. Retrying in ~\(minutes)m."
    }

    private func retryAfterSeconds(from response: HTTPResponse) -> Int {
        if let raw = response.header("retry-after")?.trimmingCharacters(in: .whitespacesAndNewlines),
           let seconds = Int(raw),
           seconds > 0
        {
            return min(seconds, 60 * 60)
        }
        return Int(Self.rateLimitCooldown)
    }

    private func museErrorText(_ snapshot: ProviderSnapshot) -> String? {
        snapshot.lines.compactMap { line -> String? in
            guard case .badge(_, let text, _, _) = line else { return nil }
            return text
        }.first
    }
}
