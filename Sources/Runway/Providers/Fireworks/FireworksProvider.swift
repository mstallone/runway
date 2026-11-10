import Foundation

@MainActor
final class FireworksProvider: ProviderRuntime {
    let provider = Provider(
        id: "fireworks",
        displayName: "Fireworks",
        icon: .providerMark("fireworks"),
        links: [
            ProviderLink(label: "Usage", url: "https://fireworks.ai/account/usage"),
            ProviderLink(label: "Status", url: "https://status.fireworks.ai/")
        ]
    )

    let authStore: FireworksAuthStore
    let usageClient: FireworksUsageClient
    let now: @Sendable () -> Date
    /// The account discovered for a key that came without one, so discovery runs once per key.
    private var discoveredAccount: (apiKey: String, accountID: String)?

    init(
        authStore: FireworksAuthStore = FireworksAuthStore(),
        usageClient: FireworksUsageClient = FireworksUsageClient(),
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.authStore = authStore
        self.usageClient = usageClient
        self.now = now
    }

    var widgetDescriptors: [WidgetDescriptor] {
        [
            .boundedDollars(id: "fireworks.monthlySpend", provider: provider, title: "Monthly Spend",
                            metricLabel: "Monthly Spend", limit: 100, limitNoun: "limit")
                .exportingLimit("monthlySpend", unit: "usd")
        ]
    }

    func hasLocalCredentials() async -> Bool {
        // Same sources as `refresh()`. A protected Keychain item counts too — it is a real login even
        // though only a manual refresh may ask the user to approve reading it.
        await loadOffMainActor { [authStore] in authStore.loadCredentials() } != .none
    }

    func refresh() async -> ProviderSnapshot {
        // A manual refresh may raise the Keychain approval prompt; automatic refreshes stay prompt-free.
        let allowInteraction = ProviderRefreshContext.isManual
        let load = await loadOffMainActor { [authStore] in
            authStore.loadCredentials(allowKeychainInteraction: allowInteraction)
        }
        let auth: FireworksAuth
        switch load {
        case .auth(let loaded):
            auth = loaded
        case .connectRequired:
            return ProviderSnapshot.connectPrompt(provider: provider, error: FireworksAuthError.keychainConnectRequired)
        case .keychainPermissionRequired:
            return ProviderSnapshot.error(provider: provider, error: FireworksAuthError.keychainPermissionRequired)
        case .unreadable:
            return ProviderSnapshot.error(provider: provider, error: FireworksAuthError.credentialStoreUnreadable)
        case .none:
            return ProviderSnapshot.error(provider: provider, error: FireworksAuthError.notLoggedIn)
        }

        do {
            let accountID = try await resolveAccountID(auth)
            let response = try await send { try await usageClient.fetchQuotas(apiKey: auth.apiKey, accountID: accountID) }
            let refreshedAt = now()
            let line = try FireworksUsageMapper.monthlySpendLine(from: response.body, now: refreshedAt)
            return ProviderSnapshot.make(provider: provider, plan: nil, lines: [line], refreshedAt: refreshedAt)
        } catch {
            AppLog.warn(LogTag.plugin("fireworks"), "refresh failed: \(error.localizedDescription)")
            return ProviderSnapshot.error(provider: provider, error: error)
        }
    }

    private func resolveAccountID(_ auth: FireworksAuth) async throws -> String {
        if let accountID = auth.accountID { return accountID }
        if let discoveredAccount, discoveredAccount.apiKey == auth.apiKey {
            return discoveredAccount.accountID
        }
        let response = try await send { try await usageClient.fetchAccounts(apiKey: auth.apiKey) }
        guard let accountID = FireworksUsageMapper.soleAccountID(from: response.body) else {
            throw FireworksAuthError.accountUnknown
        }
        discoveredAccount = (auth.apiKey, accountID)
        return accountID
    }

    /// Run one request and triage it: 401/403 is a rejected key, any other non-2xx a request failure,
    /// and a transport error a connection failure.
    private func send(_ call: () async throws -> HTTPResponse) async throws -> HTTPResponse {
        let response: HTTPResponse
        do {
            response = try await call()
        } catch let error as FireworksUsageError {
            throw error
        } catch {
            throw FireworksUsageError.connectionFailed
        }
        try ProviderAuthRetry.requireSuccess(
            response,
            authExpired: FireworksAuthError.invalidKey,
            requestFailed: { FireworksUsageError.requestFailed($0) }
        )
        return response
    }
}
