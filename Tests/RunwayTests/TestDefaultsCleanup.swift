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
/// a few seconds later, and rewrites it even if it is unlinked in the meantime. So cleanup is two-step.
/// Each suite name is appended to a ledger the moment it is opened (so a crashed or interrupted run is
/// still on record). When the bundle finishes, every suite is flushed and its file unlinked, which
/// sticks for most. The next run's first suite then sweeps the ledger, removing whatever the daemon
/// rewrote after the earlier process exited.
final class TestDefaultsCleanup: NSObject, XCTestObservation, @unchecked Sendable {
    static let shared = TestDefaultsCleanup()

    /// Ledger entries newer than this may belong to a run that is still going, or one whose files the
    /// daemon has yet to rewrite; they are kept for a later sweep.
    private static let settleInterval: TimeInterval = 5 * 60

    private let lock = NSLock()
    private var suiteNames: Set<String> = []
    private var started = false
    private let preferences = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Preferences", isDirectory: true)
    /// Outside the temp directory on purpose: macOS purges that, and a lost ledger strands its files.
    private let ledger = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Caches/RunwayTests/defaults-ledger.txt")

    func register(_ suiteName: String) {
        let (isNew, isFirst) = lock.withLock {
            let inserted = suiteNames.insert(suiteName).inserted
            defer { started = true }
            return (inserted, !started)
        }
        if isFirst {
            sweepPreviousRuns()
            // XCTest delivers observer callbacks on the main thread; register there too.
            if Thread.isMainThread {
                XCTestObservationCenter.shared.addTestObserver(self)
            } else {
                DispatchQueue.main.async { XCTestObservationCenter.shared.addTestObserver(self) }
            }
        }
        if isNew {
            appendToLedger(["\(Date().timeIntervalSince1970)\t\(suiteName)"])
        }
    }

    func testBundleDidFinish(_ testBundle: Bundle) {
        for name in lock.withLock({ suiteNames }) {
            CFPreferencesAppSynchronize(name as CFString)
            removeFile(for: name)
        }
    }

    /// Removes every settled suite's file and rewrites the ledger with the entries still settling.
    private func sweepPreviousRuns() {
        withLedgerLock {
            guard FileManager.default.fileExists(atPath: ledger.path) else { return }
            let text = try String(contentsOf: ledger, encoding: .utf8)
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
            try kept.map { $0 + "\n" }.joined().write(to: ledger, atomically: true, encoding: .utf8)
        }
    }

    private func appendToLedger(_ lines: [String]) {
        withLedgerLock {
            let descriptor = open(ledger.path, O_WRONLY | O_APPEND | O_CREAT, 0o644)
            guard descriptor >= 0 else { throw CocoaError(.fileWriteUnknown) }
            let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
            try handle.write(contentsOf: Data(lines.map { $0 + "\n" }.joined().utf8))
        }
    }

    /// Runs `body` holding an exclusive `flock` on a sibling lock file, so test processes in other
    /// worktrees never read, rewrite, or append to the ledger at the same time.
    private func withLedgerLock(_ body: () throws -> Void) {
        do {
            let directory = ledger.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let descriptor = open(directory.appendingPathComponent("defaults-ledger.lock").path, O_RDWR | O_CREAT, 0o644)
            guard descriptor >= 0, flock(descriptor, LOCK_EX) == 0 else {
                if descriptor >= 0 { close(descriptor) }
                throw CocoaError(.fileLocking)
            }
            defer {
                flock(descriptor, LOCK_UN)
                close(descriptor)
            }
            try body()
        } catch {
            warn("could not update \(ledger.path): \(error.localizedDescription)")
        }
    }

    private func removeFile(for suiteName: String) {
        do {
            try FileManager.default.removeItem(at: preferences.appendingPathComponent("\(suiteName).plist"))
        } catch let error as CocoaError where error.code == .fileNoSuchFile {
            // Never flushed, or already swept.
        } catch {
            warn("could not remove \(suiteName).plist: \(error.localizedDescription)")
        }
    }

    private func warn(_ message: String) {
        FileHandle.standardError.write(Data("TestDefaultsCleanup: \(message)\n".utf8))
    }
}
