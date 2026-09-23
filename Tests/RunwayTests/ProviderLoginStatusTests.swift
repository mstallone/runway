import XCTest
@testable import Runway

@MainActor
final class ProviderLoginStatusTests: XCTestCase {
    func testTypedLoginFailuresExcludeNetworkAndSubscriptionErrors() {
        let failures: [Error] = [ClaudeAuthError.loginRenewalRequired, CodexAuthError.notLoggedIn,
                                 CursorAuthError.loginRenewalRequired, CopilotAuthError.tokenInvalid,
                                 AntigravityError.authExpired, GrokAuthError.expired,
                                 KimiAuthError.sessionExpired, MuseAuthError.sessionExpired,
                                 SakanaAuthError.invalidCookie, DevinAuthError.notLoggedIn,
                                 ZAIAuthError.invalidKey, OpenRouterAuthError.invalidKey,
                                 OpenCodeUsageError.unauthorized]
        for failure in failures { XCTAssertTrue(ProviderLoginStatus.requiresLogin(failure)) }
        for failure: Error in [URLError(.notConnectedToInternet), AntigravityError.unavailable,
                               OpenCodeUsageError.noGoSubscription, OpenCodeUsageError.requestFailed(500)] {
            XCTAssertFalse(ProviderLoginStatus.requiresLogin(failure))
        }
    }

    func testLoginStateTracksRefreshFailuresRecoveryAndPartialData() async {
        let provider = Provider(id: "login-test", displayName: "Test", icon: .providerMark("codex"))
        let runtime = LoginStatusRuntime(provider: provider)
        let defaults = UserDefaults(suiteName: "ProviderLoginStatusTests.\(UUID().uuidString)")!
        let store = WidgetDataStore(registry: WidgetRegistry(providers: [provider], descriptors: []),
                                    providers: [runtime], defaults: defaults)
        runtime.snapshot = ProviderSnapshot(providerID: provider.id, displayName: "Test",
                                             lines: [.progress(label: "Weekly", used: 20, limit: 100, format: .percent)])
        await store.refresh(providerID: provider.id, force: true)
        XCTAssertFalse(store.loginRequired(for: provider.id))
        runtime.snapshot = .error(provider: provider, error: CodexAuthError.loginRenewalRequired)
        await store.refresh(providerID: provider.id, force: true)
        XCTAssertTrue(store.loginRequired(for: provider.id))
        XCTAssertFalse(store.snapshots[provider.id]!.lines.isEmpty, "Cached data survives a login failure")
        runtime.snapshot = .error(provider: provider, error: URLError(.notConnectedToInternet))
        await store.refresh(providerID: provider.id, force: true)
        XCTAssertTrue(store.loginRequired(for: provider.id), "A network failure cannot clear a known login failure")
        runtime.snapshot = ProviderSnapshot(providerID: provider.id, displayName: "Test", lines: [],
                                             warning: "Renew login", loginRequired: true)
        await store.refresh(providerID: provider.id, force: true)
        XCTAssertTrue(store.loginRequired(for: provider.id))
        runtime.snapshot = ProviderSnapshot(providerID: provider.id, displayName: "Test", lines: [],
                                             warning: "Network unavailable; local history only", loginRequired: nil)
        await store.refresh(providerID: provider.id, force: true)
        XCTAssertTrue(store.loginRequired(for: provider.id), "Local history cannot verify login recovery")
        runtime.snapshot = ProviderSnapshot(providerID: provider.id, displayName: "Test", lines: [])
        await store.refresh(providerID: provider.id, force: true)
        XCTAssertFalse(store.loginRequired(for: provider.id))
    }

    func testLoginMetadataSurvivesCacheEncodingAndOlderSnapshots() throws {
        let snapshot = ProviderSnapshot(providerID: "test", displayName: "Test", lines: [], loginRequired: true)
        let encoded = try JSONEncoder().encode(snapshot)
        XCTAssertEqual(try JSONDecoder().decode(ProviderSnapshot.self, from: encoded).loginRequired, true)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        object.removeValue(forKey: "loginRequired")
        let legacy = try JSONSerialization.data(withJSONObject: object)
        XCTAssertNil(try JSONDecoder().decode(ProviderSnapshot.self, from: legacy).loginRequired)
    }
}

@MainActor
private final class LoginStatusRuntime: ProviderRuntime {
    let provider: Provider
    let widgetDescriptors: [WidgetDescriptor] = []
    var snapshot: ProviderSnapshot
    init(provider: Provider) {
        self.provider = provider
        snapshot = ProviderSnapshot(providerID: provider.id, displayName: provider.displayName, lines: [])
    }
    func refresh() async -> ProviderSnapshot { snapshot }
}
