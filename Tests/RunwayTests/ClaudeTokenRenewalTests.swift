import XCTest
@testable import Runway

final class ClaudeTokenRenewalTests: XCTestCase {
    private final class StubHTTPClient: HTTPClient, @unchecked Sendable {
        private let lock = NSLock()
        private var _requests: [HTTPRequest] = []
        var requests: [HTTPRequest] { lock.withLock { _requests } }
        var response: HTTPResponse
        var onSend: (@Sendable () -> Void)?

        init(status: Int, body: [String: Any], onSend: (@Sendable () -> Void)? = nil) {
            self.response = HTTPResponse(
                statusCode: status,
                headers: [:],
                body: (try? JSONSerialization.data(withJSONObject: body)) ?? Data()
            )
            self.onSend = onSend
        }

        func send(_ request: HTTPRequest) async throws -> HTTPResponse {
            lock.withLock { _requests.append(request) }
            onSend?()
            return response
        }
    }

    private struct StubStdinRunner: StdinProcessRunning {
        var result = ProcessResult(exitCode: 0, stdout: "", stderr: "")
        var onRun: (@Sendable (String) -> Void)? = nil

        func run(executable: String, arguments: [String], stdin: String, timeout: TimeInterval) throws -> ProcessResult {
            onRun?(stdin)
            return result
        }
    }

    private static let endpoint = ClaudeAuthStore.TokenRefreshEndpoint(
        url: "https://platform.claude.com/v1/oauth/token",
        clientID: "client-1"
    )
    private static let fixedNow = Date(timeIntervalSince1970: 1_000_000)
    /// Expired an hour ago — comfortably past the renewal grace.
    private static let staleExpiry: Double = (1_000_000 - 3_600) * 1000

    private static func blob(refreshToken: String) -> String {
        #"{"claudeAiOauth":{"accessToken":"old-access","refreshToken":"\#(refreshToken)","expiresAt":\#(Int(staleExpiry)),"subscriptionType":"max","scopes":["user:profile"]},"unmodeled":{"keep":true}}"#
    }

    private static func state(refreshToken: String = "r1", source: ClaudeCredentialState.Source) -> ClaudeCredentialState {
        ClaudeCredentialState(
            oauth: ClaudeOAuth(
                accessToken: "old-access",
                refreshToken: refreshToken,
                expiresAt: staleExpiry
            ),
            source: source,
            inferenceOnly: false
        )
    }

    private func makeRenewal(
        http: StubHTTPClient,
        keychain: ServiceKeychain = ServiceKeychain(),
        files: InMemoryFiles = InMemoryFiles(),
        canWrite: Bool = true,
        onKeychainWrite: (@Sendable (String) -> Void)? = nil,
        disabled: Bool = false
    ) -> ClaudeTokenRenewal {
        var renewal = ClaudeTokenRenewal()
        renewal.refresher = ClaudeTokenRefresher(httpClient: http)
        renewal.keychain = keychain
        renewal.files = files
        renewal.environment = StaticEnvironment([:])
        renewal.isDisabled = { disabled }
        renewal.now = { Self.fixedNow }
        renewal.currentAccount = { "tester" }
        var writeBack = ClaudeCredentialWriteBack()
        writeBack.helperIsSilentlyAuthorized = { _, _ in canWrite }
        writeBack.setUserInteractionAllowed = { _ in errSecSuccess }
        // In-process update "fails" so the helper path (with its observable stdin) is exercised.
        writeBack.updateItem = { _, _ in errSecAuthFailed }
        writeBack.stdinRunner = StubStdinRunner(onRun: onKeychainWrite)
        renewal.writeBack = writeBack
        return renewal
    }

    final class InMemoryFiles: TextFileAccessing, @unchecked Sendable {
        var contents: [String: String]
        init(_ contents: [String: String] = [:]) { self.contents = contents }
        func exists(_ path: String) -> Bool { contents[path] != nil }
        func readTextIfPresent(_ path: String) throws -> String? { contents[path] }
        func readText(_ path: String) throws -> String {
            guard let text = contents[path] else { throw CocoaError(.fileNoSuchFile) }
            return text
        }
        func writeText(_ path: String, _ text: String) throws { contents[path] = text }
        func writeTextPreservingMode(_ path: String, _ text: String) throws { contents[path] = text }
        func remove(_ path: String) throws { contents[path] = nil }
        func ensureParentDirectory(for path: String) throws {}
    }

