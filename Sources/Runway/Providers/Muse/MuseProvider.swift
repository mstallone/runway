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
    let now: @Sendable () -> Date

    /// `/muse-code/key` mints a Model API key. Polling it every refresh cycle trips Meta's rate
    /// limit and can fail Muse Code's own `credential.refresh`. On 429, serve last-good meters and
    /// skip the network until this cooldown ends.
    private var lastGood: (usage: MuseMappedUsage, refreshedAt: Date, accessToken: String)?
    private var rateLimitedUntil: Date?
    static let rateLimitCooldown: TimeInterval = 15 * 60

    init(
        authStore: MuseAuthStore = MuseAuthStore(),
        usageClient: MuseUsageClient = MuseUsageClient(),
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.authStore = authStore
        self.usageClient = usageClient
        self.now = now
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
            .exportingLimit("weekly", unit: "percent")
        ]
    }

    func hasLocalCredentials() async -> Bool {
        // Same sources as `refresh()`: the Muse Keychain item, then a legacy auth.json access token.
        // A protected Keychain item counts — only a manual refresh may ask to load it.
        await loadOffMainActor { [authStore] in authStore.hasCredentialFootprint() }
    }

    func refresh() async -> ProviderSnapshot {
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
            if let until = rateLimitedUntil, now() < until {
                AppLog.info(LogTag.auth("muse"), "mint endpoint cooldown; skipping network")
                return rateLimitedSnapshot(retryAfterSeconds: Int(ceil(until.timeIntervalSince(now()))))
            }
            return await fetchSnapshot(auth: auth, allowInteraction: allowInteraction, allowRetry: true)
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
        allowRetry: Bool
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
                            allowRetry: false
                        )
                    }
                }
                throw MuseAuthError.sessionExpired
            }
            if status == 429 {
                let retryAfter = retryAfterSeconds(from: response)
                rateLimitedUntil = now().addingTimeInterval(TimeInterval(retryAfter))
                AppLog.warn(LogTag.auth("muse"), "mint endpoint rate-limited; backing off \(retryAfter)s")
                return rateLimitedSnapshot(retryAfterSeconds: retryAfter)
            }
            guard (200..<300).contains(status) else {
                throw MuseUsageError.requestFailed(status)
            }
            let mapped = try MuseUsageMapper.map(response.body)
            let refreshedAt = now()
            lastGood = (mapped, refreshedAt, auth.accessToken)
            rateLimitedUntil = nil
            return ProviderSnapshot.make(
                provider: provider,
                plan: mapped.plan,
                lines: mapped.lines,
                refreshedAt: refreshedAt
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
}
