import XCTest

/// The cleanup that keeps test runs from piling preferences files up in `~/Library/Preferences`,
/// driven against scratch directories with a fixed clock and a fake process table.
final class TestDefaultsCleanupTests: XCTestCase {
    private var root: URL!
    private var preferences: URL { root.appendingPathComponent("Preferences", isDirectory: true) }
    private var ledgerDirectory: URL { root.appendingPathComponent("Ledger", isDirectory: true) }
    private let start = Date(timeIntervalSince1970: 1_800_000_000)

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("RunwayTests.DefaultsCleanup.\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: preferences, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try FileManager.default.removeItem(at: root)
    }

    func testFinishingRunRemovesTheFilesOfTheSuitesItRecorded() throws {
        let run = makeRun(processID: 100, at: start)
        run.record("Suite.A")
        try writeFile("Suite.A")
        try writeFile("com.example.app")

        run.removeRecordedFiles()

        XCTAssertEqual(try files(), ["com.example.app.plist"], "only recorded suites are removed")
    }

    func testLaterRunSweepsFilesRewrittenAfterTheOwningProcessExited() throws {
        makeRun(processID: 100, at: start).record("Suite.A")
        try writeFile("Suite.A") // the daemon's rewrite, after process 100 exited

        makeRun(processID: 200, at: start.addingTimeInterval(10)).sweepPreviousRuns()
        XCTAssertEqual(try files(), [])

        // Rewritten once more inside the settle window: the entry is still on record, so the next
        // sweep removes the file again. Past the window the entry is dropped.
        try writeFile("Suite.A")
        let settled = start.addingTimeInterval(TestDefaultsCleanup.settleInterval + 1)
        makeRun(processID: 300, at: settled).sweepPreviousRuns()
        XCTAssertEqual(try files(), [])
        XCTAssertEqual(try ledgerSuites(), [])
    }

    func testSweepLeavesSuitesOfARunningProcessAlone() throws {
        makeRun(processID: 100, at: start).record("Suite.Live")
        try writeFile("Suite.Live")

        // Long past the settle window, but process 100 is still running its tests.
        let later = start.addingTimeInterval(TestDefaultsCleanup.settleInterval * 10)
        makeRun(processID: 200, at: later, alive: [100]).sweepPreviousRuns()

        XCTAssertEqual(try files(), ["Suite.Live.plist"])
        XCTAssertEqual(try ledgerSuites(), ["Suite.Live"], "still on record for when the process exits")
    }

    func testInterruptedRunIsSweptFromItsLedgerEntries() throws {
        // Recorded as the suite opened; the run then died without reaching its end-of-bundle cleanup.
        makeRun(processID: 100, at: start).record("Suite.Crashed")
        try writeFile("Suite.Crashed")

        makeRun(processID: 200, at: start.addingTimeInterval(TestDefaultsCleanup.settleInterval + 1))
            .sweepPreviousRuns()

        XCTAssertEqual(try files(), [])
    }

    // MARK: - Helpers

    private func makeRun(processID: Int32, at date: Date, alive: Set<Int32> = []) -> TestDefaultsCleanup {
        TestDefaultsCleanup(
            preferences: preferences,
            ledgerDirectory: ledgerDirectory,
            processID: processID,
            now: { date },
            isProcessAlive: { alive.contains($0) }
        )
    }

    private func writeFile(_ suiteName: String) throws {
        try Data("{}".utf8).write(to: preferences.appendingPathComponent("\(suiteName).plist"))
    }

    private func files() throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: preferences.path).sorted()
    }

    private func ledgerSuites() throws -> [String] {
        try String(contentsOf: ledgerDirectory.appendingPathComponent("defaults-ledger.txt"), encoding: .utf8)
            .split(separator: "\n")
            .compactMap { $0.split(separator: "\t").last.map(String.init) }
    }
}
