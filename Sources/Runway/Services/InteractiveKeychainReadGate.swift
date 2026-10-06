import Foundation
import LocalAuthentication
import Security

/// Serializes every Keychain operation that may show — or must forbid — keychain UI: the
/// prompt-capable reads started by explicit user actions (`withTurn`), and the background "quiet"
/// reads that run with the process-global UI switch off (`withQuietTurn`). A manual Refresh All
/// starts providers concurrently, but macOS approval dialogs must appear one at a time — and no
/// quiet read may overlap a dialog-capable one, because the switch is process-global and would
/// silently fail the dialog the user is waiting on. Queued work remains cancellation-aware so an
/// abandoned refresh never opens a stale dialog later.
///
/// Suppression uses the deprecated process-global switch (confined to `LegacyKeychainUISwitch`,
/// see its doc) because `LAContext.interactionNotAllowed` still fails to suppress classic
/// login-keychain ACL dialogs on macOS 26.6. The switch's hazard — staying disabled around an
/// unbounded synchronous `SecItemCopyMatching` call — is what this gate's quiet turn contains:
/// the switch is only ever off inside a held quiet turn, and dialog-capable waiters bail out of a
/// stuck one after `quietHolderBailout`.
enum InteractiveKeychainReadGate {
    private static let cancellationPollInterval: TimeInterval = 0.1
    private static let condition = NSCondition()
    nonisolated(unsafe) private static var nextInteractiveTicket: UInt64 = 0
    nonisolated(unsafe) private static var interactiveQueue: [UInt64] = []
    nonisolated(unsafe) private static var inFlight = false

    /// Testable seam for the process-signature check. Production consults the real signature once;
    /// tests override it so the refusal path doesn't depend on how the test runner is signed.
    nonisolated(unsafe) static var processCanHoldDurableApprovals: @Sendable () -> Bool = {
        ProcessCodeSignature.canHoldDurableKeychainApprovals
    }

    enum Turn {
        case available
        case cancelled
        /// Refused before queueing: this build's ad-hoc signature cannot hold the durable approval
        /// the dialog would grant, so showing it would only train the user to keep re-approving.
        case ephemeralSignature
    }

    /// How long a quiet read may wait behind OTHER quiet reads. They are ms-scale (no UI can
    /// appear), so this only bites when securityd is wedged — then every waiter falls back to the
    /// metadata-only path instead of stacking up.
    private static let quietWait: TimeInterval = 2
    /// How long a MANUAL read may wait behind a stuck quiet holder before bailing out as a
    /// cancellation. Longer than `quietWait` — a user click deserves more patience — but bounded,
    /// because the hold is unattended and may never release. Var only as a test seam.
    nonisolated(unsafe) static var quietHolderBailout: TimeInterval = 5
    /// Whether the gate's current holder is a quiet (suppressed-UI) turn rather than a
    /// dialog-capable one. Guarded by `condition`'s lock.
    nonisolated(unsafe) private static var quietHolder = false

    /// Turn for a background read that runs with keychain UI globally suppressed. Returns `nil` —
    /// no gate taken, `body` not run — whenever a dialog-capable operation is queued or in flight:
    /// the UI switch is process-global, so a quiet read overlapping a user-attended read would
    /// silently fail the dialog the user is waiting on. Behind another QUIET holder it briefly
    /// waits instead — at launch every keychain provider races here at once, and skipping would
    /// park the losers on the Connect state for a full refresh cycle. While a quiet read holds the
    /// gate (milliseconds — no UI can appear), a manual read queues behind it exactly like behind
    /// another dialog. Quiet turns skip the durable-signature check: with UI provably off there is
    /// no approval to squander, so even an ad-hoc build may read silently.
    static func withQuietTurn<T>(_ body: () throws -> T) rethrows -> T? {
        condition.lock()
        let deadline = Date().addingTimeInterval(quietWait)
        while inFlight, quietHolder, interactiveQueue.isEmpty, Date() < deadline {
            condition.wait(until: deadline)
        }
        if inFlight || !interactiveQueue.isEmpty {
            condition.unlock()
            return nil
        }
        inFlight = true
        quietHolder = true
        condition.unlock()
        defer {
            condition.lock()
            inFlight = false
            quietHolder = false
            condition.broadcast()
            condition.unlock()
        }
        return try body()
    }

