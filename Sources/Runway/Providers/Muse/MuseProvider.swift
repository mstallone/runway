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

        let auth: MuseAuth
        switch load {
        case .token(let loaded):
            auth = loaded
        case .connectRequired:
            return ProviderSnapshot.connectPrompt(provider: provider, error: MuseAuthError.keychainConnectRequired)
        case .keychainPermissionRequired:
            return ProviderSnapshot.error(provider: provider, error: MuseAuthError.keychainPermissionRequired)
        case .unreadable:
            return ProviderSnapshot.error(provider: provider, error: MuseAuthError.credentialStoreUnreadable)
        case .invalid:
            return ProviderSnapshot.error(provider: provider, error: MuseAuthError.invalidCredentialData)
        case .none:
            return ProviderSnapshot.error(provider: provider, error: MuseAuthError.notLoggedIn)
        }

        do {
            let response = try await usageClient.fetchKey(accessToken: auth.accessToken)
            switch response.statusCode {
            case 200..<300:
                let mapped = try MuseUsageMapper.map(response.body)
                return ProviderSnapshot.make(
                    provider: provider,
                    plan: mapped.plan,
                    lines: mapped.lines,
                    refreshedAt: now()
                )
            case 401, 403:
                throw MuseAuthError.sessionExpired
            default:
                throw MuseUsageError.requestFailed(response.statusCode)
            }
        } catch {
            return ProviderSnapshot.error(provider: provider, error: error)
        }
    }
}
