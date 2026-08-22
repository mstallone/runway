import Foundation
import XCTest
@testable import Runway

final class JSONLScannerCancellationTests: XCTestCase {
    func testCancelledQueuedScanReturnsNilAndNeverInvokesItsParser() async throws {
        let base = try makeDirectory("Queue")
        defer { try? FileManager.default.removeItem(at: base) }
        let file = try makeIntegerFile(in: base)
        let scanner = IncrementalJSONLScanner<Int>()
        let blockingParser = BlockingParser()
        let firstTask = Task {
            await scanner.items(
                from: [file], since: .distantPast, cacheIdentity: "shared-home", parse: blockingParser.parse
            )
        }
        guard await waitUntil({ blockingParser.hasStarted }) else {
            blockingParser.unblock()
            firstTask.cancel()
            _ = await firstTask.value
            return XCTFail("the first parser did not start before the timeout")
        }

        let queuedParser = ParseCounter()
        let queuedTask = Task {
            await scanner.items(
                from: [file], since: .distantPast, cacheIdentity: "shared-home", parse: queuedParser.parse
            )
        }
        guard await waitUntil({ await scanner.queuedScanCountForTesting(identity: "shared-home") > 0 }) else {
            queuedTask.cancel()
            blockingParser.unblock()
            _ = await firstTask.value
            _ = await queuedTask.value
            return XCTFail("the second scan did not queue before the timeout")
        }
        queuedTask.cancel()
        blockingParser.unblock()

        let firstResult = await firstTask.value
        let queuedResult = await queuedTask.value
        XCTAssertEqual(firstResult, [7])
        XCTAssertNil(queuedResult)
        XCTAssertEqual(queuedParser.count, 0)
    }

    func testCancelledClaudeScanIsNotAnAuthoritativeEmptyHistory() async throws {
        let now = Date()
        let home = try ClaudeLogFixture.makeHome(files: [
            "project/session.jsonl": ClaudeLogFixture.usageLine(
                timestamp: RunwayISO8601.string(from: now),
                input: 10,
                output: 5,
                costUSD: 0.25
            )
        ])
        defer { try? FileManager.default.removeItem(at: home) }
        let file = try XCTUnwrap(JSONLScanning.jsonlFiles(under: home.appendingPathComponent("projects")).first)
        let incremental = IncrementalJSONLScanner<ClaudeLogUsageScanner.Entry>()
        let blockingParser = BlockingClaudeParser()
        let firstTask = Task {
            await incremental.items(
                from: [file],
                since: .distantPast,
                cacheIdentity: "shared-home",
                parse: blockingParser.parse
            )
        }
        guard await waitUntil({ blockingParser.hasStarted }) else {
            blockingParser.unblock()
            firstTask.cancel()
            _ = await firstTask.value
            return XCTFail("the first parser did not start before the timeout")
        }

        let scanner = ClaudeLogUsageScanner(
            environment: FakeEnvironment(["CLAUDE_CONFIG_DIR": home.path]),
            homeDirectory: { home },
            incrementalScanner: incremental,
            cacheIdentityOverride: "shared-home"
        )
        let cancelledTask = Task {
            await scanner.scan(now: now, pricing: TestPricing.bundled)
        }
        guard await waitUntil({ await incremental.queuedScanCountForTesting(identity: "shared-home") > 0 }) else {
            cancelledTask.cancel()
            blockingParser.unblock()
            _ = await firstTask.value
            _ = await cancelledTask.value
            return XCTFail("the Claude scan did not queue before the timeout")
        }
        cancelledTask.cancel()
        blockingParser.unblock()

        _ = await firstTask.value
        let cancelledResult = await cancelledTask.value
        XCTAssertNil(cancelledResult)
    }

