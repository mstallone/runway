import XCTest
@testable import Runway

final class FireworksAuthStoreTests: XCTestCase {
    func testReadsFirectlAuthFileWithoutTouchingKeychain() {
        let keychain = DeferredKeychain(value: "fw_nexus")
        let store = FireworksAuthStore(
            files: FakeFiles([FireworksAuthStore.authPath: """
            # written by firectl
            [default]
            api_key = "fw_test"
            account_id = accounts/acme
            """]),
            keychain: keychain
        )

        XCTAssertEqual(store.loadCredentials(), .auth(FireworksAuth(apiKey: "fw_test", accountID: "acme")))
        XCTAssertEqual(keychain.reads, 0)
    }

    func testAuthFileWithoutKeyIsNoLogin() {
        let store = FireworksAuthStore(
            files: FakeFiles([FireworksAuthStore.authPath: "account_id = acme"]),
            keychain: ServiceKeychain()
        )

        XCTAssertEqual(store.loadCredentials(), .none)
    }

    func testFallsBackToNexusKeychainKey() {
        let store = FireworksAuthStore(
            files: FakeFiles(),
            keychain: ServiceKeychain(values: [FireworksAuthStore.nexusKeychainService: "fw_nexus\n"])
        )

        XCTAssertEqual(store.loadCredentials(), .auth(FireworksAuth(apiKey: "fw_nexus", accountID: nil)))
    }

    func testAutomaticLoadDefersProtectedKeychainItem() {
        let keychain = DeferredKeychain(value: "fw_nexus")
        let store = FireworksAuthStore(files: FakeFiles(), keychain: keychain)

        // Automatic refreshes never prompt: the item is a real login, offered as a connect prompt.
        XCTAssertEqual(store.loadCredentials(allowKeychainInteraction: false), .connectRequired)
        // A manual refresh may read it.
        XCTAssertEqual(
            store.loadCredentials(allowKeychainInteraction: true),
            .auth(FireworksAuth(apiKey: "fw_nexus", accountID: nil))
        )
    }

    func testParsesINIVariants() {
        let values = FireworksAuthStore.parseINI("""
        ; comment
        API-Key: 'fw_quoted'
        api_key = fw_second
        account_id =
        """)

        XCTAssertEqual(values["api_key"], "fw_quoted")
        XCTAssertNil(values["account_id"])
        XCTAssertEqual(FireworksAuthStore.normalizedAccountID(" accounts/acme/ "), "acme")
    }
}

