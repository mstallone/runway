import XCTest
@testable import Runway

/// OpenCode's ChatGPT OAuth slice is attributed to Codex, following the same carried-cost-else-price
/// policy as pi. API-key OpenAI traffic must never enter the Codex card.
final class OpenCodeCodexUsageScannerTests: XCTestCase {
    private let now = RunwayISO8601.date(from: "2026-07-12T12:00:00.000Z")!

    private let pricing = ModelPricing(
        supplement: PricingSupplement(),
        primary: PricingCatalog(entries: [
            "gpt-test": ModelRates(
                inputPerMillion: 2,
                outputPerMillion: 10,
                cacheWritePerMillion: 2,
                cacheReadPerMillion: 0.2
            )
        ]),
        secondary: PricingCatalog(entries: [:])
    )

    private let codexPricing = ModelPricing(
        supplement: PricingSupplement(
            pricing: [
                "gpt-5.6-sol": ModelRates(
                    inputPerMillion: 5,
                    outputPerMillion: 30,
                    cacheWritePerMillion: 6.25,
                    cacheReadPerMillion: 0.5
                )
            ],
            fastMultipliers: ["gpt-5.6-sol": 2.5]
        ),
        primary: PricingCatalog(entries: [:]),
        secondary: PricingCatalog(entries: [:])
    )

    private func scanner(auth: String, rows: String, sqlite: OpenCodeFakeSQLite? = nil) -> OpenCodeCodexUsageScanner {
        let database = sqlite ?? OpenCodeFakeSQLite(data: ["/oc/opencode.db": rows])
        return OpenCodeCodexUsageScanner(
            authStore: OpenCodeAuthStore(
                files: FakeFiles(["/oc/auth.json": auth]),
                environment: FakeEnvironment(["OPENCODE_DATA_DIR": "/oc"]),
                homeDirectory: { URL(fileURLWithPath: "/unused") }
            ),
            sqlite: database,
            databasePaths: { ["/oc/opencode.db"] }
        )
    }

    func testOAuthUsageIsPricedAndReturnedForCodex() async throws {
        let rows = "[" + row(
            "2026-07-12T10:00:00.000Z", cost: "0", total: 150, model: "gpt-test",
            input: 100, cacheRead: 20, output: 20, reasoning: 10
        ) + "]"
        let scan = await scanner(
            auth: #"{"openai":{"type":"oauth","access":"token"}}"#,
            rows: rows
        ).scan(now: now, pricing: pricing)

        let day = try XCTUnwrap(scan?.series.daily.first)
        XCTAssertEqual(day.totalTokens, 150)
        // 100*$2/M + 20*$0.20/M + (20+10)*$10/M.
        XCTAssertEqual(day.costUSD ?? -1, 0.000504, accuracy: 0.0000001)
        XCTAssertEqual(scan?.modelUsage?.daily.first?.models.first?.model, "gpt-test")
    }

    func testAPIKeyTrafficIsExcludedBeforeDatabaseRead() async {
        let sqlite = OpenCodeFakeSQLite(data: ["/oc/opencode.db": "[]"])
        let scan = await scanner(
            auth: #"{"openai":{"type":"api","key":"sk-openai"}}"#,
            rows: "[]",
            sqlite: sqlite
        ).scan(now: now, pricing: pricing)

        XCTAssertNil(scan)
        XCTAssertNil(sqlite.lastDataSQL)
    }

    func testHistoricAPIKeyRowIsExcludedWhileZeroCostOAuthRowStillCounts() async throws {
        let rows = "[" + [
            row(
                "2026-07-12T10:00:00.000Z", cost: "1", total: 150, model: "gpt-test",
                input: 100, output: 50, id: "historic-api-key"
            ),
            row(
                "2026-07-12T11:00:00.000Z", cost: "0", total: 60, model: "gpt-test",
                input: 50, output: 10, id: "current-oauth"
            )
        ].joined(separator: ",") + "]"
        let scan = await scanner(
            auth: #"{"openai":{"type":"oauth","access":"token"}}"#,
            rows: rows
        ).scan(now: now, pricing: pricing)

        XCTAssertEqual(try XCTUnwrap(scan).series.daily.first?.totalTokens, 60)
    }

