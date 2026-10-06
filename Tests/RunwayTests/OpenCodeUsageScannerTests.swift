import XCTest
@testable import Runway

/// The SQLite scanner: unions `opencode*.db` files and sums combined hosted spend for the tiles/trend.
/// Fed a stub `SQLiteAccessing` that returns crafted `json_group_array` payloads keyed by path.
final class OpenCodeUsageScannerTests: XCTestCase {
    private func d(_ iso: String) -> Date { RunwayISO8601.date(from: iso)! }
    private func epochMs(_ iso: String) -> Int { Int(d(iso).timeIntervalSince1970 * 1000) }
    private func row(
        _ iso: String, _ cost: String, _ tokens: Int, _ model: String, _ provider: String, id: String? = nil
    ) -> String {
        "[\(epochMs(iso)),\(cost),\(tokens),\"\(model)\",\"\(provider)\"\(id.map { ",\"\($0)\"" } ?? "")]"
    }
    private let now = RunwayISO8601.date(from: "2026-07-12T12:00:00.000Z")!

    private var db1: String {
        "[" + [
            row("2026-07-12T11:00:00.000Z", "2.0", 1000, "glm-5.2", "opencode-go"),
            row("2026-07-12T10:00:00.000Z", "1.0", 500, "gpt-5.5", "opencode"),
            row("2026-07-11T10:00:00.000Z", "3.0", 2000, "kimi-k2.6", "opencode-go"),
            row("2026-07-12T11:00:00.000Z", "null", 100, "x", "opencode-go"),
            "\"garbage\""
        ].joined(separator: ",") + "]"
    }
    private var db2: String {
        "[" + row("2026-07-12T09:00:00.000Z", "4.0", 800, "deepseek-v4-pro", "opencode-go") + "]"
    }

    private func standardScanner() -> OpenCodeUsageScanner {
        let sqlite = OpenCodeFakeSQLite(data: [
            "/oc/opencode.db": db1,
            "/oc/opencode-next.db": db2
        ])
        return OpenCodeUsageScanner(sqlite: sqlite, databasePaths: { ["/oc/opencode.db", "/oc/opencode-next.db"] })
    }

    func testCombinedHostedSeriesUnionsDatabasesAndSkipsGarbage() async throws {
        guard let scan = try await standardScanner().scan(now: now) else { return XCTFail("expected a scan") }
        let totalCost = scan.series.daily.compactMap(\.costUSD).reduce(0, +)
        let totalTokens = scan.series.daily.reduce(0) { $0 + $1.totalTokens }
        // opencode-go 2+3+4 plus Zen 1 = 10; the null-cost and "garbage" rows are dropped.
        XCTAssertEqual(totalCost, 10.0, accuracy: 0.0001)
        XCTAssertEqual(totalTokens, 4300) // 1000 + 500 + 2000 + 800
    }

    func testZenOnlyUsageStillScans() async throws {
        let db = "[" + row("2026-07-12T10:00:00.000Z", "1.0", 500, "gpt-5.5", "opencode") + "]"
        let scanner = OpenCodeUsageScanner(
            sqlite: OpenCodeFakeSQLite(data: ["/oc/opencode.db": db]),
            databasePaths: { ["/oc/opencode.db"] }
        )
        guard let scan = try await scanner.scan(now: now) else { return XCTFail("expected a scan") }
        XCTAssertEqual(scan.series.daily.compactMap(\.costUSD).reduce(0, +), 1.0, accuracy: 0.0001)
    }

    func testMissingDatabaseReturnsNil() async throws {
        let scanner = OpenCodeUsageScanner(sqlite: OpenCodeFakeSQLite(), databasePaths: { [] })
        let scan = try await scanner.scan(now: now)
        XCTAssertNil(scan)
    }

    func testEmptyDatabaseYieldsEmptyScanNotNil() async throws {
        let scanner = OpenCodeUsageScanner(
            sqlite: OpenCodeFakeSQLite(data: ["/oc/opencode.db": "[]"]),
            databasePaths: { ["/oc/opencode.db"] }
        )
        guard let scan = try await scanner.scan(now: now) else { return XCTFail("expected a scan") }
        XCTAssertTrue(scan.series.daily.isEmpty)
    }

    func testFailingDatabaseIsSkippedNotFatal() async throws {
        let scanner = OpenCodeUsageScanner(
            sqlite: OpenCodeFakeSQLite(data: ["/oc/opencode-next.db": db2], failing: ["/oc/opencode.db"]),
            databasePaths: { ["/oc/opencode.db", "/oc/opencode-next.db"] }
        )
        guard let scan = try await scanner.scan(now: now) else { return XCTFail("expected a scan") }
        XCTAssertEqual(scan.series.daily.compactMap(\.costUSD).reduce(0, +), 4.0, accuracy: 0.0001)
    }

    func testAllDatabasesFailingThrowsInsteadOfEmptyScan() async {
        let scanner = OpenCodeUsageScanner(
            sqlite: OpenCodeFakeSQLite(failing: ["/oc/opencode.db", "/oc/opencode-next.db"]),
            databasePaths: { ["/oc/opencode.db", "/oc/opencode-next.db"] }
        )
        do {
            _ = try await scanner.scan(now: now)
            XCTFail("expected databaseUnreadable")
        } catch {
            XCTAssertEqual(error as? OpenCodeUsageError, .databaseUnreadable)
        }
    }

    func testUnreadableDataDirectoryThrowsInsteadOfNil() async {
        let scanner = OpenCodeUsageScanner(
            sqlite: OpenCodeFakeSQLite(),
            databasePaths: { throw CocoaError(.fileReadNoPermission) }
        )
        do {
            _ = try await scanner.scan(now: now)
            XCTFail("expected databaseUnreadable")
        } catch {
            XCTAssertEqual(error as? OpenCodeUsageError, .databaseUnreadable)
        }
    }

    func testHasHostedUsageProbe() {
        let db = "[" + row("2026-07-12T10:00:00.000Z", "1.0", 500, "gpt-5.5", "opencode") + "]"
        let withUsage = OpenCodeUsageScanner(
            sqlite: OpenCodeFakeSQLite(data: ["/oc/opencode.db": db]),
            databasePaths: { ["/oc/opencode.db"] }
        )
        XCTAssertTrue(withUsage.hasHostedUsage())

        let empty = OpenCodeUsageScanner(
            sqlite: OpenCodeFakeSQLite(data: ["/oc/opencode.db": "[]"]),
            databasePaths: { ["/oc/opencode.db"] }
        )
        XCTAssertFalse(empty.hasHostedUsage())
    }

    func testSQLCutoffMatchesCalendarTileWindow() async throws {
        let now = d("2026-07-12T18:00:00.000Z")
        let sqlite = OpenCodeFakeSQLite(data: ["/oc/opencode.db": "[]"])
        let scanner = OpenCodeUsageScanner(sqlite: sqlite, databasePaths: { ["/oc/opencode.db"] })
        _ = try await scanner.scan(now: now)

        let tileSinceMs = Int(JSONLScanning.sinceDate(daysBack: 30, now: now).timeIntervalSince1970 * 1000)
        guard let sql = sqlite.lastDataSQL else { return XCTFail("expected a data query") }
        XCTAssertTrue(sql.contains("time_created >= \(tileSinceMs)"), sql)
    }

    func testAbsurdTokenCountIsClampedNotCrashing() async throws {
        let db = "[[\(epochMs("2026-07-12T10:00:00.000Z")),1.0,1e19,\"glm-5.2\",\"opencode-go\"]]"
        let scanner = OpenCodeUsageScanner(
            sqlite: OpenCodeFakeSQLite(data: ["/oc/opencode.db": db]),
            databasePaths: { ["/oc/opencode.db"] }
        )
        guard let scan = try await scanner.scan(now: now) else { return XCTFail("expected a scan") }
        let tokens = scan.series.daily.reduce(0) { $0 + $1.totalTokens }
        XCTAssertEqual(tokens, 1_000_000_000_000_000)
    }

    // MARK: - OpenCode 2

    private typealias DB = OpenCodeDataDirectory

    /// The generated SQL against a real upgraded OpenCode 2 database, which keeps the old table and
    /// copies its rows into the new one. Row shapes follow OpenCode 2: a nested `$.model`, token
    /// buckets without `$.tokens.total`, and compaction rows that carry usage once completed. The
    /// running compaction is given usage anyway to prove the status filter drops it.
    func testUpgradedOpenCode2DatabaseCountsEachMessageOnce() async throws {
        let dir = try DB(self)
        let t = epochMs("2026-07-12T10:00:00.000Z")
        try dir.execute(DB.openCode2Tables + [
            DB.message(id: "m1", ms: t, data:
                #"{"role":"assistant","providerID":"opencode-go","modelID":"glm-5.2","cost":2,"tokens":{"total":500}}"#),
            DB.sessionMessage(id: "m1", seq: 1, ms: t, data:
                #"{"model":{"id":"glm-5.2","providerID":"opencode-go"},"cost":2,"tokens":{"input":400,"output":100}}"#),
            DB.sessionMessage(id: "m2", seq: 2, ms: t, data:
                #"{"model":{"id":"gpt-5.5","providerID":"opencode"},"cost":1,"tokens":{"input":100,"output":50,"reasoning":25,"cache":{"read":20,"write":5}}}"#),
            DB.sessionMessage(id: "m3", type: "compaction", seq: 3, ms: t, data:
                #"{"status":"completed","model":{"id":"glm-5.2","providerID":"opencode-go"},"cost":0.5,"tokens":{"input":100}}"#),
            DB.sessionMessage(id: "m4", type: "compaction", seq: 4, ms: t, data:
                #"{"status":"running","model":{"id":"glm-5.2","providerID":"opencode-go"},"cost":9,"tokens":{"input":1}}"#),
            DB.sessionMessage(id: "m5", seq: 5, ms: t, data:
                #"{"model":{"id":"gpt-5.5","providerID":"openai"},"cost":7,"tokens":{"input":1}}"#),
            DB.sessionMessage(id: "m6", type: "user", seq: 6, ms: t, data:
                #"{"model":{"id":"glm-5.2","providerID":"opencode-go"},"cost":9,"tokens":{"input":1}}"#)
        ].joined())

        let scanner = OpenCodeUsageScanner(databasePaths: dir.databasePaths)
        guard let scan = try await scanner.scan(now: now) else { return XCTFail("expected a scan") }
        // m1 once (2), m2 (1), completed compaction m3 (0.5).
        XCTAssertEqual(scan.series.daily.compactMap(\.costUSD).reduce(0, +), 3.5, accuracy: 0.0001)
        // 500 + (100+50+25+20+5) + 100.
        XCTAssertEqual(scan.series.daily.reduce(0) { $0 + $1.totalTokens }, 800)
        XCTAssertTrue(scanner.hasHostedUsage())
    }

    func testFreshOpenCode2DatabaseWithoutTheLegacyTableIsRead() async throws {
        let dir = try DB(self)
        let t = epochMs("2026-07-12T10:00:00.000Z")
        try dir.execute(DB.freshOpenCode2Tables + DB.sessionMessage(id: "m1", seq: 1, ms: t, data:
            #"{"model":{"id":"deepseek-v4-pro","providerID":"opencode-go"},"cost":2,"tokens":{"input":900,"output":100}}"#))

        let scanner = OpenCodeUsageScanner(databasePaths: dir.databasePaths)
        guard let scan = try await scanner.scan(now: now) else { return XCTFail("expected a scan") }
        XCTAssertEqual(scan.series.daily.compactMap(\.costUSD).reduce(0, +), 2.0, accuracy: 0.0001)
        XCTAssertEqual(scan.series.daily.reduce(0) { $0 + $1.totalTokens }, 1000)
        XCTAssertTrue(scanner.hasHostedUsage())
    }

    func testOpenCode1DatabasesAreStillRead() async throws {
        // Without the newer tables, and with them present but empty as OpenCode 1.18 creates them.
        for tables in [DB.messageTable, DB.openCode118Tables] {
            try await assertOpenCode1DatabaseIsRead(tables)
        }
    }

    private func assertOpenCode1DatabaseIsRead(_ tables: String) async throws {
        let dir = try DB(self)
        let t = epochMs("2026-07-12T10:00:00.000Z")
        try dir.execute(tables + DB.message(id: "m1", ms: t, data:
            #"{"role":"assistant","providerID":"opencode","modelID":"gpt-5.5","cost":1.5,"tokens":{"total":700}}"#))

        let scanner = OpenCodeUsageScanner(databasePaths: dir.databasePaths)
        guard let scan = try await scanner.scan(now: now) else { return XCTFail("expected a scan") }
        XCTAssertEqual(scan.series.daily.compactMap(\.costUSD).reduce(0, +), 1.5, accuracy: 0.0001)
        XCTAssertEqual(scan.series.daily.reduce(0) { $0 + $1.totalTokens }, 700)
    }

    func testCopiesAreCountedOnceAcrossTablesAndChannelDatabases() async throws {
        let copy = row("2026-07-12T11:00:00.000Z", "2.0", 500, "glm-5.2", "opencode-go", id: "msg-same")
        let other = row("2026-07-12T10:00:00.000Z", "1.0", 300, "gpt-5.5", "opencode", id: "msg-other")
        let noID = row("2026-07-12T09:00:00.000Z", "0.5", 100, "gpt-5.5", "opencode")
        let scanner = OpenCodeUsageScanner(
            sqlite: OpenCodeFakeSQLite(data: [
                "/oc/opencode.db": "[" + [copy, copy, other, noID, noID].joined(separator: ",") + "]",
                "/oc/opencode-next.db": "[\(copy)]"
            ]),
            databasePaths: { ["/oc/opencode.db", "/oc/opencode-next.db"] }
        )
        guard let scan = try await scanner.scan(now: now) else { return XCTFail("expected a scan") }
        // The copy once (2), the other message (1), and both ID-less rows (0.5 each).
        XCTAssertEqual(scan.series.daily.compactMap(\.costUSD).reduce(0, +), 4.0, accuracy: 0.0001)
        XCTAssertEqual(scan.series.daily.reduce(0) { $0 + $1.totalTokens }, 1000)
    }

    func testDatabaseWithoutMessageTablesDoesNotVote() async throws {
        // A readable sibling with no message tables must not turn "every usable database failed"
        // into a partial success.
        let failing = OpenCodeUsageScanner(
            sqlite: OpenCodeFakeSQLite(failing: ["/oc/opencode-next.db"], tables: ["/oc/opencode.db": "credential"]),
            databasePaths: { ["/oc/opencode.db", "/oc/opencode-next.db"] }
        )
        do {
            _ = try await failing.scan(now: now)
            XCTFail("expected databaseUnreadable")
        } catch {
            XCTAssertEqual(error as? OpenCodeUsageError, .databaseUnreadable)
        }

        let empty = OpenCodeUsageScanner(
            sqlite: OpenCodeFakeSQLite(tables: ["/oc/opencode.db": ""]),
            databasePaths: { ["/oc/opencode.db"] }
        )
        guard let scan = try await empty.scan(now: now) else { return XCTFail("expected a scan") }
        XCTAssertTrue(scan.series.daily.isEmpty)
        XCTAssertFalse(empty.hasHostedUsage())
    }
}