    static func withTurn<T>(_ body: (_ turn: Turn) throws -> T) rethrows -> T {
        guard processCanHoldDurableApprovals() else {
            AppLog.warn(.keychain, "interactive keychain read refused: this build is ad-hoc signed, so an Always Allow approval would die with the next rebuild; use a signed build (script/build_and_run.sh) to connect keychain-backed providers")
            return try body(.ephemeralSignature)
        }
        condition.lock()
        let ticket = nextInteractiveTicket
        nextInteractiveTicket &+= 1
        interactiveQueue.append(ticket)
        // Waiting behind a user-attended dialog is unbounded by design — the user is looking at
        // it. Waiting behind an unattended QUIET holder is not: quiet reads are ms-scale, so a
        // long hold means securityd is wedged, and a manual read hanging forever behind it would
        // turn Connect into a spinner that never resolves. Bail out as a cancellation — the read
        // never reached securityd, so it stores no evidence and the user can simply retry.
        var quietDeadline: Date?
        while inFlight || interactiveQueue.first != ticket {
            if Task.isCancelled {
                interactiveQueue.removeAll { $0 == ticket }
                condition.broadcast()
                condition.unlock()
                AppLog.debug(.keychain, "cancelled an interactive keychain operation while it was queued")
                return try body(.cancelled)
            }
            if inFlight, quietHolder {
                let deadline = quietDeadline ?? Date().addingTimeInterval(quietHolderBailout)
                quietDeadline = deadline
                if Date() >= deadline {
                    interactiveQueue.removeAll { $0 == ticket }
                    condition.broadcast()
                    condition.unlock()
                    AppLog.warn(.keychain, "manual keychain read gave up after \(Int(quietHolderBailout))s behind a stuck background quiet read")
                    return try body(.cancelled)
                }
            } else {
                quietDeadline = nil
            }
            condition.wait(until: Date().addingTimeInterval(cancellationPollInterval))
        }
        interactiveQueue.removeFirst()
        if Task.isCancelled {
            condition.broadcast()
            condition.unlock()
            AppLog.debug(.keychain, "cancelled an interactive keychain operation before it reached Security.framework")
            return try body(.cancelled)
        }
        inFlight = true
        condition.unlock()
        defer {
            condition.lock()
            inFlight = false
            condition.broadcast()
            condition.unlock()
        }
        return try body(.available)
    }
}

/// The single call site of the deprecated process-global keychain UI switch. Deprecated since
/// macOS 12, but still Apple's documented answer for keychain requests that target ANOTHER app's
/// items (developer.apple.com/forums/thread/693148) — the modern `kSecUseAuthenticationUI` only
/// governs your own data-protection items, and `LAContext.interactionNotAllowed` provably fails to
/// suppress classic login-keychain ACL dialogs (verified on macOS 26.6: with this switch off, an
/// unauthorized secret read fails errSecAuthFailed in milliseconds, dialog-free).
enum LegacyKeychainUISwitch {
    static func set(_ allowed: Bool) -> OSStatus {
        SecKeychainSetUserInteractionAllowed(allowed)
    }
}

/// The shared core of every background "quiet" secret read: takes the gate's quiet turn, flips the
/// process-global UI switch off for the duration (restored — loudly checked — before the turn is
/// released), runs ONE copy-matching call, and classifies the status identically for every caller.
/// Centralized so the classification, the restore check, and the locked-keychain diagnosis cannot
/// drift between the accessor and the Safe Storage readers.
enum QuietKeychainSecretRead {
    enum Outcome {
        /// `errSecSuccess` — the raw secret data (decoding belongs to the caller).
        case hit(Data?)
        case missing
        /// `errSecAuthFailed`: securityd wanted to ask and was forbidden to. The user has denied
        /// nothing — the neutral deferral; a manual read remains the path to approval.
        case needsApproval
        /// `errSecInteractionNotAllowed` (a locked login keychain needing its own unlock UI) or
        /// any other failure — states approval cannot fix.
        case unreadable(OSStatus)
    }

    /// `nil` when the quiet window is unavailable — a dialog-capable operation holds or awaits the
    /// gate, or the UI switch could not be disabled. Callers fall back to metadata-only then.
    static func perform(
        query: [String: Any],
        service: String,
        copyMatching: (CFDictionary, UnsafeMutablePointer<CFTypeRef?>?) -> OSStatus,
        setUserInteractionAllowed: (Bool) -> OSStatus
    ) -> Outcome? {
        let outcome: Outcome?? = InteractiveKeychainReadGate.withQuietTurn { () -> Outcome? in
            guard setUserInteractionAllowed(false) == errSecSuccess else { return nil }
            defer {
                // A failed restore would leave every future approval dialog suppressed
                // process-wide — manual reads would then fail errSecAuthFailed and masquerade as
                // denials. Nothing can force the restore, but it must never fail silently.
                if setUserInteractionAllowed(true) != errSecSuccess {
                    AppLog.error(.keychain, "failed to restore keychain UI after a quiet read of '\(service)'; approval dialogs may stay suppressed until relaunch")
                }
            }
            var item: CFTypeRef?
            let status = copyMatching(query as CFDictionary, &item)
            switch status {
            case errSecSuccess:
                AppLog.debug(.keychain, "quiet read hit service=\(service)")
                return .hit(item as? Data)
            case errSecItemNotFound:
                return .missing
            case errSecAuthFailed:
                AppLog.debug(.keychain, "quiet read needs approval for service '\(service)'; manual read required")
                return .needsApproval
            case errSecInteractionNotAllowed:
                AppLog.debug(.keychain, "quiet read unavailable for service '\(service)' (keychain locked)")
                return .unreadable(status)
            default:
                AppLog.warn(.keychain, "quiet read failed for service '\(service)' (status \(status))")
                return .unreadable(status)
            }
        }
        return outcome.flatMap { $0 }
    }
}

/// Per-query UI suppression for metadata-only Keychain checks. The macOS 26.6 experiment showed
/// that this context does not suppress a classic item's ACL dialog when secret data is requested,
/// so automatic paths never use it for secrets. Metadata checks do not evaluate that item ACL, but
/// a locked login keychain can still ask to authenticate; this context makes that check fail locally
/// with `errSecInteractionNotAllowed` instead of presenting an unattended unlock dialog.
enum NonInteractiveKeychainMetadataQuery {
    static func applying(to query: [String: Any]) -> [String: Any] {
        var query = query
        let context = LAContext()
        context.interactionNotAllowed = true
        query[kSecUseAuthenticationContext as String] = context
        return query
    }
}