    func testOAuthUsageUsesCodexLongContextRatesPerRequest() async throws {
        let rows = "[" + row(
            "2026-07-12T10:00:00.000Z", cost: "0", total: 310_000, model: "gpt-5.6-sol",
            input: 200_000, cacheRead: 100_000, output: 10_000
        ) + "]"
        let scan = await scanner(
            auth: #"{"openai":{"type":"oauth","access":"token"}}"#,
            rows: rows
        ).scan(now: now, pricing: codexPricing)

        // Prompt = 300K, above Codex's 272K threshold. The request uses $10/M input,
        // $1/M cache read, and $45/M output: $2 + $0.10 + $0.45 = $2.55.
        XCTAssertEqual(try XCTUnwrap(scan?.series.daily.first?.costUSD), 2.55, accuracy: 0.000_001)
    }

    func testOAuthUsageAtCodexLongContextBoundaryKeepsBaseRates() async throws {
        let rows = "[" + row(
            "2026-07-12T10:00:00.000Z", cost: "0", total: 282_000, model: "gpt-5.6-sol",
            input: 172_000, cacheRead: 100_000, output: 10_000
        ) + "]"
        let scan = await scanner(
            auth: #"{"openai":{"type":"oauth","access":"token"}}"#,
            rows: rows
        ).scan(now: now, pricing: codexPricing)

        // Exactly 272K prompt tokens does not cross the threshold.
        XCTAssertEqual(try XCTUnwrap(scan?.series.daily.first?.costUSD), 1.21, accuracy: 0.000_001)
    }

    func testOAuthFastAliasAppliesCodexPriorityMultiplierOnce() async throws {
        let rows = "[" + row(
            "2026-07-12T10:00:00.000Z", cost: "0", total: 110_000, model: "gpt-5.6-sol-fast",
            input: 100_000, output: 10_000
        ) + "]"
        let scan = await scanner(
            auth: #"{"openai":{"type":"oauth","access":"token"}}"#,
            rows: rows
        ).scan(now: now, pricing: codexPricing)

        // Base cost is $0.80. Codex priority is 2x for Sol, even though the supplement's
        // Cursor-oriented fast multiplier is deliberately 2.5x.
        XCTAssertEqual(try XCTUnwrap(scan?.series.daily.first?.costUSD), 1.6, accuracy: 0.000_001)
    }

    func testSeparateInputAndCacheReadBucketsAreEachPricedOnce() async throws {
        let rows = "[" + row(
            "2026-07-12T10:00:00.000Z", cost: "0", total: 160_000, model: "gpt-5.6-sol",
            input: 100_000, cacheRead: 50_000, output: 10_000
        ) + "]"
        let scan = await scanner(
            auth: #"{"openai":{"type":"oauth","access":"token"}}"#,
            rows: rows
        ).scan(now: now, pricing: codexPricing)

        // OpenCode already stores disjoint buckets, so the native Codex rule of subtracting cached
        // tokens from input must not be applied here: 100K * $5/M + 50K * $0.50/M + 10K * $30/M.
        // Treating the buckets as native's inclusive input would price only 50K at the input rate.
        XCTAssertEqual(try XCTUnwrap(scan?.series.daily.first?.costUSD), 0.825, accuracy: 0.000_001)
    }

    func testUnknownOAuthModelIsExcludedAndWarned() async throws {
        let rows = "[" + row(
            "2026-07-12T10:00:00.000Z", cost: "0", total: 150, model: "gpt-mystery",
            input: 100, output: 50
        ) + "]"
        let scan = await scanner(
            auth: #"{"openai":{"type":"oauth","access":"token"}}"#,
            rows: rows
        ).scan(now: now, pricing: .empty)

        XCTAssertTrue(try XCTUnwrap(scan).series.daily.isEmpty)
        XCTAssertEqual(scan?.unknownModelsByDay["2026-07-12"], ["gpt-mystery"])
    }

