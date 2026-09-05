import XCTest
@testable import Runway

final class GrokLogUsageScannerTests: XCTestCase {
    private let since = RunwayISO8601.date(from: "2026-06-01T00:00:00.000Z")!

    func testParsesModernTurnCompletedUsageIntoDisjointTokenBuckets() throws {
        let line = modernUsageLine(
            timestampMilliseconds: 1_781_087_400_123,
            promptID: "prompt-1",
            model: "grok-4.6-build",
            input: 1_000,
            cacheRead: 700,
            cacheCreation: 200,
            output: 50,
            total: 1_050
        )

        let entry = try XCTUnwrap(GrokLogUsageScanner.parseSessionFile(Data(line.utf8)).first)

        XCTAssertEqual(entry.promptID, "prompt-1")
        XCTAssertEqual(entry.model, "grok-4.6-build")
        XCTAssertEqual(entry.timestamp.timeIntervalSince1970, 1_781_087_400.123, accuracy: 0.001)
        XCTAssertEqual(entry.tokens, TokenBreakdown(input: 100, cacheWrite5m: 200, cacheRead: 700, output: 50))
        XCTAssertEqual(entry.reportedTotalTokens, 1_050)
    }

    func testModernSessionScanIncludesSubagentsAndDeduplicatesForkReplay() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("runway-grok-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let main = modernUsageLine(
            timestampMilliseconds: 1_787_386_600_000,
            promptID: "shared-prompt",
            model: "grok-4.6-build",
            input: 1_000_000,
            cacheRead: 500_000,
            output: 100_000,
            total: 1_100_000
        )
        let fork = [
            main,
            modernUsageLine(
                timestampMilliseconds: 1_787_386_700_000,
                promptID: "fork-only-prompt",
                model: "grok-4.6-build",
                input: 2_000_000,
                output: 0,
                total: 2_000_000
            )
        ].joined(separator: "\n")
        let child = modernUsageLine(
            timestampMilliseconds: 1_787_386_800_000,
            promptID: "child-prompt",
            model: "grok-4.6-build",
            input: 9_000_000,
            output: 0,
            total: 9_000_000
        )
        try writeSession(root: root, name: "main", summary: "{}", updates: main)
        try writeSession(root: root, name: "fork", summary: #"{"session_kind":"fork"}"#, updates: fork)
        try writeSession(root: root, name: "child", summary: #"{"session_kind":"subagent"}"#, updates: child)

        let scanner = GrokLogUsageScanner(
            files: FakeFiles(),
            environment: FakeEnvironment(["GROK_HOME": root.path]),
            homeDirectory: { URL(fileURLWithPath: "/home/ignored") },
            incrementalScanner: IncrementalJSONLScanner<GrokLogUsageScanner.SessionEntry>()
        )
        let now = RunwayISO8601.date(from: "2026-08-22T12:00:00.000Z")!

        let scannedUsage = await scanner.scan(daysBack: 30, now: now, pricing: TestPricing.bundled)
        let usage = try XCTUnwrap(scannedUsage)

        XCTAssertEqual(usage.series.daily.count, 1)
        XCTAssertEqual(usage.series.daily.first?.totalTokens, 12_100_000)
        // Main: $1.00 uncached input + $0.25 cache read + $0.60 output. Fork-only: $4 input. Child: $18 input.
        XCTAssertEqual(usage.series.daily.first?.costUSD ?? 0, 23.85, accuracy: 0.0001)
        XCTAssertEqual(usage.modelUsage?.daily.first?.models.map(\.model), ["grok-4.6-build"])
        XCTAssertTrue(usage.unknownModelsByDay.isEmpty)
    }

    func testModernSessionDayOverridesLegacyWhileOlderLegacyDayRemains() throws {
        var modernAccumulator = DailyUsageAccumulator()
        modernAccumulator.add(day: "2026-08-22", tokens: 1_000, cost: 1, model: "grok-4.6-build")
        var legacyAccumulator = DailyUsageAccumulator()
        legacyAccumulator.add(day: "2026-08-22", tokens: 9_000, cost: 9, model: "grok-build")
        legacyAccumulator.add(day: "2026-08-21", tokens: 500, cost: 0.5, model: "grok-build")

        let merged = try XCTUnwrap(GrokLogUsageScanner.merging(
            session: modernAccumulator.build(),
            legacy: legacyAccumulator.build()
        ))

        XCTAssertEqual(
            merged.series.daily,
            [
                DailyUsageEntry(date: "2026-08-22", totalTokens: 1_000, costUSD: 1),
                DailyUsageEntry(date: "2026-08-21", totalTokens: 500, costUSD: 0.5)
            ]
        )
        XCTAssertEqual(merged.modelUsage?.daily.first?.models.map(\.model), ["grok-4.6-build"])
    }

    func testAttributesTokensToPerProcessModelAndPrices() {
        // pid 100 is on grok-build, pid 200 on grok-composer-2.5-fast; each token row prices against
        // its own process's current model.
        let log = """
        {"ts":"2026-06-10T09:00:00.000Z","pid":100,"msg":"model catalog: notifying clients","ctx":{"current_model_id":"grok-build"}}
        {"ts":"2026-06-10T09:00:00.000Z","pid":200,"msg":"model changed","ctx":{"model":"grok-composer-2.5-fast"}}
        {"ts":"2026-06-10T10:00:00.000Z","pid":100,"msg":"shell.turn.inference_done","ctx":{"prompt_tokens":1000000,"cached_prompt_tokens":0,"completion_tokens":1000000,"reasoning_tokens":0}}
        {"ts":"2026-06-10T11:00:00.000Z","pid":200,"msg":"shell.turn.inference_done","ctx":{"prompt_tokens":1000000,"cached_prompt_tokens":0,"completion_tokens":1000000,"reasoning_tokens":0}}
        """

        let usage = GrokLogUsageScanner.parse(log, since: since, pricing: TestPricing.bundled)

        let day = usage.series.daily.first { $0.date == "2026-06-10" }
        XCTAssertEqual(day?.totalTokens, 4_000_000)
        // grok-build: 1M input @ $1 + 1M output @ $2 = $3. composer-2.5-fast: 1M @ $3 + 1M @ $15 = $18.
        XCTAssertEqual(day?.costUSD ?? 0, 21.0, accuracy: 0.0001)
        let models = usage.modelUsage?.daily.first { $0.date == "2026-06-10" }?.models ?? []
        XCTAssertEqual(Set(models.map(\.model)), Set(["grok-build", "grok-composer-2.5-fast"]))
    }

    func testTracksMidProcessModelSwitch() {
        let log = """
        {"ts":"2026-06-12T08:00:00.000Z","pid":7,"msg":"model changed","ctx":{"model":"grok-build"}}
        {"ts":"2026-06-12T09:00:00.000Z","pid":7,"msg":"shell.turn.inference_done","ctx":{"prompt_tokens":1000000,"cached_prompt_tokens":0,"completion_tokens":0,"reasoning_tokens":0}}
        {"ts":"2026-06-12T10:00:00.000Z","pid":7,"msg":"model changed","ctx":{"model":"grok-composer-2.5-fast"}}
        {"ts":"2026-06-12T11:00:00.000Z","pid":7,"msg":"shell.turn.inference_done","ctx":{"prompt_tokens":1000000,"cached_prompt_tokens":0,"completion_tokens":0,"reasoning_tokens":0}}
        """

        let usage = GrokLogUsageScanner.parse(log, since: since, pricing: TestPricing.bundled)

        // First row priced as grok-build ($1/M input), second after the switch as composer-2.5-fast ($3/M).
        XCTAssertEqual(usage.series.daily.first?.costUSD ?? 0, 4.0, accuracy: 0.0001)
    }

    func testUsesCachedReadRateForCachedPromptTokens() {
        // 800k of the 1M prompt tokens are cache reads (grok-build: $0.2/M read vs $1/M input).
        let log = """
        {"ts":"2026-06-12T08:00:00.000Z","pid":1,"msg":"model changed","ctx":{"model":"grok-build"}}
        {"ts":"2026-06-12T09:00:00.000Z","pid":1,"msg":"shell.turn.inference_done","ctx":{"prompt_tokens":1000000,"cached_prompt_tokens":800000,"completion_tokens":0,"reasoning_tokens":0}}
        """

        let usage = GrokLogUsageScanner.parse(log, since: since, pricing: TestPricing.bundled)

        // 200k input @ $1/M ($0.2) + 800k cache read @ $0.2/M ($0.16) = $0.36.
        XCTAssertEqual(usage.series.daily.first?.costUSD ?? 0, 0.36, accuracy: 0.0001)
    }

    func testSkipsRowsWithoutTokenFieldsAndOutsideWindow() {
        let log = """
        {"ts":"2026-06-10T09:00:00.000Z","pid":1,"msg":"model changed","ctx":{"model":"grok-build"}}
        {"ts":"2026-05-30T09:00:00.000Z","pid":1,"msg":"shell.turn.inference_done","ctx":{"prompt_tokens":1000000,"completion_tokens":0,"reasoning_tokens":0}}
        {"ts":"2026-06-10T10:00:00.000Z","pid":1,"msg":"shell.turn.inference_done","ctx":{"loop_index":3,"model_elapsed_ms":10}}
        {"ts":"2026-06-10T11:00:00.000Z","pid":1,"msg":"shell.turn.inference_done","ctx":{"prompt_tokens":500000,"completion_tokens":0,"reasoning_tokens":0}}
        """

        let usage = GrokLogUsageScanner.parse(log, since: since, pricing: TestPricing.bundled)

        // Only the in-window, token-bearing row counts (the pre-window row and the token-less row drop).
        XCTAssertEqual(usage.series.daily.count, 1)
        XCTAssertEqual(usage.series.daily.first?.totalTokens, 500_000)
    }

    func testUnpricedModelIsExcludedFromTotalsButWarns() {
        let log = """
        {"ts":"2026-06-10T09:00:00.000Z","pid":1,"msg":"model changed","ctx":{"model":"grok-unknown-model"}}
        {"ts":"2026-06-10T10:00:00.000Z","pid":1,"msg":"shell.turn.inference_done","ctx":{"prompt_tokens":1000000,"completion_tokens":0,"reasoning_tokens":0}}
        {"ts":"2026-06-10T11:00:00.000Z","pid":2,"msg":"model changed","ctx":{"model":"grok-build"}}
        {"ts":"2026-06-10T12:00:00.000Z","pid":2,"msg":"shell.turn.inference_done","ctx":{"prompt_tokens":500000,"completion_tokens":0,"reasoning_tokens":0}}
        """

        let usage = GrokLogUsageScanner.parse(log, since: since, pricing: TestPricing.bundled)

        // Unpriceable tokens never enter the displayed totals — they surface only through the
        // warning triangle, so the tile's tokens and dollars stay coherent.
        XCTAssertEqual(usage.series.daily.first?.totalTokens, 500_000)
        XCTAssertNotNil(usage.series.daily.first?.costUSD)
        XCTAssertEqual(usage.unknownModelsByDay["2026-06-10"], ["grok-unknown-model"])
        XCTAssertEqual(usage.modelUsage?.daily.first?.models.map(\.model), ["grok-build"])
    }

    func testUnpricedModelOnlyLeavesDayUnbacked() {
        let log = """
        {"ts":"2026-06-10T09:00:00.000Z","pid":1,"msg":"model changed","ctx":{"model":"grok-unknown-model"}}
        {"ts":"2026-06-10T10:00:00.000Z","pid":1,"msg":"shell.turn.inference_done","ctx":{"prompt_tokens":1000000,"completion_tokens":0,"reasoning_tokens":0}}
        """

        let usage = GrokLogUsageScanner.parse(log, since: since, pricing: TestPricing.bundled)

        // A day with nothing priceable produces no series entry at all (→ "No data"), but the
        // unknown-model warning still names what was excluded.
        XCTAssertTrue(usage.series.daily.isEmpty)
        XCTAssertEqual(usage.unknownModelsByDay["2026-06-10"], ["grok-unknown-model"])
        XCTAssertEqual(usage.modelUsage?.daily ?? [], [])
    }

    func testUnattributedRowsAreExcludedWithoutWarning() {
        let log = """
        {"ts":"2026-06-10T10:00:00.000Z","pid":1,"msg":"shell.turn.inference_done","ctx":{"prompt_tokens":1000000,"completion_tokens":0,"reasoning_tokens":0}}
        """

        let usage = GrokLogUsageScanner.parse(log, since: since, pricing: TestPricing.bundled)

        // Tokens with no attributable model can't be priced, so they're excluded from every total —
        // and with no model name to warn about, no unknown-model entry either.
        XCTAssertTrue(usage.series.daily.isEmpty)
        XCTAssertTrue(usage.unknownModelsByDay.isEmpty)
        XCTAssertEqual(usage.modelUsage?.daily ?? [], [])
    }

    func testScanReadsGrokHomeOverride() async {
        let files = FakeFiles([
            "/custom/grok/logs/unified.jsonl": """
            {"ts":"2026-06-10T09:00:00.000Z","pid":1,"msg":"model changed","ctx":{"model":"grok-build"}}
            {"ts":"2026-06-10T10:00:00.000Z","pid":1,"msg":"shell.turn.inference_done","ctx":{"prompt_tokens":1000000,"completion_tokens":0,"reasoning_tokens":0}}
            """
        ])
        let scanner = GrokLogUsageScanner(
            files: files,
            environment: FakeEnvironment(["GROK_HOME": "/custom/grok"]),
            homeDirectory: { URL(fileURLWithPath: "/home/ignored") }
        )

        let usage = await scanner.scan(daysBack: 30, now: RunwayISO8601.date(from: "2026-06-18T00:00:00.000Z")!, pricing: TestPricing.bundled)

        XCTAssertEqual(usage?.series.daily.first?.totalTokens, 1_000_000)
    }

    func testScanReturnsNilWhenLogMissing() async {
        let warnings = GrokWarningRecorder()
        let scanner = GrokLogUsageScanner(
            files: FakeFiles(),
            environment: FakeEnvironment(),
            homeDirectory: { URL(fileURLWithPath: "/home/none") },
            readFailureWarning: warnings.record
        )

        let usage = await scanner.scan(pricing: TestPricing.bundled)
        XCTAssertNil(usage)
        XCTAssertEqual(warnings.counts, [])
    }

    func testUnreadableLogWarnsOnceUntilItRecovers() async {
        let path = "/custom/grok/logs/unified.jsonl"
        let files = FailingTextFiles(path: path)
        let warnings = GrokWarningRecorder()
        let scanner = GrokLogUsageScanner(
            files: files,
            environment: FakeEnvironment(["GROK_HOME": "/custom/grok"]),
            homeDirectory: { URL(fileURLWithPath: "/home/ignored") },
            readFailureWarning: warnings.record
        )

        _ = await scanner.scan(pricing: TestPricing.bundled)
        _ = await scanner.scan(pricing: TestPricing.bundled)
        XCTAssertEqual(warnings.counts, [1])

        files.shouldFail = false
        _ = await scanner.scan(pricing: TestPricing.bundled)
        files.shouldFail = true
        _ = await scanner.scan(pricing: TestPricing.bundled)
        XCTAssertEqual(warnings.counts, [1, 1])
    }

    private func modernUsageLine(
        timestampMilliseconds: Int,
        promptID: String,
        model: String,
        input: Int,
        cacheRead: Int = 0,
        cacheCreation: Int = 0,
        output: Int,
        total: Int
    ) -> String {
        let object: [String: Any] = [
            "timestamp": timestampMilliseconds / 1_000,
            "method": "_x.ai/session/update",
            "params": [
                "sessionId": "session-1",
                "update": [
                    "sessionUpdate": "turn_completed",
                    "prompt_id": promptID,
                    "usage": [
                        "modelUsage": [
                            model: [
                                "inputTokens": input,
                                "outputTokens": output,
                                "totalTokens": total,
                                "cachedReadTokens": cacheRead,
                                "cacheCreationTokens": cacheCreation
                            ]
                        ]
                    ]
                ],
                "_meta": ["agentTimestampMs": timestampMilliseconds]
            ]
        ]
        let data = try! JSONSerialization.data(withJSONObject: object)
        return String(decoding: data, as: UTF8.self)
    }

    private func writeSession(root: URL, name: String, summary: String, updates: String) throws {
        let directory = root.appendingPathComponent("sessions/group/\(name)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try summary.write(to: directory.appendingPathComponent("summary.json"), atomically: true, encoding: .utf8)
        let updatesURL = directory.appendingPathComponent("updates.jsonl")
        try (updates + "\n").write(to: updatesURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.modificationDate: RunwayISO8601.date(from: "2026-08-22T12:00:00.000Z")!],
            ofItemAtPath: updatesURL.path
        )
    }
}

private final class GrokWarningRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var recordedCounts: [Int] = []

    var counts: [Int] { lock.withLock { recordedCounts } }

    func record(_ count: Int) {
        lock.withLock { recordedCounts.append(count) }
    }
}

private final class FailingTextFiles: TextFileAccessing, @unchecked Sendable {
    let path: String
    var shouldFail = true

    init(path: String) {
        self.path = path
    }

    func exists(_ path: String) -> Bool { path == self.path }

    func readText(_ path: String) throws -> String {
        if shouldFail { throw TestError.unreadable }
        return ""
    }

    func writeText(_ path: String, _ text: String) throws {}
    func remove(_ path: String) throws {}

    private enum TestError: Error {
        case unreadable
    }
}