    struct StaticEnvironment: EnvironmentReading {
        var values: [String: String]
        init(_ values: [String: String]) { self.values = values }
        func value(for name: String) -> String? { values[name] }
    }

    // MARK: - Refresher

    func testRefresherParsesARotatedCredential() async {
        let http = StubHTTPClient(status: 200, body: [
            "access_token": "new-access",
            "refresh_token": "r2",
            "expires_in": 3600.0,
        ])
        let outcome = await ClaudeTokenRefresher(httpClient: http)
            .refresh(refreshToken: "r1", endpoint: Self.endpoint, now: Self.fixedNow)

        XCTAssertEqual(outcome, .refreshed(
            accessToken: "new-access",
            refreshToken: "r2",
            expiresAt: Self.fixedNow.timeIntervalSince1970 * 1000 + 3_600_000
        ))
        let request = http.requests.first
        XCTAssertEqual(request?.method, "POST")
        let sent = request.flatMap { try? JSONSerialization.jsonObject(with: $0.body ?? Data()) } as? [String: Any]
        XCTAssertEqual(sent?["grant_type"] as? String, "refresh_token")
        XCTAssertEqual(sent?["client_id"] as? String, "client-1")
    }

    func testRefresherDistinguishesInvalidGrantFromTransientFailure() async {
        let revoked = await ClaudeTokenRefresher(
            httpClient: StubHTTPClient(status: 400, body: ["error": "invalid_grant"])
        ).refresh(refreshToken: "r1", endpoint: Self.endpoint, now: Self.fixedNow)
        XCTAssertEqual(revoked, .invalidGrant)

        let transient = await ClaudeTokenRefresher(
            httpClient: StubHTTPClient(status: 500, body: [:])
        ).refresh(refreshToken: "r1", endpoint: Self.endpoint, now: Self.fixedNow)
        XCTAssertEqual(transient, .failed)
    }

    // MARK: - Blob patching

