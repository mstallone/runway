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
            scanner: OpenCodeUsageScanner(sqlite: StubSQLite(), databasePaths: { [] })
        )
        let has = await provider.hasLocalCredentials()
        XCTAssertTrue(has)
    }

    func testHasLocalCredentialsViaLocalUsage() async {
        let db = "[" + row("2026-07-12T10:00:00.000Z", "1.0", 500, "gpt-5.5", "opencode") + "]"
        let provider = provider(
            files: FakeFiles(),
            scanner: OpenCodeUsageScanner(
                sqlite: StubSQLite(data: ["/oc/opencode.db": db]),
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
                sqlite: StubSQLite(data: ["/oc/opencode.db": "[]"]),
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
                sqlite: StubSQLite(data: ["/oc/opencode.db": db]),
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

    /// The Session row as the dashboard reads it, after a real provider refresh through
    /// `WidgetDataStore`, for a usage response whose rolling window reads `percent` with `rollingReset`.
    private func sessionRow(percent: Int, rollingReset: Date, dateHeader: String?) async throws -> WidgetData {
        let body: [String: Any] = [
            "usage": [
                "rolling": ["status": "ok", "percent": percent,
                            "resetsAt": RunwayISO8601.string(from: rollingReset)],
                "weekly": ["status": "ok", "percent": 1, "resetsAt": "2026-07-13T00:00:00.000Z"],
                "monthly": ["status": "ok", "percent": 0, "resetsAt": "2026-08-04T11:18:32.000Z"]
            ]
        ]
        let response = HTTPResponse(
            statusCode: 200,
            headers: dateHeader.map { ["date": $0] } ?? [:],
            body: try JSONSerialization.data(withJSONObject: body)
        )
        let runtime = provider(
            files: FakeFiles(["/oc/auth.json": authJSON]),
            scanner: OpenCodeUsageScanner(sqlite: StubSQLite(), databasePaths: { [] }),
            client: OpenCodeUsageClient(http: FakeHTTPClient(response: response))
        )
        let descriptors = runtime.widgetDescriptors
        let suiteName = "OpenCodeProviderTests.session.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(testSuiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        let fixedNow = now
        let store = WidgetDataStore(
            registry: WidgetRegistry(providers: [runtime.provider], descriptors: descriptors),
            providers: [runtime],
            cache: ProviderSnapshotCache(userDefaults: defaults),
            defaults: defaults,
            now: { fixedNow }
        )
        await store.refreshAll(force: true)
        return store.data(for: try XCTUnwrap(descriptors.first { $0.id == "opencode.session" }))
    }

    func testSubOnePercentSessionShowsResetCountdown() async throws {
        // A session that has started still reads 0% (whole-percent API), but its rolling reset is
        // anchored inside the five-hour window. The row must show the countdown, not "Not started".
        let anchoredReset = now.addingTimeInterval(5 * 3600 - 30)
        for dateHeader in ["Sun, 12 Jul 2026 12:00:00 GMT", nil] {
            let data = try await sessionRow(percent: 0, rollingReset: anchoredReset, dateHeader: dateHeader)
            XCTAssertTrue(data.hasData)
            XCTAssertEqual(data.used, 0)
            XCTAssertEqual(data.resetsAt, anchoredReset)
            XCTAssertFalse(data.isFreshSessionWindow(now: now))
            XCTAssertEqual(data.boundedTrailingText(now: now)?.hasPrefix("Resets in "), true)
            XCTAssertTrue(data.hasResetLabel(now: now))
            XCTAssertNotEqual(data.resetTooltip(now: now), WidgetData.freshSessionTooltip)
        }
    }

    func testUntouchedSessionStillShowsNotStarted() async throws {
        // An untouched session reports a placeholder reset of about now + 5h. The row drops it and
        // reads "Not started", with no reset label to toggle and a calm bar.
        let placeholderReset = now.addingTimeInterval(5 * 3600 + 0.5)
        for dateHeader in ["Sun, 12 Jul 2026 12:00:00 GMT", nil] {
            let data = try await sessionRow(percent: 0, rollingReset: placeholderReset, dateHeader: dateHeader)
            XCTAssertTrue(data.hasData)
            XCTAssertEqual(data.used, 0)
            XCTAssertNil(data.resetsAt)
            XCTAssertTrue(data.isFreshSessionWindow(now: now))
            XCTAssertEqual(data.boundedTrailingText(now: now), "Not started")
            XCTAssertFalse(data.hasResetLabel(now: now))
            XCTAssertEqual(data.resetTooltip(now: now), WidgetData.freshSessionTooltip)
            XCTAssertEqual(data.meterState(now: now), .level(.normal))
            // The stored snapshot does not go stale into a countdown as the clock moves on.
            let later = now.addingTimeInterval(20 * 60)
            XCTAssertEqual(data.boundedTrailingText(now: later), "Not started")
        }
    }

    func testStartedSessionKeepsCountdownAtFullPeriod() async throws {
        // Usage above zero is never a placeholder, even with the reset exactly one period out.
        let data = try await sessionRow(
            percent: 3, rollingReset: now.addingTimeInterval(5 * 3600), dateHeader: "Sun, 12 Jul 2026 12:00:00 GMT"
        )
        XCTAssertEqual(data.used, 3)
        XCTAssertEqual(data.boundedTrailingText(now: now)?.hasPrefix("Resets in "), true)
    }

    func testRefreshNotLoggedInWhenNoKeyAndNoDatabase() async {
        let snapshot = await provider(
            files: FakeFiles(),
            scanner: OpenCodeUsageScanner(sqlite: StubSQLite(), databasePaths: { [] })
        ).refresh()
        XCTAssertEqual(snapshot.errorText, OpenCodeUsageError.notLoggedIn.localizedDescription)
    }

    func testRefreshShowsAPIMetersWithGoKeyButNoDatabase() async {
        let snapshot = await provider(
            files: FakeFiles(["/oc/auth.json": authJSON]),
            scanner: OpenCodeUsageScanner(sqlite: StubSQLite(), databasePaths: { [] })
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
                sqlite: StubSQLite(failing: ["/oc/opencode.db"]),
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
                sqlite: StubSQLite(failing: ["/oc/opencode.db"]),
                databasePaths: { ["/oc/opencode.db"] }
            )
        ).refresh()
        XCTAssertEqual(snapshot.errorText, OpenCodeUsageError.databaseUnreadable.localizedDescription)
        XCTAssertNil(snapshot.line(label: "Session"))
    }

    func testRefreshSurfacesUnreadableAuthFileInsteadOfNotLoggedIn() async {
        let snapshot = await provider(
            files: UnreadableFiles(present: ["/oc/auth.json"]),
            scanner: OpenCodeUsageScanner(sqlite: StubSQLite(), databasePaths: { [] })
        ).refresh()
        XCTAssertEqual(snapshot.errorText, OpenCodeUsageError.credentialsUnreadable(detail: "").localizedDescription)
    }

    func testHasLocalCredentialsTrueWhenAuthFileUnreadable() async {
        let provider = provider(
            files: UnreadableFiles(present: ["/oc/auth.json"]),
            scanner: OpenCodeUsageScanner(sqlite: StubSQLite(), databasePaths: { [] })
        )
        let has = await provider.hasLocalCredentials()
        XCTAssertTrue(has)
    }

    func testSpendTilesAreNotMarkedEstimated() async {
        let db = "[" + row("2026-07-12T10:00:00.000Z", "1.0", 500, "gpt-5.5", "opencode") + "]"
        let snapshot = await provider(
            files: FakeFiles(),
            scanner: OpenCodeUsageScanner(
                sqlite: StubSQLite(data: ["/oc/opencode.db": db]),
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

    func testUnauthorizedKeyFailsLoudly() async {
        let snapshot = await provider(
            files: FakeFiles(["/oc/auth.json": authJSON]),
            scanner: OpenCodeUsageScanner(sqlite: StubSQLite(), databasePaths: { [] }),
            client: OpenCodeUsageClient(http: FakeHTTPClient(response: HTTPResponse(
                statusCode: 401,
                headers: [:],
                body: Data(#"{"type":"error","error":{"type":"AuthError","message":"Unauthorized"}}"#.utf8)
            )))
        ).refresh()
        XCTAssertEqual(snapshot.errorText, OpenCodeUsageError.unauthorized.localizedDescription)
    }

    func testEntitlementErrorWithoutLocalUsageIsNoGoSubscription() async {
        let snapshot = await provider(
            files: FakeFiles(["/oc/auth.json": authJSON]),
            scanner: OpenCodeUsageScanner(sqlite: StubSQLite(), databasePaths: { [] }),
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
                sqlite: StubSQLite(data: ["/oc/opencode.db": db]),
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

    func testGeneric403FailsLoudly() async {
        let snapshot = await provider(
            files: FakeFiles(["/oc/auth.json": authJSON]),
            scanner: OpenCodeUsageScanner(sqlite: StubSQLite(), databasePaths: { [] }),
            client: OpenCodeUsageClient(http: FakeHTTPClient(response: HTTPResponse(
                statusCode: 403, headers: [:], body: Data("<html>denied</html>".utf8)
            )))
        ).refresh()
        XCTAssertEqual(snapshot.errorText, OpenCodeUsageError.requestFailed(403).localizedDescription)
    }

    func testConnectionFailureFailsLoudly() async {
        let snapshot = await provider(
            files: FakeFiles(["/oc/auth.json": authJSON]),
            scanner: OpenCodeUsageScanner(sqlite: StubSQLite(), databasePaths: { [] }),
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

private final class StubSQLite: SQLiteAccessing, @unchecked Sendable {
    var data: [String: String]
    var failing: Set<String>
    init(data: [String: String] = [:], failing: Set<String> = []) {
        self.data = data
        self.failing = failing
    }

    func queryValue(path: String, sql: String) throws -> String? {
        if failing.contains(path) { throw SQLiteError.queryFailed("boom") }
        if sql.contains("json_group_array") { return data[path] }
        if sql.contains("SELECT 1") {
            let payload = data[path]
            return (payload != nil && payload != "[]" && !(payload ?? "").isEmpty) ? "1" : nil
        }
        return nil
    }

    // JSON row queries are not exercised here.
    func queryJSONRows(path: String, sql: String) throws -> String? { nil }
}