    func testCopiedRowsAcrossChannelDatabasesAreDeduplicatedByMessageID() async throws {
        let duplicate = row(
            "2026-07-12T10:00:00.000Z", cost: "0", total: 150, model: "gpt-test",
            input: 100, output: 50, id: "same-message"
        )
        let sqlite = OpenCodeFakeSQLite(data: [
            "/oc/opencode.db": "[\(duplicate)]",
            "/oc/opencode-next.db": "[\(duplicate)]"
        ])
        let scanner = OpenCodeCodexUsageScanner(
            authStore: OpenCodeAuthStore(
                files: FakeFiles(["/oc/auth.json": #"{"openai":{"type":"oauth","access":"token"}}"#]),
                environment: FakeEnvironment(["OPENCODE_DATA_DIR": "/oc"]),
                homeDirectory: { URL(fileURLWithPath: "/unused") }
            ),
            sqlite: sqlite,
            databasePaths: { ["/oc/opencode.db", "/oc/opencode-next.db"] }
        )

        let scan = await scanner.scan(now: now, pricing: pricing)
        XCTAssertEqual(try XCTUnwrap(scan?.series.daily.first).totalTokens, 150)
    }

    func testQuerySelectsOnlyCompletedOpenAIRows() {
        let sql = OpenCodeCodexUsageScanner.dataSQL(cutoffMs: 123)
        XCTAssertTrue(
            sql.contains("COALESCE(json_extract(data,'$.model.providerID'),json_extract(data,'$.providerID')) = 'openai'"),
            sql
        )
        XCTAssertTrue(sql.contains("$.cost') = 0"), sql)
        XCTAssertTrue(sql.contains("$.time.completed"), sql)
        XCTAssertTrue(sql.contains("$.finish"), sql)
        XCTAssertTrue(sql.contains("$.tokens.reasoning"), sql)
    }

    private func row(
        _ iso: String,
        cost: String,
        total: Int,
        model: String,
        input: Int,
        cacheRead: Int = 0,
        cacheWrite: Int = 0,
        output: Int,
        reasoning: Int = 0,
        id: String = "message-1"
    ) -> String {
        let milliseconds = Int(RunwayISO8601.date(from: iso)!.timeIntervalSince1970 * 1000)
        return "[\(milliseconds),\(cost),\(total),\"\(model)\",\(input),\(cacheRead),\(cacheWrite),\(output),\(reasoning),\"\(id)\"]"
    }

    // MARK: - OpenCode 2

    private typealias DB = OpenCodeDataDirectory
    private let oauthAuth = #"{"openai":{"type":"oauth","access":"token"}}"#

    private func ms(_ iso: String) -> Int { Int(RunwayISO8601.date(from: iso)!.timeIntervalSince1970 * 1000) }

    /// An OpenCode 2 assistant row: nested model, token buckets, no `$.tokens.total`.
    private func assistant(
        _ id: String, seq: Int, at iso: String, provider: String = "openai", cost: String = "0",
        input: Int, output: Int, completed: Bool = true
    ) -> String {
        let t = ms(iso)
        let time = completed ? #"{"created":\#(t),"completed":\#(t)}"# : #"{"created":\#(t)}"#
        return DB.sessionMessage(id: id, seq: seq, ms: t, data:
            #"{"model":{"id":"gpt-test","providerID":"\#(provider)"},"cost":\#(cost),"time":\#(time),"tokens":{"input":\#(input),"output":\#(output)}}"#)
    }

    private func realScanner(_ dir: DB, auth: String? = nil) -> OpenCodeCodexUsageScanner {
        OpenCodeCodexUsageScanner(authStore: dir.authStore(auth: auth), databasePaths: dir.databasePaths)
    }

    private func totalTokens(_ scan: LogUsageScan?) -> Int? {
        scan.map { $0.series.daily.reduce(0) { $0 + $1.totalTokens } }
    }

    /// The shape OpenCode 1.18.21 leaves on disk: empty `credential` and `session_message` tables,
    /// every message in `message`, and the ChatGPT login in auth.json. The empty table must not read
    /// as a logout.
    func testOpenCode118UsageIsAttributedFromTheAuthFileLogin() async throws {
        let dir = try DB(self)
        try dir.execute(DB.openCode118Tables + DB.message(id: "m1", ms: ms("2026-07-12T10:00:00.000Z"), data:
            #"{"role":"assistant","providerID":"openai","modelID":"gpt-test","cost":0,"finish":"stop","tokens":{"total":150,"input":100,"output":50}}"#))

        let scan = await realScanner(dir, auth: oauthAuth).scan(now: now, pricing: pricing)
        XCTAssertEqual(totalTokens(scan), 150)

        let apiKey = await realScanner(dir, auth: #"{"openai":{"type":"api","key":"sk-x"}}"#)
            .scan(now: now, pricing: pricing)
        XCTAssertNil(apiKey)
        let loggedOut = await realScanner(dir).scan(now: now, pricing: pricing)
        XCTAssertNil(loggedOut)
    }

    /// The generated SQL against a real upgraded OpenCode 2 database. The ChatGPT login was created
    /// on July 11; the stale auth.json says API key and must be ignored.
    func testOpenCode2OAuthUsageIsAttributedOnce() async throws {
        let dir = try DB(self)
        let legacy = ms("2026-07-05T10:00:00.000Z")
        try dir.execute(DB.openCode2Tables + [
            DB.credential(
                id: "c1", integration: "openai", value: #"{"type":"oauth","access":"a","refresh":"r"}"#,
                created: String(ms("2026-07-11T00:00:00.000Z"))
            ),
            // Counted: a new-table row after the login.
            assistant("m1", seq: 1, at: "2026-07-12T10:00:00.000Z", input: 100, output: 50),
            // Counted once: an old-table row and its migrated copy, both older than the login. The
            // copy is outside the login bound; the original needs no bound.
            DB.message(id: "m2", ms: legacy, data:
                #"{"role":"assistant","providerID":"openai","modelID":"gpt-test","cost":0,"finish":"stop","tokens":{"total":30,"input":20,"output":10}}"#),
            assistant("m2", seq: 2, at: "2026-07-05T10:00:00.000Z", input: 20, output: 10),
            // Not counted: a new-table row from before the login, which may be paid API-key usage.
            assistant("m3", seq: 3, at: "2026-07-10T10:00:00.000Z", input: 4000, output: 4000),
            // Not counted: priced (API-key) traffic, another provider, and an unfinished message.
            assistant("m4", seq: 4, at: "2026-07-12T10:00:00.000Z", cost: "0.5", input: 4000, output: 4000),
            assistant("m5", seq: 5, at: "2026-07-12T10:00:00.000Z", provider: "opencode-go", input: 4000, output: 4000),
            assistant("m6", seq: 6, at: "2026-07-12T10:00:00.000Z", input: 4000, output: 4000, completed: false),
            // Counted: a completed compaction. Not counted: a running one.
            DB.sessionMessage(id: "m7", type: "compaction", seq: 7, ms: ms("2026-07-12T11:00:00.000Z"), data:
                #"{"status":"completed","model":{"id":"gpt-test","providerID":"openai"},"cost":0,"tokens":{"input":1000}}"#),
            DB.sessionMessage(id: "m8", type: "compaction", seq: 8, ms: ms("2026-07-12T11:00:00.000Z"), data:
                #"{"status":"running","model":{"id":"gpt-test","providerID":"openai"},"cost":0,"tokens":{"input":4000}}"#)
        ].joined())

        let scan = await realScanner(dir, auth: #"{"openai":{"type":"api","key":"sk-stale"}}"#)
            .scan(now: now, pricing: pricing)
        // m1 (150) + m2 (30) + m7 (1000).
        XCTAssertEqual(totalTokens(scan), 1180)
        XCTAssertEqual(scan?.modelUsage?.daily.flatMap(\.models).map(\.model).first, "gpt-test")
    }

    func testLoggingInAgainDoesNotDropEarlierOpenCode2Usage() async throws {
        // First ChatGPT login on July 1, a second on July 11. OpenCode keeps the first row as an
        // inactive account, so usage between the two logins still counts.
        let dir = try DB(self)
        try dir.execute(DB.openCode2Tables + [
            DB.credential(
                id: "c1", integration: "openai", value: #"{"type":"oauth","access":"a"}"#,
                active: "0", created: String(ms("2026-07-01T00:00:00.000Z"))
            ),
            DB.credential(
                id: "c2", integration: "openai", value: #"{"type":"oauth","access":"b"}"#,
                created: String(ms("2026-07-11T00:00:00.000Z"))
            ),
            assistant("before-first-login", seq: 1, at: "2026-06-30T10:00:00.000Z", input: 4000, output: 4000),
            assistant("between-logins", seq: 2, at: "2026-07-05T10:00:00.000Z", input: 20, output: 10),
            assistant("after-second-login", seq: 3, at: "2026-07-12T10:00:00.000Z", input: 100, output: 50)
        ].joined())

        let scan = await realScanner(dir).scan(now: now, pricing: pricing)
        XCTAssertEqual(totalTokens(scan), 180)
    }

    func testMigratedCopyDoesNotMoveAMessageToAnotherDay() async throws {
        // OpenCode 2 copies an old message under its ID and stamps the copy's completion with the
        // row's last update. The original keeps the day it had before the upgrade.
        let dir = try DB(self)
        let created = ms("2026-07-05T10:00:00.000Z")
        let updated = ms("2026-07-08T10:00:00.000Z")
        try dir.execute(DB.openCode2Tables + [
            DB.credential(id: "c1", integration: "openai", value: #"{"type":"oauth","access":"a"}"#, created: "0"),
            DB.sessionMessage(id: "m1", seq: 1, ms: created, data:
                #"{"model":{"id":"gpt-test","providerID":"openai"},"cost":0,"time":{"created":\#(created),"completed":\#(updated)},"tokens":{"input":100,"output":50}}"#),
            DB.message(id: "m1", ms: created, data:
                #"{"role":"assistant","providerID":"openai","modelID":"gpt-test","cost":0,"time":{"created":\#(created),"completed":\#(created)},"tokens":{"total":150,"input":100,"output":50}}"#)
        ].joined())

        let scan = await realScanner(dir).scan(now: now, pricing: pricing)
        XCTAssertEqual(scan?.series.daily.map(\.date), ["2026-07-05"])
        XCTAssertEqual(totalTokens(scan), 150)
    }

    func testOpenCode2APIKeyLoginIsNotAttributedDespiteStaleOAuthAuthFile() async throws {
        let dir = try DB(self)
        try dir.execute(DB.openCode2Tables + [
            DB.credential(id: "c1", integration: "openai", value: #"{"type":"key","key":"sk-x"}"#),
            assistant("m1", seq: 1, at: "2026-07-12T10:00:00.000Z", input: 100, output: 50)
        ].joined())
        let scan = await realScanner(dir, auth: oauthAuth).scan(now: now, pricing: pricing)
        XCTAssertNil(scan)
    }

    func testOpenCode2LogoutStopsAttributionDespiteStaleOAuthAuthFile() async throws {
        let dir = try DB(self)
        try dir.execute(DB.openCode2Tables + assistant("m1", seq: 1, at: "2026-07-12T10:00:00.000Z", input: 100, output: 50))
        let scan = await realScanner(dir, auth: oauthAuth).scan(now: now, pricing: pricing)
        XCTAssertNil(scan)
    }

    func testEachChannelDatabaseIsGatedAndBoundedByItsOwnLogin() async throws {
        // Stable is on an API key; preview is on ChatGPT since July 11. Only preview usage after its
        // own login counts.
        let dir = try DB(self)
        try dir.execute(DB.openCode2Tables + [
            DB.credential(id: "c1", integration: "openai", value: #"{"type":"key","key":"sk-x"}"#),
            assistant("stable", seq: 1, at: "2026-07-12T10:00:00.000Z", input: 600, output: 300)
        ].joined())
        try dir.execute(DB.openCode2Tables + [
            DB.credential(
                id: "c1", integration: "openai", value: #"{"type":"oauth","access":"live"}"#,
                created: String(ms("2026-07-11T00:00:00.000Z"))
            ),
            assistant("preview-before", seq: 1, at: "2026-07-10T10:00:00.000Z", input: 4000, output: 4000),
            assistant("preview-after", seq: 2, at: "2026-07-12T10:00:00.000Z", input: 100, output: 50)
        ].joined(), in: "opencode-next.db")

        let scan = await realScanner(dir).scan(now: now, pricing: pricing)
        XCTAssertEqual(totalTokens(scan), 150)
    }

    func testUnreadableChannelDatabaseDoesNotHideAReadableOne() async throws {
        let dir = try DB(self)
        try dir.execute(DB.openCode2Tables + [
            DB.credential(id: "c1", integration: "openai", value: #"{"type":"oauth","access":"live"}"#),
            assistant("m1", seq: 1, at: "2026-07-12T10:00:00.000Z", input: 100, output: 50)
        ].joined())
        try dir.writeCorruptDatabase("opencode-next.db")
        let scan = await realScanner(dir).scan(now: now, pricing: pricing)
        XCTAssertEqual(totalTokens(scan), 150)
    }

    func testOAuthDatabaseThatCannotBeQueriedIsAMissNotAnEmptyHistory() async {
        // Both channels are on ChatGPT. The only database with messages fails, and the sibling with
        // no message tables does not turn that into a successful empty scan.
        let sqlite = FailingDataSQLite(base: OpenCodeFakeSQLite(
            tables: ["/oc/opencode-next.db": "credential,migration"], openCode2: ["/oc/opencode-next.db"]
        ))
        sqlite.base.openAICredentials["/oc/opencode-next.db"] = #"["oauth",1,0]"#
        sqlite.base.tables["/oc/opencode.db"] = "message"
        let scanner = OpenCodeCodexUsageScanner(
            authStore: OpenCodeAuthStore(
                files: FakeFiles(["/oc/auth.json": oauthAuth]),
                environment: FakeEnvironment(["OPENCODE_DATA_DIR": "/oc"]),
                homeDirectory: { URL(fileURLWithPath: "/unused") },
                sqlite: sqlite
            ),
            sqlite: sqlite,
            databasePaths: { ["/oc/opencode-next.db", "/oc/opencode.db"] }
        )
        let scan = await scanner.scan(now: now, pricing: pricing)
        XCTAssertNil(scan)
    }

    func testOAuthChannelsWithoutMessageTablesYieldAnEmptyHistory() async {
        let sqlite = OpenCodeFakeSQLite(
            tables: ["/oc/opencode.db": "credential,migration"],
            openAICredentials: ["/oc/opencode.db": #"["oauth",1,0]"#],
            openCode2: ["/oc/opencode.db"]
        )
        let scanner = OpenCodeCodexUsageScanner(
            authStore: OpenCodeAuthStore(
                files: FakeFiles(),
                environment: FakeEnvironment(["OPENCODE_DATA_DIR": "/oc"]),
                homeDirectory: { URL(fileURLWithPath: "/unused") },
                sqlite: sqlite
            ),
            sqlite: sqlite,
            databasePaths: { ["/oc/opencode.db"] }
        )
        guard let scan = await scanner.scan(now: now, pricing: pricing) else { return XCTFail("expected a scan") }
        XCTAssertTrue(scan.series.daily.isEmpty)
        XCTAssertNil(sqlite.lastDataSQL)
    }

    func testLoginBoundAppliesOnlyToTheNewTable() throws {
        let sql = OpenCodeCodexUsageScanner.dataSQL(cutoffMs: 123, oauthSinceMs: 456)
        let union = try XCTUnwrap(sql.range(of: "UNION ALL"), sql)
        let old = sql[try XCTUnwrap(sql.range(of: "FROM message"), sql).lowerBound..<union.lowerBound]
        let new = sql[union.upperBound...]
        XCTAssertFalse(old.contains(">= 456"), String(old))
        XCTAssertTrue(new.contains("COALESCE(json_extract(data,'$.time.completed'),time_created) >= 456"), String(new))
        XCTAssertFalse(OpenCodeCodexUsageScanner.dataSQL(cutoffMs: 123).contains(">= 456"))
    }
}

/// Answers probes and credential queries from `base` and fails every usage query.
private final class FailingDataSQLite: SQLiteAccessing, @unchecked Sendable {
    let base: OpenCodeFakeSQLite
    init(base: OpenCodeFakeSQLite) { self.base = base }

    func queryValue(path: String, sql: String) throws -> String? {
        if sql.contains("json_group_array") { throw SQLiteError.queryFailed("database is locked") }
        return try base.queryValue(path: path, sql: sql)
    }

    func queryJSONRows(path: String, sql: String) throws -> String? { nil }
}