    func testPatchedBlobReplacesOnlyRotatedFieldsAndStaysSingleLine() throws {
        let patched = try XCTUnwrap(ClaudeCredentialWriteBack.patchedBlob(
            original: Self.blob(refreshToken: "r1"),
            accessToken: "new-access",
            refreshToken: "r2",
            expiresAt: 42_000
        ))
        XCTAssertFalse(patched.contains("\n"), "the blob must stay single-line (a multi-line value gets hex-encoded on write and breaks Claude Code)")
        let root = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(patched.utf8)) as? [String: Any])
        let oauth = try XCTUnwrap(root["claudeAiOauth"] as? [String: Any])
        XCTAssertEqual(oauth["accessToken"] as? String, "new-access")
        XCTAssertEqual(oauth["refreshToken"] as? String, "r2")
        XCTAssertEqual(oauth["expiresAt"] as? Int64, 42_000)
        XCTAssertEqual(oauth["subscriptionType"] as? String, "max", "unmodeled oauth fields must survive")
        XCTAssertEqual((root["unmodeled"] as? [String: Any])?["keep"] as? Bool, true, "unmodeled top-level fields must survive")
    }

    // MARK: - Renewal guards

    func testRenewalRefusesFreshExpiryAndDisabledSwitchWithoutTouchingTheNetwork() async {
        let http = StubHTTPClient(status: 200, body: [:], onSend: { XCTFail("guards must fail closed before any network call") })

        var fresh = Self.state(source: .keychainCurrentUser(service: "svc"))
        fresh.oauth.expiresAt = Self.fixedNow.timeIntervalSince1970 * 1000 - 60 * 1000
        let freshOutcome = await makeRenewal(http: http).renew(state: fresh, credentialsFilePath: "/tmp/creds")
        guard case .skipped = freshOutcome else { return XCTFail("a freshly expired token may still belong to a live session") }

        let disabledOutcome = await makeRenewal(http: http, disabled: true)
            .renew(state: Self.state(source: .keychainCurrentUser(service: "svc")), credentialsFilePath: "/tmp/creds")
        guard case .skipped = disabledOutcome else { return XCTFail("the kill switch must stop renewal") }
    }

    func testRenewalRequiresAVerifiedWritePathBeforeConsumingTheToken() async {
        let http = StubHTTPClient(status: 200, body: [:], onSend: { XCTFail("no write path proven, so the refresh token must not be consumed") })
        let keychain = ServiceKeychain(currentUserValues: ["svc": Self.blob(refreshToken: "r1")])

        let outcome = await makeRenewal(http: http, keychain: keychain, canWrite: false)
            .renew(state: Self.state(source: .keychainCurrentUser(service: "svc")), credentialsFilePath: "/tmp/creds")
        guard case .skipped = outcome else { return XCTFail("expected skip without a write path") }
    }

    func testRenewalAdoptsAFresherCredentialInsteadOfRacingIt() async {
        let http = StubHTTPClient(status: 200, body: [:], onSend: { XCTFail("the store already rotated; racing it forks the chain") })
        let keychain = ServiceKeychain(currentUserValues: ["svc": Self.blob(refreshToken: "r-newer")])

        let outcome = await makeRenewal(http: http, keychain: keychain)
            .renew(state: Self.state(refreshToken: "r1", source: .keychainCurrentUser(service: "svc")), credentialsFilePath: "/tmp/creds")
        guard case .adopted(let oauth) = outcome else { return XCTFail("expected adoption of the fresher credential") }
        XCTAssertEqual(oauth.refreshToken, "r-newer")
    }

    func testRenewalRotatesAndWritesBackToTheKeychainStore() async {
        let written = Locked<String?>(nil)
        let http = StubHTTPClient(status: 200, body: [
            "access_token": "new-access",
            "refresh_token": "r2",
            "expires_in": 3600.0,
        ])
        let keychain = ServiceKeychain(currentUserValues: ["svc": Self.blob(refreshToken: "r1")])
        let renewal = makeRenewal(http: http, keychain: keychain, onKeychainWrite: { stdin in
            written.withLock { $0 = stdin }
        })

        let outcome = await renewal.renew(
            state: Self.state(refreshToken: "r1", source: .keychainCurrentUser(service: "svc")),
            credentialsFilePath: "/tmp/creds"
        )

        guard case .renewed(let oauth) = outcome else { return XCTFail("expected a successful renewal") }
        XCTAssertEqual(oauth.accessToken, "new-access")
        XCTAssertEqual(oauth.refreshToken, "r2")
        let command = written.withLock { $0 }
        XCTAssertNotNil(command, "the rotated credential must be written back through the helper")
        XCTAssertTrue(command?.contains("add-generic-password -U") == true)
        XCTAssertTrue(command?.contains("new-access") == true)
        XCTAssertTrue(command?.contains("unmodeled") == true, "unmodeled fields must ride along in the write-back")
    }

    func testRenewalRotatesAndWritesBackToTheFileStore() async {
        let http = StubHTTPClient(status: 200, body: [
            "access_token": "new-access",
            "refresh_token": "r2",
            "expires_in": 3600.0,
        ])
        let files = InMemoryFiles(["/tmp/creds": Self.blob(refreshToken: "r1")])
        let renewal = makeRenewal(http: http, files: files)

        let outcome = await renewal.renew(
            state: Self.state(refreshToken: "r1", source: .file),
            credentialsFilePath: "/tmp/creds"
        )

        guard case .renewed = outcome else { return XCTFail("expected a successful renewal") }
        let persisted = files.contents["/tmp/creds"]
        XCTAssertTrue(persisted?.contains("new-access") == true)
        XCTAssertTrue(persisted?.contains("r2") == true)
    }

    func testInvalidGrantIsTerminalAndDesktopSourcesNeverRenew() async {
        let http = StubHTTPClient(status: 400, body: ["error": "invalid_grant"])
        let keychain = ServiceKeychain(currentUserValues: ["svc": Self.blob(refreshToken: "r1")])
        let outcome = await makeRenewal(http: http, keychain: keychain)
            .renew(state: Self.state(source: .keychainCurrentUser(service: "svc")), credentialsFilePath: "/tmp/creds")
        guard case .attemptFailed = outcome else { return XCTFail("invalid_grant must report a failed attempt for backoff") }

        let guarded = StubHTTPClient(status: 200, body: [:], onSend: { XCTFail("desktop credentials are never rotated by Runway") })
        let desktop = await makeRenewal(http: guarded)
            .renew(state: Self.state(source: .desktop), credentialsFilePath: "/tmp/creds")
        guard case .skipped = desktop else { return XCTFail("expected desktop skip") }
    }

    private final class Locked<Value>: @unchecked Sendable {
        private let lock = NSLock()
        private var value: Value
        init(_ value: Value) { self.value = value }
        func withLock<T>(_ body: (inout Value) -> T) -> T {
            lock.withLock { body(&value) }
        }
    }
}