final class FireworksUsageMapperTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_792_670_400) // 2026-10-22T12:00:00Z

    func testMapsMonthlySpendQuota() throws {
        let line = try FireworksUsageMapper.monthlySpendLine(from: Data("""
        {
          "quotas": [
            {"name": "accounts/acme/quotas/h100-us-iowa-1", "value": "8", "usage": 2},
            {"name": "accounts/acme/quotas/monthly-spend-usd", "value": "200", "maxValue": "500", "usage": 50}
          ]
        }
        """.utf8), now: now)

        guard case .progress(let label, let used, let limit, let format, let resetsAt, _, _) = line else {
            return XCTFail("expected a progress line")
        }
        XCTAssertEqual(label, "Monthly Spend")
        XCTAssertEqual(used, 50)
        XCTAssertEqual(limit, 200)
        XCTAssertEqual(format, .dollars)
        XCTAssertEqual(resetsAt, RunwayISO8601.date(from: "2026-11-01T00:00:00Z"))
    }

    func testMissingUsageIsMeasuredZero() throws {
        let line = try FireworksUsageMapper.monthlySpendLine(from: Data("""
        {"quotas": [{"name": "accounts/acme/quotas/monthly-spend-usd", "value": "50"}]}
        """.utf8), now: now)

        guard case .progress(_, let used, _, _, _, _, _) = line else { return XCTFail("expected a progress line") }
        XCTAssertEqual(used, 0)
    }

    func testAccountWithoutSpendQuotaIsUnavailable() {
        XCTAssertThrowsError(try FireworksUsageMapper.monthlySpendLine(from: Data(#"{"quotas":[]}"#.utf8), now: now)) {
            XCTAssertEqual($0 as? FireworksUsageError, .monthlySpendUnavailable)
        }
        XCTAssertThrowsError(try FireworksUsageMapper.monthlySpendLine(from: Data("<html>".utf8), now: now)) {
            XCTAssertEqual($0 as? FireworksUsageError, .invalidResponse)
        }
    }

    func testDiscoversOnlySoleAccount() {
        XCTAssertEqual(
            FireworksUsageMapper.soleAccountID(from: Data(#"{"accounts":[{"name":"accounts/acme"}]}"#.utf8)),
            "acme"
        )
        XCTAssertNil(FireworksUsageMapper.soleAccountID(
            from: Data(#"{"accounts":[{"name":"accounts/a"},{"name":"accounts/b"}]}"#.utf8)
        ))
    }
}

@MainActor
final class FireworksProviderTests: XCTestCase {
    func testRefreshReadsQuotaForConfiguredAccount() async throws {
        let provider = FireworksProvider(
            authStore: authStore(ini: "api_key = fw_test\naccount_id = acme"),
            usageClient: FireworksUsageClient(http: RoutingHTTPClient { request in
                XCTAssertEqual(request.headers["Authorization"], "Bearer fw_test")
                XCTAssertEqual(
                    request.url.absoluteString,
                    "https://api.fireworks.ai/v1/accounts/acme/quotas?pageSize=200"
                )
                return quotasResponse(value: 100, usage: 25)
            })
        )

        let snapshot = await provider.refresh()

        XCTAssertNil(snapshot.errorText)
        XCTAssertNotNil(snapshot.line(label: "Monthly Spend"))
    }

    func testRefreshDiscoversAccountOnceForKeyWithoutOne() async {
        let requests = RequestLog()
        let provider = FireworksProvider(
            authStore: FireworksAuthStore(
                files: FakeFiles(),
                keychain: ServiceKeychain(values: [FireworksAuthStore.nexusKeychainService: "fw_nexus"])
            ),
            usageClient: FireworksUsageClient(http: RoutingHTTPClient { request in
                requests.append(request.url.path)
                if request.url.path == "/v1/accounts" {
                    return HTTPResponse(statusCode: 200, headers: [:], body: Data(#"{"accounts":[{"name":"accounts/solo"}]}"#.utf8))
                }
                return quotasResponse(value: 100, usage: 25)
            })
        )

        _ = await provider.refresh()
        let snapshot = await provider.refresh()

        XCTAssertNotNil(snapshot.line(label: "Monthly Spend"))
        XCTAssertEqual(requests.paths, ["/v1/accounts", "/v1/accounts/solo/quotas", "/v1/accounts/solo/quotas"])
    }

    func testRefreshWithAmbiguousAccountAsksForAccountID() async {
        let provider = FireworksProvider(
            authStore: authStore(ini: "api_key = fw_test"),
            usageClient: FireworksUsageClient(http: RoutingHTTPClient { _ in
                HTTPResponse(statusCode: 200, headers: [:], body: Data(#"{"accounts":[{"name":"accounts/a"},{"name":"accounts/b"}]}"#.utf8))
            })
        )

        let snapshot = await provider.refresh()

        XCTAssertEqual(snapshot.errorText, FireworksAuthError.accountUnknown.localizedDescription)
    }

    func testRefreshOnAuthFailureReportsInvalidKey() async {
        let provider = FireworksProvider(
            authStore: authStore(ini: "api_key = fw_bad\naccount_id = acme"),
            usageClient: FireworksUsageClient(http: RoutingHTTPClient { _ in
                HTTPResponse(statusCode: 401, headers: [:], body: Data("{}".utf8))
            })
        )

        let snapshot = await provider.refresh()

        XCTAssertEqual(snapshot.errorText, FireworksAuthError.invalidKey.localizedDescription)
        XCTAssertEqual(snapshot.loginRequired, true)
    }

    func testRefreshWithoutLoginSkipsNetwork() async {
        let provider = FireworksProvider(
            authStore: FireworksAuthStore(files: FakeFiles(), keychain: ServiceKeychain()),
            usageClient: FireworksUsageClient(http: RoutingHTTPClient { _ in
                XCTFail("should not hit the network without a login")
                return HTTPResponse(statusCode: 500, headers: [:], body: Data())
            })
        )

        let snapshot = await provider.refresh()
        let hasCredentials = await provider.hasLocalCredentials()

        XCTAssertEqual(snapshot.errorText, FireworksAuthError.notLoggedIn.localizedDescription)
        XCTAssertFalse(hasCredentials)
    }

    func testDeferredKeychainLoginCountsAsLocalCredentials() async {
        let provider = FireworksProvider(
            authStore: FireworksAuthStore(files: FakeFiles(), keychain: DeferredKeychain(value: "fw_nexus")),
            usageClient: FireworksUsageClient(http: RoutingHTTPClient { _ in
                XCTFail("an automatic refresh must not read the deferred key")
                return HTTPResponse(statusCode: 500, headers: [:], body: Data())
            })
        )

        let hasCredentials = await provider.hasLocalCredentials()
        let snapshot = await provider.refresh()

        XCTAssertTrue(hasCredentials)
        XCTAssertEqual(snapshot.loginRequired, true)
        XCTAssertNil(snapshot.errorText)
    }

    private func authStore(ini: String) -> FireworksAuthStore {
        FireworksAuthStore(files: FakeFiles([FireworksAuthStore.authPath: ini]), keychain: ServiceKeychain())
    }
}

private func quotasResponse(value: Double, usage: Double) -> HTTPResponse {
    let body: [String: Any] = ["quotas": [
        ["name": "accounts/acme/quotas/monthly-spend-usd", "value": String(value), "usage": usage]
    ]]
    return HTTPResponse(statusCode: 200, headers: [:], body: try! JSONSerialization.data(withJSONObject: body))
}

private final class RequestLog: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String] = []

    var paths: [String] { lock.withLock { storage } }
    func append(_ path: String) { lock.withLock { storage.append(path) } }
}

/// A Keychain item that exists but whose secret only a user-attended read may load, like a foreign
/// item Runway hasn't been approved for yet.
private final class DeferredKeychain: KeychainReading, @unchecked Sendable {
    let value: String
    private(set) var reads = 0

    init(value: String) {
        self.value = value
    }

    func readGenericPassword(service: String) throws -> String? {
        reads += 1
        return value
    }

    func readGenericPasswordWithoutUserInteraction(service: String) -> NonInteractiveKeychainRead {
        reads += 1
        return .unavailable
    }

    func lastReadFailure(service: String) -> KeychainReadFailure? {
        .manualReadDeferred
    }
}
