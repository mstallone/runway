import XCTest
@testable import Runway

/// End-to-end provider behavior: detection via the Go auth key or local usage, Go meters from the
/// usage API, and local spend tiles + trend, plus auth/empty paths.
@MainActor
final class OpenCodeProviderTests: XCTestCase {
    private func d(_ iso: String) -> Date { RunwayISO8601.date(from: iso)! }
    private func epochMs(_ iso: String) -> Int { Int(d(iso).timeIntervalSince1970 * 1000) }
    private func row(_ iso: String, _ cost: String, _ tokens: Int, _ model: String, _ provider: String) -> String {
        "[\(epochMs(iso)),\(cost),\(tokens),\"\(model)\",\"\(provider)\"]"
    }
    private let authJSON = #"{"opencode-go":{"type":"api","key":"sk-test"}}"#
    private let now = RunwayISO8601.date(from: "2026-07-12T12:00:00.000Z")!

    private func authStore(files: TextFileAccessing) -> OpenCodeAuthStore {
        OpenCodeAuthStore(
            files: files,
            environment: FakeEnvironment(["OPENCODE_DATA_DIR": "/oc"]),
            homeDirectory: { URL(fileURLWithPath: "/nonexistent") }
        )
    }

    private func usageJSON(rolling: Int = 12, weekly: Int = 8, monthly: Int = 35) -> Data {
        let body: [String: Any] = [
            "usage": [
                "rolling": ["status": "ok", "percent": rolling, "resetsAt": "2026-07-12T17:00:00.000Z"],
                "weekly": ["status": "ok", "percent": weekly, "resetsAt": "2026-07-13T00:00:00.000Z"],
                "monthly": ["status": "ok", "percent": monthly, "resetsAt": "2026-08-04T11:18:32.000Z"]
            ]
        ]
        return try! JSONSerialization.data(withJSONObject: body)
    }

    private func okClient() -> OpenCodeUsageClient {
        OpenCodeUsageClient(http: FakeHTTPClient(response: HTTPResponse(
            statusCode: 200, headers: [:], body: usageJSON()
        )))
    }

