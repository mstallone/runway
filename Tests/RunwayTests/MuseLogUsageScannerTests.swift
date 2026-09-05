import XCTest
@testable import Runway

final class MuseLogUsageScannerTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_787_119_200)
    private var recordedAtMicros: Int { Int(now.timeIntervalSince1970 * 1_000_000) }

    func testParsesModelCompletedAndNetsCacheWithoutDoubleCountingReasoning() throws {
        let line = museCompletedLine(
            recordedAt: recordedAtMicros,
            model: "muse-spark-1.3",
            input: 1_000_000,
            output: 277,
            cached: 800_000,
            cacheRead: 800_000,
            reasoning: 236
        )

        let entry = try XCTUnwrap(MuseLogUsageScanner.parseSessionFile(Data(line.utf8)).first)

        XCTAssertEqual(entry.model, "muse-spark-1.3")
        XCTAssertEqual(entry.timestamp.timeIntervalSince1970, now.timeIntervalSince1970, accuracy: 0.001)
        XCTAssertEqual(entry.tokens, TokenBreakdown(input: 200_000, cacheRead: 800_000, output: 277))
    }

    func testIgnoresGoalUsageAttributionSoCompletionsAreNotDoubled() {
        let completed = museCompletedLine(
            id: "evt-1",
            recordedAt: recordedAtMicros,
            model: "muse-spark-1.3",
            input: 1_000,
            output: 10
        )
        let attribution = museAttributionLine(recordedAt: recordedAtMicros, input: 1_000, output: 10)
        let entries = MuseLogUsageScanner.parseSessionFile(Data((attribution + "\n" + completed).utf8))

        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(entries.first?.tokens.totalTokens, 1_010)
    }

    func testContributorAndStandardPriceAtPublishedMetaRates() {
        let standard = MuseLogUsageScanner.Entry(
            eventID: "s",
            timestamp: now,
            model: "muse-spark-1.3",
            tokens: TokenBreakdown(input: 1_000_000, output: 1_000_000)
        )
        let contributor = MuseLogUsageScanner.Entry(
            eventID: "c",
            timestamp: now,
            model: "muse-spark-1.3-contributor",
            tokens: TokenBreakdown(input: 1_000_000, output: 1_000_000)
        )

        let standardScan = MuseLogUsageScanner.aggregate([standard], since: .distantPast, pricing: TestPricing.bundled)
        let contributorScan = MuseLogUsageScanner.aggregate([contributor], since: .distantPast, pricing: TestPricing.bundled)

        // Standard: $1.25 input + $4.25 output. Contributor: $0.10 input + $0.20 output.
        XCTAssertEqual(standardScan.series.daily.first?.costUSD ?? 0, 5.50, accuracy: 0.0001)
        XCTAssertEqual(contributorScan.series.daily.first?.costUSD ?? 0, 0.30, accuracy: 0.0001)
        XCTAssertEqual(standardScan.series.daily.first?.totalTokens, 2_000_000)
    }

    func testOlderSparkLogsAliasToTheSameStandardRates() {
        let spark12 = MuseLogUsageScanner.Entry(
            eventID: "s12",
            timestamp: now,
            model: "muse-spark-1.2",
            tokens: TokenBreakdown(input: 1_000_000)
        )
        let scan = MuseLogUsageScanner.aggregate([spark12], since: .distantPast, pricing: TestPricing.bundled)
        XCTAssertEqual(scan.series.daily.first?.costUSD ?? 0, 1.25, accuracy: 0.0001)
    }

    func testCacheWriteNetsOutOfInputAndBillsAtTheInputRate() throws {
        let line = museCompletedLine(
            recordedAt: recordedAtMicros,
            model: "muse-spark-1.3",
            input: 1_000_000,
            output: 0,
            cached: 100_000,
            cacheRead: 100_000,
            cacheWrite: 200_000
        )
        let entry = try XCTUnwrap(MuseLogUsageScanner.parseSessionFile(Data(line.utf8)).first)
        XCTAssertEqual(
            entry.tokens,
            TokenBreakdown(input: 700_000, cacheWrite5m: 200_000, cacheRead: 100_000, output: 0)
        )

        let scan = MuseLogUsageScanner.aggregate(
            [entry],
            since: .distantPast,
            pricing: TestPricing.bundled
        )
        // 700k input + 200k cache-write at $1.25, plus 100k cache-read at $0.15.
        XCTAssertEqual(scan.series.daily.first?.costUSD ?? 0, 1.14, accuracy: 0.0001)
    }

    func testUnpricedModelIsExcludedFromTotalsButWarns() {
        let unknown = MuseLogUsageScanner.Entry(
            eventID: "u",
            timestamp: now,
            model: "muse-unknown-model",
            tokens: TokenBreakdown(input: 1_000_000)
        )
        let priced = MuseLogUsageScanner.Entry(
            eventID: "p",
            timestamp: now,
            model: "muse-spark-1.3",
            tokens: TokenBreakdown(input: 500_000)
        )
        let scan = MuseLogUsageScanner.aggregate([unknown, priced], since: .distantPast, pricing: TestPricing.bundled)
        let day = DailyUsageAccumulator.dayKey(from: now)

        XCTAssertEqual(scan.series.daily.first?.totalTokens, 500_000)
        XCTAssertEqual(scan.unknownModelsByDay[day], ["muse-unknown-model"])
        XCTAssertEqual(scan.modelUsage?.daily.first?.models.map(\.model), ["muse-spark-1.3"])
    }

    func testScanIncludesSubagentLogsAndHonorsXDGDataHome() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("runway-muse-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let parent = museCompletedLine(
            id: "parent",
            recordedAt: recordedAtMicros,
            model: "muse-spark-1.3",
            input: 1_000_000,
            output: 0
        )
        let child = museCompletedLine(
            id: "child",
            recordedAt: recordedAtMicros,
            model: "muse-spark-1.3",
            input: 2_000_000,
            output: 0
        )
        try writeSession(root: root, sessionID: "session-a", lines: parent)
        try writeSession(root: root, sessionID: "session-a", subagent: "sub-1", lines: child)

        let scanner = MuseLogUsageScanner(
            files: LocalTextFileAccessor(),
            environment: FakeEnvironment(["XDG_DATA_HOME": root.path]),
            homeDirectory: { URL(fileURLWithPath: "/home/ignored") },
            incrementalScanner: IncrementalJSONLScanner<MuseLogUsageScanner.Entry>()
        )

        XCTAssertTrue(scanner.hasSessionFootprint())
        let scan = await scanner.scan(daysBack: 30, now: now, pricing: TestPricing.bundled)
        let usage = try XCTUnwrap(scan)
        XCTAssertEqual(usage.series.daily.first?.totalTokens, 3_000_000)
        XCTAssertEqual(usage.series.daily.first?.costUSD ?? 0, 3.75, accuracy: 0.0001)
    }

    func testScanReturnsNilWhenSessionsAreMissing() async {
        let scanner = MuseLogUsageScanner(
            files: FakeFiles(),
            environment: FakeEnvironment(["XDG_DATA_HOME": "/tmp/runway-muse-missing"]),
            homeDirectory: { URL(fileURLWithPath: "/home/none") },
            incrementalScanner: IncrementalJSONLScanner<MuseLogUsageScanner.Entry>()
        )

        XCTAssertFalse(scanner.hasSessionFootprint())
        let usage = await scanner.scan(now: now, pricing: TestPricing.bundled)
        XCTAssertNil(usage)
    }

    func testDedupDropsCopiedCompletionsWithTheSameEnvelopeID() {
        let line = museCompletedLine(
            id: "same-event",
            recordedAt: recordedAtMicros,
            model: "muse-spark-1.3",
            input: 1_000,
            output: 0
        )
        let entries = MuseLogUsageScanner.parseSessionFile(Data((line + "\n" + line).utf8))
        XCTAssertEqual(MuseLogUsageScanner.dedup(entries).count, 1)
    }

    private func writeSession(
        root: URL,
        sessionID: String,
        subagent: String? = nil,
        lines: String
    ) throws {
        var directory = root.appendingPathComponent("muse/sessions/2026/08/18/\(sessionID)", isDirectory: true)
        if let subagent {
            directory = directory
                .appendingPathComponent("subagent", isDirectory: true)
                .appendingPathComponent(subagent, isDirectory: true)
        }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appendingPathComponent("session.jsonl")
        try (lines + "\n").write(to: file, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.modificationDate: now], ofItemAtPath: file.path)
    }
}