    func testCancelledGrokSessionScanDoesNotPublishTheLegacyFallback() async throws {
        let root = try makeDirectory("Grok")
        defer { try? FileManager.default.removeItem(at: root) }
        let sessionDirectory = root.appendingPathComponent("sessions/group/main", isDirectory: true)
        try FileManager.default.createDirectory(at: sessionDirectory, withIntermediateDirectories: true)
        try #"{"session_kind":"main"}"#.write(
            to: sessionDirectory.appendingPathComponent("summary.json"),
            atomically: true,
            encoding: .utf8
        )
        let updatesURL = sessionDirectory.appendingPathComponent("updates.jsonl")
        try Data(#"{"params":{"update":{"sessionUpdate":"turn_completed"}}}"#.utf8).write(to: updatesURL)
        let sessionFile = try XCTUnwrap(
            JSONLScanning.jsonlFiles(under: root.appendingPathComponent("sessions")).first
        )
        let identity = root.appendingPathComponent("sessions")
            .resolvingSymlinksInPath()
            .standardizedFileURL.path
        let incremental = IncrementalJSONLScanner<GrokLogUsageScanner.SessionEntry>()
        let blockingParser = BlockingGrokParser()
        let firstTask = Task {
            await incremental.items(
                from: [sessionFile],
                since: .distantPast,
                cacheIdentity: identity,
                parse: blockingParser.parse
            )
        }
        guard await waitUntil({ blockingParser.hasStarted }) else {
            blockingParser.unblock()
            firstTask.cancel()
            _ = await firstTask.value
            return XCTFail("the first Grok parser did not start before the timeout")
        }

        let logPath = root.appendingPathComponent("logs/unified.jsonl").path
        let legacy = """
        {"ts":"2026-08-22T09:00:00.000Z","pid":1,"msg":"model changed","ctx":{"model":"grok-build"}}
        {"ts":"2026-08-22T10:00:00.000Z","pid":1,"msg":"shell.turn.inference_done","ctx":{"prompt_tokens":1000}}
        """
        let scanner = GrokLogUsageScanner(
            files: FakeFiles([logPath: legacy]),
            environment: FakeEnvironment(["GROK_HOME": root.path]),
            homeDirectory: { root },
            incrementalScanner: incremental
        )
        let cancelledTask = Task {
            await scanner.scan(
                now: RunwayISO8601.date(from: "2026-08-22T12:00:00.000Z")!,
                pricing: TestPricing.bundled
            )
        }
        guard await waitUntil({ await incremental.queuedScanCountForTesting(identity: identity) > 0 }) else {
            cancelledTask.cancel()
            blockingParser.unblock()
            _ = await firstTask.value
            _ = await cancelledTask.value
            return XCTFail("the Grok scan did not queue before the timeout")
        }
        cancelledTask.cancel()
        blockingParser.unblock()

        _ = await firstTask.value
        let cancelledResult = await cancelledTask.value
        XCTAssertNil(cancelledResult)
    }

    func testCancellationDuringParseReturnsNilWithoutPersistingPartialCache() async throws {
        let base = try makeDirectory("ActiveParse")
        defer { try? FileManager.default.removeItem(at: base) }
        let first = try makeIntegerFile(named: "first.jsonl", value: 1, in: base)
        let second = try makeIntegerFile(named: "second.jsonl", value: 2, in: base)
        let persistence = JSONLScanCachePersistence(
            namespace: "test",
            schemaVersion: 1,
            directory: base.appendingPathComponent("cache"),
            writeDebounce: .milliseconds(1)
        )
        let scanner = IncrementalJSONLScanner<Int>(maxConcurrentParses: 1, persistence: persistence)
        let blockingParser = BlockingParser()
        let task = Task {
            await scanner.items(
                from: [first, second],
                since: .distantPast,
                cacheIdentity: "home",
                parse: blockingParser.parse
            )
        }
        guard await waitUntil({ blockingParser.hasStarted }) else {
            blockingParser.unblock()
            task.cancel()
            _ = await task.value
            return XCTFail("the parser did not start before the timeout")
        }
        task.cancel()
        blockingParser.unblock()

        let cancelledResult = await task.value
        XCTAssertNil(cancelledResult)
        await scanner.waitForPendingWritesForTesting()

        let reloadCounter = ParseCounter()
        let reloaded = IncrementalJSONLScanner<Int>(persistence: persistence)
        let reloadedItems = await reloaded.items(
            from: [first, second],
            since: .distantPast,
            cacheIdentity: "home",
            parse: reloadCounter.parse
        )
        XCTAssertEqual(reloadedItems, [1, 2])
        XCTAssertEqual(reloadCounter.count, 2)
    }

    private func waitUntil(
        _ condition: @escaping @Sendable () async -> Bool
    ) async -> Bool {
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while ContinuousClock.now < deadline {
            if await condition() { return true }
            try? await Task.sleep(for: .milliseconds(1))
        }
        return await condition()
    }

    private func makeDirectory(_ suffix: String) throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("RunwayScannerCancellation\(suffix)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private func makeIntegerFile(
        named name: String = "usage.jsonl",
        value: Int = 7,
        in directory: URL
    ) throws -> JSONLScanning.DiscoveredFile {
        let url = directory.appendingPathComponent(name)
        try Data(String(value).utf8).write(to: url)
        let values = try url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
        return JSONLScanning.DiscoveredFile(
            path: url.path,
            size: try XCTUnwrap(values.fileSize),
            mtime: try XCTUnwrap(values.contentModificationDate)
        )
    }
}

private final class BlockingClaudeParser: @unchecked Sendable {
    private let lock = NSLock()
    private var started = false
    private let release = DispatchSemaphore(value: 0)

    var hasStarted: Bool {
        lock.withLock { started }
    }

    func parse(_ data: Data) -> [ClaudeLogUsageScanner.Entry]? {
        lock.withLock { started = true }
        release.wait()
        return ClaudeLogUsageScanner.parseFile(data)
    }

    func unblock() {
        release.signal()
    }
}

private final class BlockingGrokParser: @unchecked Sendable {
    private let lock = NSLock()
    private var started = false
    private let release = DispatchSemaphore(value: 0)

    var hasStarted: Bool {
        lock.withLock { started }
    }

    func parse(_ data: Data) -> [GrokLogUsageScanner.SessionEntry]? {
        lock.withLock { started = true }
        release.wait()
        return GrokLogUsageScanner.parseSessionFile(data)
    }

    func unblock() {
        release.signal()
    }
}
