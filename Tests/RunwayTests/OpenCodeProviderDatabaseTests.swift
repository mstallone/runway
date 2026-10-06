import XCTest
@testable import Runway

/// The OpenCode card against real data directories: which login store is live for OpenCode 1.18 and
/// OpenCode 2, and what an unreadable database does to the card and to first-run detection.
@MainActor
final class OpenCodeProviderDatabaseTests: XCTestCase {
    private typealias DB = OpenCodeDataDirectory

    private func epochMs(_ iso: String) -> Int { Int(RunwayISO8601.date(from: iso)!.timeIntervalSince1970 * 1000) }
    private func row(_ iso: String, _ cost: String, _ tokens: Int, _ model: String, _ provider: String) -> String {
        "[\(epochMs(iso)),\(cost),\(tokens),\"\(model)\",\"\(provider)\"]"
    }
    private let authJSON = #"{"opencode-go":{"type":"api","key":"sk-test"}}"#
    private let now = RunwayISO8601.date(from: "2026-07-12T12:00:00.000Z")!

    private func usageJSON() -> Data {
        let window = ["status": "ok", "percent": 12, "resetsAt": "2026-07-12T17:00:00.000Z"] as [String: Any]
        return try! JSONSerialization.data(withJSONObject: [
            "usage": ["rolling": window, "weekly": window, "monthly": window]
        ])
    }

    /// A provider over one listed database whose login reads and usage reads can fail separately:
    /// the login comes from auth.json unless `authSQLite` fails, and usage comes from `db`.
    private func splitProvider(authSQLite: OpenCodeFakeSQLite) throws -> (OpenCodeProvider, FakeHTTPClient) {
        let dir = try OpenCodeDataDirectory(self)
        try Data().write(to: dir.url.appendingPathComponent("opencode.db"))
        let db = "[" + row("2026-07-12T10:00:00.000Z", "1.0", 500, "gpt-5.5", "opencode") + "]"
        let http = FakeHTTPClient(response: HTTPResponse(statusCode: 200, headers: [:], body: usageJSON()))
        let now = self.now
        let provider = OpenCodeProvider(
            authStore: OpenCodeAuthStore(
                files: FakeFiles([dir.path("auth.json"): authJSON]),
                environment: FakeEnvironment(["OPENCODE_DATA_DIR": dir.url.path]),
                homeDirectory: { URL(fileURLWithPath: "/nonexistent") },
                sqlite: authSQLite
            ),
            usageClient: OpenCodeUsageClient(http: http),
            usageScanner: OpenCodeUsageScanner(
                sqlite: OpenCodeFakeSQLite(data: [dir.path(): db]),
                databasePaths: dir.databasePaths
            ),
            now: { now }
        )
        authSQLite.failing = [dir.path()]
        return (provider, http)
    }

    func testLoginDatabaseFailureAfterAGoKeyWasSeenFailsTheRefresh() async throws {
        // The card had Go meters, then the login could not be read from a busy database while the
        // usage scan still worked. Publishing tiles alone would replace and cache over the meters.
        let authSQLite = OpenCodeFakeSQLite()
        let (provider, http) = try splitProvider(authSQLite: authSQLite)
        let locked = authSQLite.failing
        authSQLite.failing = []
        let first = await provider.refresh()
        XCTAssertNotNil(first.line(label: "Session"))

        authSQLite.failing = locked
        let second = await provider.refresh()
        XCTAssertEqual(
            second.errorText, OpenCodeUsageError.credentialDatabaseUnreadable(detail: "").localizedDescription
        )
        XCTAssertNil(second.line(label: "Today"))
        XCTAssertNil(second.loginRequired)
        XCTAssertEqual(http.requests.count, 1)

        // Readable again: the card recovers on its own.
        authSQLite.failing = []
        let third = await provider.refresh()
        XCTAssertNil(third.errorText)
        XCTAssertNotNil(third.line(label: "Session"))
        XCTAssertEqual(http.requests.count, 2)
    }

