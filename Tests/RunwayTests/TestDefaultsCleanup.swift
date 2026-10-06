import Foundation
import XCTest

extension UserDefaults {
    /// The test target's way to open a scratch suite. Identical to `init(suiteName:)`, but records the
    /// suite so its preferences file is removed from `~/Library/Preferences` instead of piling up there
    /// (every suite name is unique per run, so nothing else ever reclaims them).
    convenience init?(testSuiteName suiteName: String) {
        self.init(suiteName: suiteName)
        TestDefaultsCleanup.shared.register(suiteName)
    }
}

/// Removes the preferences files test suites leave behind.
///
/// `removePersistentDomain` does not delete a suite's file: the preferences daemon writes an empty one
/// a few seconds later, and rewrites it even if it is unlinked in the meantime. So cleanup is two-step:
/// when the bundle finishes, each suite is flushed and its file unlinked, which sticks for every suite
/// that never had its populated domain removed; the names are also appended to a ledger, and the next
/// run's first suite sweeps whatever the daemon rewrote after this process exited.
final class TestDefaultsCleanup: NSObject, XCTestObservation, @unchecked Sendable {
    static let shared = TestDefaultsCleanup()

    /// Ledger entries newer than this may belong to a run that just finished and whose files the
    /// daemon has yet to rewrite; they are kept for a later sweep.
    private static let settleInterval: TimeInterval = 60

    private let lock = NSLock()
    private var suiteNames: Set<String> = []
    private var started = false
    private let preferences = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Preferences", isDirectory: true)
    private let ledger = FileManager.default.temporaryDirectory
        .appendingPathComponent("RunwayTests.defaults-ledger.txt")

    func register(_ suiteName: String) {
        let isFirst = lock.withLock {
            suiteNames.insert(suiteName)
            defer { started = true }
            return !started
        }
        guard isFirst else { return }
        sweepPreviousRuns()
        XCTestObservationCenter.shared.addTestObserver(self)
    }

    func testBundleDidFinish(_ testBundle: Bundle) {
        let names = lock.withLock { suiteNames }
        for name in names {
            CFPreferencesAppSynchronize(name as CFString)
            removeFile(for: name)
        }
        let stamp = Date().timeIntervalSince1970
        appendToLedger(names.map { "\(stamp)\t\($0)" })
    }

    private func sweepPreviousRuns() {
        guard let text = try? String(contentsOf: ledger, encoding: .utf8) else { return }
        let cutoff = Date().timeIntervalSince1970 - Self.settleInterval
        var kept: [String] = []
        for line in text.split(separator: "\n") {
            let fields = line.split(separator: "\t", maxSplits: 1)
            guard fields.count == 2, let stamp = TimeInterval(fields[0]) else { continue }
            if stamp > cutoff {
                kept.append(String(line))
            } else {
                removeFile(for: String(fields[1]))
            }
        }
        try? kept.joined(separator: "\n").appending(kept.isEmpty ? "" : "\n")
            .write(to: ledger, atomically: true, encoding: .utf8)
    }

    private func appendToLedger(_ lines: [String]) {
        guard !lines.isEmpty else { return }
        let existing = (try? String(contentsOf: ledger, encoding: .utf8)) ?? ""
        try? (existing + lines.joined(separator: "\n") + "\n").write(to: ledger, atomically: true, encoding: .utf8)
    }

    private func removeFile(for suiteName: String) {
        try? FileManager.default.removeItem(at: preferences.appendingPathComponent("\(suiteName).plist"))
    }
}