func museCompletedLine(
    id: String = "evt-1",
    recordedAt: Int,
    model: String,
    input: Int,
    output: Int,
    cached: Int = 0,
    cacheRead: Int? = nil,
    cacheWrite: Int = 0,
    reasoning: Int = 0
) -> String {
    let object: [String: Any] = [
        "schema_version": 1,
        "id": id,
        "sequence": 50,
        "recorded_at": recordedAt,
        "record_type": "event",
        "durability": "durable",
        "payload_type": "runtime.session",
        "payload": [
            "kind": "run",
            "event": [
                "kind": "model_completed",
                "model": model,
                "usage": [
                    "input_tokens": input,
                    "output_tokens": output,
                    "cached_tokens": cached,
                    "cache_write_tokens": cacheWrite,
                    "cache_read_tokens": cacheRead ?? cached,
                    "reasoning_tokens": reasoning
                ]
            ]
        ]
    ]
    return museJSONLine(object)
}

private func museAttributionLine(recordedAt: Int, input: Int, output: Int) -> String {
    let object: [String: Any] = [
        "schema_version": 1,
        "id": "attr-1",
        "sequence": 49,
        "recorded_at": recordedAt,
        "record_type": "event",
        "payload_type": "runtime.session",
        "payload": [
            "kind": "run",
            "event": [
                "kind": "goal_usage_attribution",
                "record": [
                    "quantity": [
                        "input_tokens": input,
                        "output_tokens": output,
                        "cached_tokens": 0,
                        "reasoning_tokens": 0
                    ]
                ]
            ]
        ]
    ]
    return museJSONLine(object)
}

func museJSONLine(_ object: [String: Any]) -> String {
    let data = try! JSONSerialization.data(withJSONObject: object)
    return String(decoding: data, as: UTF8.self)
}