    func testLogoutBesideAnUnreadableDatabaseShowsTilesNotAnError() async throws {
        // While logged in, a corrupt leftover channel database is never asked, because the stable
        // database already answered. After a logout it is asked and fails. The database that had the
        // key was read and has none now, so this is a logout, not a failed read of the login.
        let dir = try DB(self)
        try dir.execute(DB.openCode2Tables + [
            DB.credential(id: "c1", integration: "opencode-go", value: #"{"type":"key","key":"oc_sk_live"}"#),
            DB.sessionMessage(id: "m1", seq: 1, ms: epochMs("2026-07-12T10:00:00.000Z"), data:
                #"{"finish":"stop","model":{"id":"glm-5.2","providerID":"opencode-go"},"cost":2,"tokens":{"input":400,"output":100}}"#)
        ].joined())
        try dir.writeCorruptDatabase("opencode-next.db")
        let http = FakeHTTPClient(response: HTTPResponse(statusCode: 200, headers: [:], body: usageJSON()))
        let provider = provider(dir, http: http)

        let loggedIn = await provider.refresh()
        XCTAssertNotNil(loggedIn.line(label: "Session"))
        XCTAssertNotNil(loggedIn.line(label: "Today"))

        try dir.execute("DELETE FROM credential;")
        for _ in 0..<2 {
            let loggedOut = await provider.refresh()
            XCTAssertNil(loggedOut.errorText)
            XCTAssertNotNil(loggedOut.line(label: "Today"))
            XCTAssertNil(loggedOut.line(label: "Session"))
            XCTAssertNil(loggedOut.plan)
        }
        XCTAssertEqual(http.requests.count, 1)
    }

    func testLoginDatabaseFailureOnTheFirstRefreshStillShowsLocalTiles() async throws {
        // Nothing seen yet this run, so there are no meters to protect: show what can be shown.
        let (provider, http) = try splitProvider(authSQLite: OpenCodeFakeSQLite())
        let snapshot = await provider.refresh()
        XCTAssertNil(snapshot.errorText)
        XCTAssertNotNil(snapshot.line(label: "Today"))
        XCTAssertNil(snapshot.line(label: "Session"))
        XCTAssertTrue(http.requests.isEmpty)
    }

    func testUnreadableSiblingDatabaseDoesNotCostANoGoUserTheirTiles() async throws {
        // Zen-only usage in the stable database, plus a corrupt leftover channel database.
        let dir = try OpenCodeDataDirectory(self)
        try dir.execute(OpenCodeDataDirectory.openCode2Tables + OpenCodeDataDirectory.sessionMessage(
            id: "m1", seq: 1, ms: epochMs("2026-07-12T10:00:00.000Z"),
            data: #"{"finish":"stop","model":{"id":"gpt-5.5","providerID":"opencode"},"cost":1,"tokens":{"input":400,"output":100}}"#
        ))
        try dir.writeCorruptDatabase("opencode-next.db")
        let http = FakeHTTPClient(response: HTTPResponse(statusCode: 200, headers: [:], body: usageJSON()))
        let provider = provider(dir, http: http)

        for _ in 0..<2 {
            let snapshot = await provider.refresh()
            XCTAssertNil(snapshot.errorText)
            XCTAssertNotNil(snapshot.line(label: "Today"))
            XCTAssertNil(snapshot.line(label: "Session"))
        }
        let has = await provider.hasLocalCredentials()
        XCTAssertTrue(has)
    }

    func testUnreadableDatabaseAloneIsNotAFootprint() async throws {
        // OpenCode used only with the user's own provider keys: no Go login, no hosted usage, and a
        // database that cannot be read during detection. Nothing to show, so do not enable.
        let dir = try OpenCodeDataDirectory(self)
        try dir.writeCorruptDatabase("opencode.db")
        let http = FakeHTTPClient(response: HTTPResponse(statusCode: 200, headers: [:], body: usageJSON()))
        let has = await provider(dir, http: http).hasLocalCredentials()
        XCTAssertFalse(has)
    }

    // MARK: - OpenCode 1.18

    /// The shape OpenCode 1.18.21 leaves on disk: `credential` and `session_message` exist and are
    /// empty, every message is in `message`, and the login is in auth.json. Those empty tables must
    /// not make the user look logged out.
    func testOpenCode118LoginInTheAuthFileDrivesTheCard() async throws {
        let dir = try DB(self)
        try dir.execute(DB.openCode118Tables + DB.message(id: "m1", ms: epochMs("2026-07-12T10:00:00.000Z"), data:
            #"{"role":"assistant","providerID":"opencode-go","modelID":"glm-5.2","cost":2,"tokens":{"total":500}}"#))
        let http = FakeHTTPClient(response: HTTPResponse(statusCode: 200, headers: [:], body: usageJSON()))
        let provider = provider(dir, auth: authJSON, http: http)

        let has = await provider.hasLocalCredentials()
        XCTAssertTrue(has)
        let snapshot = await provider.refresh()
        XCTAssertEqual(http.requests.first?.headers["Authorization"], "Bearer sk-test")
        XCTAssertEqual(snapshot.plan, "Go")
        XCTAssertNotNil(snapshot.line(label: "Session"))
        XCTAssertNotNil(snapshot.line(label: "Today"))
        XCTAssertNil(snapshot.warning)
    }

    func testOpenCode118LoginIsDetectedBeforeAnyUsage() async throws {
        let dir = try DB(self)
        try dir.execute(DB.openCode118Tables)
        let http = FakeHTTPClient(response: HTTPResponse(statusCode: 200, headers: [:], body: usageJSON()))

        let loggedIn = await provider(dir, auth: authJSON, http: http).hasLocalCredentials()
        XCTAssertTrue(loggedIn)
        let loggedOut = await provider(dir, http: http).hasLocalCredentials()
        XCTAssertFalse(loggedOut)
    }

    // MARK: - OpenCode 2

    private func provider(_ dir: OpenCodeDataDirectory, auth: String? = nil, http: FakeHTTPClient) -> OpenCodeProvider {
        let now = self.now
        return OpenCodeProvider(
            authStore: dir.authStore(auth: auth),
            usageClient: OpenCodeUsageClient(http: http),
            usageScanner: OpenCodeUsageScanner(databasePaths: dir.databasePaths),
            now: { now }
        )
    }

    /// The whole card against a real upgraded OpenCode 2 database: the Go key comes from the
    /// credential table (the imported auth.json is stale), and spend comes from the new message log.
    func testOpenCode2LoginAndUsageDriveTheCard() async throws {
        let dir = try DB(self)
        try dir.execute(DB.openCode2Tables + [
            DB.credential(id: "c1", integration: "opencode-go", value: #"{"type":"key","key":"oc_sk_live"}"#),
            DB.sessionMessage(id: "m1", seq: 1, ms: epochMs("2026-07-12T10:00:00.000Z"), data:
                #"{"finish":"stop","model":{"id":"glm-5.2","providerID":"opencode-go"},"cost":2,"tokens":{"input":400,"output":100}}"#)
        ].joined())
        let http = FakeHTTPClient(response: HTTPResponse(statusCode: 200, headers: [:], body: usageJSON()))
        let provider = provider(dir, auth: #"{"opencode-go":{"type":"api","key":"sk-stale"}}"#, http: http)

        let has = await provider.hasLocalCredentials()
        XCTAssertTrue(has)
        let snapshot = await provider.refresh()
        XCTAssertEqual(http.requests.first?.headers["Authorization"], "Bearer oc_sk_live")
        XCTAssertEqual(snapshot.plan, "Go")
        XCTAssertNotNil(snapshot.line(label: "Session"))
        guard case .values(_, let values, _, _, _, _)? = snapshot.line(label: "Today") else {
            return XCTFail("expected a Today tile")
        }
        XCTAssertEqual(values.first?.number, 2)
        XCTAssertEqual(values.last?.number, 500)
    }

    func testOpenCode2LogoutIsNotDetectedOrRefreshedFromTheStaleAuthFile() async throws {
        // Logged out of OpenCode 2 with nothing logged: the leftover auth.json must neither enable
        // the provider nor send its dead key anywhere. `hasLocalCredentials()` and `refresh()` agree.
        let dir = try DB(self)
        try dir.execute(DB.openCode2Tables)
        let http = FakeHTTPClient(response: HTTPResponse(statusCode: 200, headers: [:], body: usageJSON()))
        let provider = provider(dir, auth: authJSON, http: http)

        let has = await provider.hasLocalCredentials()
        XCTAssertFalse(has)
        let snapshot = await provider.refresh()
        XCTAssertTrue(http.requests.isEmpty)
        XCTAssertNil(snapshot.line(label: "Session"))
        XCTAssertNil(snapshot.errorText)
    }

    func testUnreadableOnlyDatabaseIsAnErrorAndNeverSendsTheAuthFileKey() async throws {
        let dir = try DB(self)
        try dir.writeCorruptDatabase("opencode.db")
        let http = FakeHTTPClient(response: HTTPResponse(statusCode: 200, headers: [:], body: usageJSON()))
        let provider = provider(dir, auth: authJSON, http: http)

        // Which store is live cannot be told, and there is no usage to show: not a footprint.
        let has = await provider.hasLocalCredentials()
        XCTAssertFalse(has)
        let snapshot = await provider.refresh()
        XCTAssertTrue(http.requests.isEmpty, "the auth.json key must not be sent on a guess")
        XCTAssertEqual(snapshot.errorText, OpenCodeUsageError.databaseUnreadable.localizedDescription)
    }
}