    private func unauthorizedClient() -> OpenCodeUsageClient {
        OpenCodeUsageClient(http: FakeHTTPClient(response: HTTPResponse(
            statusCode: 401,
            headers: [:],
            body: Data(#"{"type":"error","error":{"type":"AuthError","message":"Unauthorized"}}"#.utf8)
        )))
    }

    private func provider(
        files: TextFileAccessing,
        scanner: OpenCodeUsageScanner,
        client: OpenCodeUsageClient? = nil
    ) -> OpenCodeProvider {
        let now = self.now
        return OpenCodeProvider(
            authStore: authStore(files: files),
            usageClient: client ?? okClient(),
            usageScanner: scanner,
            now: { now }
        )
    }

    func testHasLocalCredentialsViaGoAuthKey() async {
        let provider = provider(
            files: FakeFiles(["/oc/auth.json": authJSON]),
            scanner: OpenCodeUsageScanner(sqlite: OpenCodeFakeSQLite(), databasePaths: { [] })
        )
        let has = await provider.hasLocalCredentials()
        XCTAssertTrue(has)
    }

    func testHasLocalCredentialsViaLocalUsage() async {
        let db = "[" + row("2026-07-12T10:00:00.000Z", "1.0", 500, "gpt-5.5", "opencode") + "]"
        let provider = provider(
            files: FakeFiles(),
            scanner: OpenCodeUsageScanner(
                sqlite: OpenCodeFakeSQLite(data: ["/oc/opencode.db": db]),
                databasePaths: { ["/oc/opencode.db"] }
            )
        )
        let has = await provider.hasLocalCredentials()
        XCTAssertTrue(has)
    }

    func testHasLocalCredentialsFalseWhenAbsent() async {
        let provider = provider(
            files: FakeFiles(),
            scanner: OpenCodeUsageScanner(
                sqlite: OpenCodeFakeSQLite(data: ["/oc/opencode.db": "[]"]),
                databasePaths: { ["/oc/opencode.db"] }
            )
        )
        let has = await provider.hasLocalCredentials()
        XCTAssertFalse(has)
    }

    func testRefreshProducesMetersTilesAndTrend() async {
        let db = "[" + [
            row("2026-07-12T11:00:00.000Z", "2.0", 1000, "glm-5.2", "opencode-go"),
            row("2026-07-12T10:00:00.000Z", "1.0", 500, "gpt-5.5", "opencode")
        ].joined(separator: ",") + "]"
        let http = FakeHTTPClient(response: HTTPResponse(statusCode: 200, headers: [:], body: usageJSON()))
        let snapshot = await provider(
            files: FakeFiles(["/oc/auth.json": authJSON]),
            scanner: OpenCodeUsageScanner(
                sqlite: OpenCodeFakeSQLite(data: ["/oc/opencode.db": db]),
                databasePaths: { ["/oc/opencode.db"] }
            ),
            client: OpenCodeUsageClient(http: http)
        ).refresh()

        XCTAssertEqual(snapshot.plan, "Go")
        XCTAssertEqual(http.requests.count, 1)
        XCTAssertEqual(http.requests.first?.url, OpenCodeUsageClient.usageURL)
        XCTAssertEqual(http.requests.first?.headers["Authorization"], "Bearer sk-test")

        guard case let .progress(_, used, limit, format, _, _, _)? = snapshot.line(label: "Session") else {
            return XCTFail("expected a Session meter")
        }
        XCTAssertEqual(used, 12)
        XCTAssertEqual(limit, 100)
        XCTAssertEqual(format, .percent)
        XCTAssertNotNil(snapshot.line(label: "Weekly"))
        XCTAssertNotNil(snapshot.line(label: "Monthly"))
        XCTAssertNotNil(snapshot.line(label: "Usage Trend"))
        XCTAssertNotNil(snapshot.line(label: "Today"))
        // Meters present → every metric applies (legacy all-applicable behavior).
        XCTAssertNil(snapshot.applicableMetricIDs)
    }

    func testRefreshNotLoggedInWhenNoKeyAndNoDatabase() async {
        let snapshot = await provider(
            files: FakeFiles(),
            scanner: OpenCodeUsageScanner(sqlite: OpenCodeFakeSQLite(), databasePaths: { [] })
        ).refresh()
        XCTAssertEqual(snapshot.errorText, OpenCodeUsageError.notLoggedIn.localizedDescription)
    }

    func testRefreshShowsAPIMetersWithGoKeyButNoDatabase() async {
        let snapshot = await provider(
            files: FakeFiles(["/oc/auth.json": authJSON]),
            scanner: OpenCodeUsageScanner(sqlite: OpenCodeFakeSQLite(), databasePaths: { [] })
        ).refresh()
        XCTAssertEqual(snapshot.plan, "Go")
        guard case let .progress(_, used, limit, format, _, _, _)? = snapshot.line(label: "Session") else {
            return XCTFail("expected a Session meter")
        }
        XCTAssertEqual(used, 12)
        XCTAssertEqual(limit, 100)
        XCTAssertEqual(format, .percent)
        XCTAssertNil(snapshot.line(label: "Today"))
    }

    func testRefreshKeepsGoMetersWhenDatabasesUnreadable() async {
        let snapshot = await provider(
            files: FakeFiles(["/oc/auth.json": authJSON]),
            scanner: OpenCodeUsageScanner(
                sqlite: OpenCodeFakeSQLite(failing: ["/oc/opencode.db"]),
                databasePaths: { ["/oc/opencode.db"] }
            )
        ).refresh()
        XCTAssertEqual(snapshot.plan, "Go")
        XCTAssertNotNil(snapshot.line(label: "Session"))
        XCTAssertNil(snapshot.line(label: "Today"))
    }

    func testRefreshErrorsWhenDatabasesUnreadableWithoutGoKey() async {
        let snapshot = await provider(
            files: FakeFiles(),
            scanner: OpenCodeUsageScanner(
                sqlite: OpenCodeFakeSQLite(failing: ["/oc/opencode.db"]),
                databasePaths: { ["/oc/opencode.db"] }
            )
        ).refresh()
        XCTAssertEqual(snapshot.errorText, OpenCodeUsageError.databaseUnreadable.localizedDescription)
        XCTAssertNil(snapshot.line(label: "Session"))
    }

    func testRefreshSurfacesUnreadableAuthFileInsteadOfNotLoggedIn() async {
        let snapshot = await provider(
            files: UnreadableFiles(present: ["/oc/auth.json"]),
            scanner: OpenCodeUsageScanner(sqlite: OpenCodeFakeSQLite(), databasePaths: { [] })
        ).refresh()
        XCTAssertEqual(snapshot.errorText, OpenCodeUsageError.credentialsUnreadable(detail: "").localizedDescription)
    }

    func testHasLocalCredentialsTrueWhenAuthFileUnreadable() async {
        let provider = provider(
            files: UnreadableFiles(present: ["/oc/auth.json"]),
            scanner: OpenCodeUsageScanner(sqlite: OpenCodeFakeSQLite(), databasePaths: { [] })
        )
        let has = await provider.hasLocalCredentials()
        XCTAssertTrue(has)
    }

    func testSpendTilesAreNotMarkedEstimated() async {
        let db = "[" + row("2026-07-12T10:00:00.000Z", "1.0", 500, "gpt-5.5", "opencode") + "]"
        let snapshot = await provider(
            files: FakeFiles(),
            scanner: OpenCodeUsageScanner(
                sqlite: OpenCodeFakeSQLite(data: ["/oc/opencode.db": db]),
                databasePaths: { ["/oc/opencode.db"] }
            )
        ).refresh()
        guard case .values(_, let values, _, _, _, _)? = snapshot.line(label: "Today") else {
            return XCTFail("expected a Today tile")
        }
        XCTAssertFalse(values.contains(where: \.estimated))
        XCTAssertNil(snapshot.plan)
        XCTAssertNil(snapshot.line(label: "Session"))
    }

    func testUnauthorizedKeyWithoutLocalUsageFailsLoudly() async {
        let snapshot = await provider(
            files: FakeFiles(["/oc/auth.json": authJSON]),
            scanner: OpenCodeUsageScanner(sqlite: OpenCodeFakeSQLite(), databasePaths: { [] }),
            client: unauthorizedClient()
        ).refresh()
        XCTAssertEqual(snapshot.errorText, OpenCodeUsageError.unauthorized.localizedDescription)
        XCTAssertEqual(snapshot.loginRequired, true)
    }

    func testGoMeterFailureKeepsLocalTilesUnderANotice() async {
        // A rejected key or an unreachable usage API must not cost the local spend. The failure
        // rides as the card notice, and the Go rows stay applicable so the notice stands in for them.
        let db = "[" + row("2026-07-12T10:00:00.000Z", "1.0", 500, "gpt-5.5", "opencode") + "]"
        let cases: [(OpenCodeUsageClient, OpenCodeUsageError, Bool?)] = [
            (unauthorizedClient(), .unauthorized, true),
            (OpenCodeUsageClient(http: ThrowingHTTPClient()), .connectionFailed, nil),
            (OpenCodeUsageClient(http: FakeHTTPClient(response: HTTPResponse(
                statusCode: 500, headers: [:], body: Data()
            ))), .requestFailed(500), nil)
        ]
        for (client, error, loginRequired) in cases {
            let snapshot = await provider(
                files: FakeFiles(["/oc/auth.json": authJSON]),
                scanner: OpenCodeUsageScanner(
                    sqlite: OpenCodeFakeSQLite(data: ["/oc/opencode.db": db]),
                    databasePaths: { ["/oc/opencode.db"] }
                ),
                client: client
            ).refresh()
            XCTAssertNil(snapshot.errorText, "\(error)")
            XCTAssertNotNil(snapshot.line(label: "Today"), "\(error)")
            XCTAssertNotNil(snapshot.usageHistory, "\(error)")
            XCTAssertNil(snapshot.line(label: "Session"), "\(error)")
            XCTAssertNil(snapshot.plan, "\(error)")
            XCTAssertEqual(snapshot.warning, error.localizedDescription)
            XCTAssertEqual(snapshot.loginRequired, loginRequired, "\(error)")
            XCTAssertNil(snapshot.applicableMetricIDs, "\(error)")
        }
    }

    // MARK: - OpenCode 2

    private typealias DB = OpenCodeDataDirectory

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
                #"{"model":{"id":"glm-5.2","providerID":"opencode-go"},"cost":2,"tokens":{"input":400,"output":100}}"#)
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

    func testUnreadableOpenCode2CredentialStoreIsAFootprintAndAnError() async throws {
        let dir = try DB(self)
        try dir.writeCorruptDatabase("opencode.db")
        let http = FakeHTTPClient(response: HTTPResponse(statusCode: 200, headers: [:], body: usageJSON()))
        let provider = provider(dir, auth: authJSON, http: http)

        let has = await provider.hasLocalCredentials()
        XCTAssertTrue(has)
        let snapshot = await provider.refresh()
        XCTAssertTrue(http.requests.isEmpty, "the stale auth.json key must not be sent")
        XCTAssertEqual(snapshot.errorText, OpenCodeUsageError.databaseUnreadable.localizedDescription)
    }

    func testEntitlementErrorWithoutLocalUsageIsNoGoSubscription() async {
        let snapshot = await provider(
            files: FakeFiles(["/oc/auth.json": authJSON]),
            scanner: OpenCodeUsageScanner(sqlite: OpenCodeFakeSQLite(), databasePaths: { [] }),
            client: OpenCodeUsageClient(http: FakeHTTPClient(response: HTTPResponse(
                statusCode: 403,
                headers: [:],
                body: Data(#"{"type":"error","error":{"type":"EntitlementError","message":"OpenCode Go subscription required."}}"#.utf8)
            )))
        ).refresh()
        XCTAssertEqual(snapshot.errorText, OpenCodeUsageError.noGoSubscription.localizedDescription)
    }

    func testEntitlementErrorWithZenUsageShowsTilesWithoutGoMeters() async {
        let db = "[" + row("2026-07-12T10:00:00.000Z", "1.0", 500, "gpt-5.5", "opencode") + "]"
        let snapshot = await provider(
            files: FakeFiles(["/oc/auth.json": authJSON]),
            scanner: OpenCodeUsageScanner(
                sqlite: OpenCodeFakeSQLite(data: ["/oc/opencode.db": db]),
                databasePaths: { ["/oc/opencode.db"] }
            ),
            client: OpenCodeUsageClient(http: FakeHTTPClient(response: HTTPResponse(
                statusCode: 403,
                headers: [:],
                body: Data(#"{"type":"error","error":{"type":"EntitlementError","message":"OpenCode Go subscription required."}}"#.utf8)
            )))
        ).refresh()
        XCTAssertNil(snapshot.plan)
        XCTAssertNil(snapshot.line(label: "Session"))
        XCTAssertNotNil(snapshot.line(label: "Today"))
        // Without a Go subscription the three cap rows must be hidden, not rendered as "No data"
        // (`isMetricApplicable` treats every descriptor as applicable when this stays nil).
        XCTAssertEqual(
            snapshot.applicableMetricIDs,
            ["opencode.trend", "opencode.today", "opencode.yesterday", "opencode.last30"]
        )
    }

    func testGeneric403WithoutLocalUsageFailsLoudly() async {
        let snapshot = await provider(
            files: FakeFiles(["/oc/auth.json": authJSON]),
            scanner: OpenCodeUsageScanner(sqlite: OpenCodeFakeSQLite(), databasePaths: { [] }),
            client: OpenCodeUsageClient(http: FakeHTTPClient(response: HTTPResponse(
                statusCode: 403, headers: [:], body: Data("<html>denied</html>".utf8)
            )))
        ).refresh()
        XCTAssertEqual(snapshot.errorText, OpenCodeUsageError.requestFailed(403).localizedDescription)
    }

    func testConnectionFailureWithoutLocalUsageFailsLoudly() async {
        let snapshot = await provider(
            files: FakeFiles(["/oc/auth.json": authJSON]),
            scanner: OpenCodeUsageScanner(sqlite: OpenCodeFakeSQLite(), databasePaths: { [] }),
            client: OpenCodeUsageClient(http: ThrowingHTTPClient())
        ).refresh()
        XCTAssertEqual(snapshot.errorText, OpenCodeUsageError.connectionFailed.localizedDescription)
    }
}

private final class ThrowingHTTPClient: HTTPClient, @unchecked Sendable {
    func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        throw URLError(.notConnectedToInternet)
    }
}
