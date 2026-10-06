import CryptoKit
import Foundation
import Security

enum NonInteractiveKeychainRead: Equatable, Sendable {
    case value(String)
    case missing
    case unavailable
}

/// Read-only view of the Keychain. Stores that consume another app's credentials (Claude, Copilot,
/// Antigravity, the default-account observer) receive ONLY this type, so writing a foreign
/// credential store is unrepresentable there at compile time — the ownership rule "only the app
/// that owns a credential may modify it", enforced by the type system.
protocol KeychainReading: Sendable {
    func readGenericPassword(service: String) throws -> String?
    func readGenericPasswordForCurrentUser(service: String) throws -> String?
    /// Interactive Security.framework reads used only after an explicit user action. These are
    /// separate requirements from the historical `security`-CLI reads so another app's Keychain ACL
    /// grants access to Runway itself, not to the `/usr/bin/security` helper process.
    func readGenericPasswordAllowingUserInteraction(service: String) throws -> String?
    func readGenericPasswordForCurrentUserAllowingUserInteraction(service: String) throws -> String?
    /// Returns a manually seeded in-memory value when its metadata is unchanged. Production never
    /// requests foreign secret data here; `.unavailable` means a manual read is required or the
    /// Keychain metadata could not be inspected.
    func readGenericPasswordWithoutUserInteraction(service: String) -> NonInteractiveKeychainRead
    func readGenericPasswordForCurrentUserWithoutUserInteraction(service: String) -> NonInteractiveKeychainRead
    /// Read a generic password scoped to an explicit account (`-a`). Used when another app stored the
    /// item under a known account name (e.g. Antigravity's `agy` token under service `gemini`,
    /// account `antigravity`) rather than the current user.
    func readGenericPassword(service: String, account: String) throws -> String?
    /// Account-scoped variants of the non-interactive / explicit-user-action reads, for foreign
    /// items stored under a known account name. Automatic refreshes use the non-interactive form
    /// (never a prompt); the interactive form runs only on a manual refresh and authorizes Runway
    /// itself, not a helper process.
    func readGenericPasswordWithoutUserInteraction(service: String, account: String) -> NonInteractiveKeychainRead
    func readGenericPasswordAllowingUserInteraction(service: String, account: String) throws -> String?
    /// Attributes-only existence probes. Keeping both overloads as protocol requirements is essential:
    /// callers hold `any KeychainReading`, so an extension-only service overload would statically call
    /// the fallback secret read instead of production's prompt-free Security.framework implementation.
    /// `nil` means the probe failed, not that the item is absent.
    func genericPasswordExists(service: String) -> Bool?
    func genericPasswordExists(service: String, account: String) -> Bool?
    /// Existence probe for the CURRENT-USER item specifically. It shares the exact
    /// `(service, currentUser)` identity that `readGenericPasswordForCurrentUserWithoutUserInteraction`
    /// uses, so a recovery probe joins that read's flight and breaker instead of launching an
    /// unrelated service-wide query that neither waits on it nor sees it fail.
    func genericPasswordForCurrentUserExists(service: String) -> Bool?
    /// Why this item's last read failed (`.manualReadDeferred` = the item exists and the automatic
    /// path deliberately did not read its secret, `.permissionDenied` = an attempted read was
    /// denied, `.unreadable` = its metadata could not be inspected), `nil` = no failure recorded.
    func lastReadFailure(service: String, account: String) -> KeychainReadFailure?
    /// The same verdict for a SERVICE-WIDE read (no account), which is a distinct coordinator key
    /// from any account-scoped read of the same service.
    func lastReadFailure(service: String) -> KeychainReadFailure?
    /// The same verdict for the CURRENT-USER item, whose account name only the accessor knows.
    func lastReadFailureForCurrentUser(service: String) -> KeychainReadFailure?
    /// Opaque digest of an account-scoped item's non-secret attributes (including its modification
    /// date). Discovery binds a cached account identity to this so replacing a keyring item invalidates
    /// the old identity without reading its secret on the launch path.
    func genericPasswordAttributeFingerprint(service: String, account: String) -> String?
}

/// Every Keychain operation here goes through Security.framework in this process. There is no `/usr/bin/security`
/// path any more: a subprocess's approval names the helper binary rather than Runway, so it could
/// never turn into a durable Always Allow — which is how one approval became a recurring prompt.
struct SecurityKeychainAccessor: KeychainReading {
    private static let metadataTimestampResolution: TimeInterval = 1
    private static let metadataStabilizationLimit: TimeInterval = 2

    /// Gates every in-process secret read: change-gated caching, single-flight per item, and a
    /// circuit breaker after denials. See `KeychainReadCoordinator`.
    let coordinator: KeychainReadCoordinator
    private let metadataNow: @Sendable () -> Date
    private let waitForMetadataStability: @Sendable (TimeInterval) -> Void
    private let copyMatching: @Sendable (CFDictionary, UnsafeMutablePointer<CFTypeRef?>?) -> OSStatus
    private let setUserInteractionAllowed: @Sendable (Bool) -> OSStatus
    private let partitionWallFallback: @Sendable (String, String?) -> String?

    init(
        coordinator: KeychainReadCoordinator = .shared,
        metadataNow: @escaping @Sendable () -> Date = Date.init,
        waitForMetadataStability: @escaping @Sendable (TimeInterval) -> Void = {
            Thread.sleep(forTimeInterval: $0)
        },
        copyMatching: @escaping @Sendable (CFDictionary, UnsafeMutablePointer<CFTypeRef?>?) -> OSStatus = {
            SecItemCopyMatching($0, $1)
        },
        setUserInteractionAllowed: @escaping @Sendable (Bool) -> OSStatus = {
            LegacyKeychainUISwitch.set($0)
        },
        partitionWallFallback: @escaping @Sendable (String, String?) -> String? = { service, account in
            PartitionWallFallbackReader().read(service: service, account: account)
        }
    ) {
        self.coordinator = coordinator
        self.metadataNow = metadataNow
        self.waitForMetadataStability = waitForMetadataStability
        self.copyMatching = copyMatching
        self.setUserInteractionAllowed = setUserInteractionAllowed
        self.partitionWallFallback = partitionWallFallback
    }

    /// The plain throwing reads are protocol requirements that exist for mocks; no auth store calls
    /// them, because each one picks the explicit non-interactive or interactive form. They are
    /// implemented here through the automatic metadata/cache-only path so that even a future caller
    /// cannot request foreign secret data without choosing the interactive API.
    func readGenericPassword(service: String) throws -> String? {
        try promptFreeValue(service: service, account: nil)
    }

    private func promptFreeValue(service: String, account: String?) throws -> String? {
        // Through the coordinator, not straight at Security: these reads get the same single-flight,
        // change-gating, and breaker as every other one, and the read is handed the ticket it needs
        // to attribute what it observes.
        switch readGenericPasswordWithoutUserInteraction(service: service, account: account) {
        case .value(let value):
            return value
        case .missing:
            return nil
        case .unavailable:
            throw KeychainError.readFailed("The keychain item could not be read without asking you.")
        }
    }

    func readGenericPasswordAllowingUserInteraction(service: String) throws -> String? {
        try readGenericPasswordAllowingUserInteraction(service: service, account: nil)
    }

    func readGenericPasswordForCurrentUserAllowingUserInteraction(service: String) throws -> String? {
        try readGenericPasswordAllowingUserInteraction(service: service, account: currentUserAccount())
    }

    func readGenericPasswordAllowingUserInteraction(service: String, account: String) throws -> String? {
        try readGenericPasswordAllowingUserInteraction(service: service, account: account as String?)
    }

    private func readGenericPasswordAllowingUserInteraction(
        service: String,
        account: String?
    ) throws -> String? {
        try coordinator.interactiveRead(
            service: service,
            account: account,
            fingerprint: { stabilizedAttributeFingerprint(service: service, account: account) },
            read: { ticket in try performInteractiveRead(service: service, account: account, ticket: ticket) }
        )
    }

    /// Runs the approval query inside Runway. Keychain access-control decisions, including
    /// "Always Allow", are attached to the requesting executable, so routing this through the
    /// `security` command would authorize that helper rather than Runway's future manual reads.
    private func performInteractiveRead(
        service: String,
        account: String?,
        ticket: KeychainReadCoordinator.ReadTicket
    ) throws -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecMatchLimit as String: kSecMatchLimitOne,
            kSecReturnData as String: true,
        ].merging(account.map { [kSecAttrAccount as String: $0] } ?? [:]) { current, _ in current }
        var item: CFTypeRef?
        var gateTurn = InteractiveKeychainReadGate.Turn.available
        let status = InteractiveKeychainReadGate.withTurn { turn -> OSStatus in
            gateTurn = turn
            guard turn == .available else { return errSecNotAvailable }
            return copyMatching(query as CFDictionary, &item)
        }
        if gateTurn == .ephemeralSignature {
            // The read never reached securityd, so like a cancellation it is no evidence about
            // this item: nothing is stored and the breaker stays untouched — quiet reads remain
            // free to keep succeeding where they can. The existence probe downstream classifies
            // the item as the neutral deferral (Connect state), never a permission warning whose
            // Always Allow advice this build cannot honor.
            coordinator.recordContention(ticket)
            throw KeychainError.readFailed("This build can't hold keychain approvals (ad-hoc signature). Use a signed build to connect.")
        }
        if status != errSecSuccess && status != errSecItemNotFound && gateTurn != .available {
            // The refresh was cancelled before this read reached Security.framework. A synthetic
            // failure says nothing about the item's ACL and must not trip its breaker.
            coordinator.recordContention(ticket)
            AppLog.warn(.keychain, "interactive read for service '\(service)' was cancelled before reaching Security.framework")
            throw KeychainError.readFailed("The keychain was busy. Try refreshing again.")
        }
        switch status {
        case errSecSuccess:
            guard let data = item as? Data,
                  let value = String(data: data, encoding: .utf8)
            else {
                return ""
            }
            return value
        case errSecItemNotFound:
            return nil
        default:
            // The user just answered the dialog, so a denial here is the strongest evidence about
            // this item's ACL there is. Record it: this read trips the breaker, and every later
            // probe is then answered locally with no status to classify.
            let denied = status == errSecAuthFailed
                || status == errSecInteractionNotAllowed
                || status == errSecUserCanceled
                || status == errAuthorizationDenied
            coordinator.recordFailureCategory(ticket, category: denied ? .permissionDenied : .unreadable)
            let message = SecCopyErrorMessageString(status, nil) as String?
                ?? "Keychain read failed with status \(status)."
            AppLog.warn(.keychain, "in-process read failed for service '\(service)' (status \(status))")
            throw KeychainError.readFailed(message)
        }
    }

    func readGenericPasswordWithoutUserInteraction(service: String) -> NonInteractiveKeychainRead {
        readGenericPasswordWithoutUserInteraction(service: service, account: nil)
    }

    func readGenericPasswordForCurrentUserWithoutUserInteraction(service: String) -> NonInteractiveKeychainRead {
        readGenericPasswordWithoutUserInteraction(service: service, account: currentUserAccount())
    }

    func readGenericPasswordWithoutUserInteraction(service: String, account: String) -> NonInteractiveKeychainRead {
        readGenericPasswordWithoutUserInteraction(service: service, account: account as String?)
    }

    private func readGenericPasswordWithoutUserInteraction(
        service: String,
        account: String?
    ) -> NonInteractiveKeychainRead {
        coordinator.nonInteractiveRead(
            service: service,
            account: account,
            fingerprint: { attributeFingerprint(service: service, account: account) },
            read: { ticket in performNonInteractiveRead(service: service, account: account, ticket: ticket) }
        )
    }

    private func performNonInteractiveRead(
        service: String,
        account: String?,
        ticket: KeychainReadCoordinator.ReadTicket
    ) -> NonInteractiveKeychainRead {
        // An automatic path may request secret data ONLY with keychain UI provably suppressed.
        // `LAContext.interactionNotAllowed` does not suppress classic login-keychain ACL dialogs on
        // macOS 26.6, but the process-global switch does (verified: an unauthorized read fails
        // errSecAuthFailed in milliseconds, dialog-free). So a granted item loads silently on any
        // background refresh — no per-session Connect click — while an unapproved one falls to the
        // neutral deferral, and only an explicit user action may ever show the dialog.
        if let outcome = quietSecretRead(service: service, account: account, ticket: ticket) {
            return outcome
        }
        // The quiet window was unavailable (a dialog is open or queued, or the UI switch failed).
        // Fall back to the metadata-only classification; the next cycle retries the quiet read.
        switch rawGenericPasswordExists(service: service, account: account) {
        case true:
            // The item exists and was deliberately not read — a neutral deferral, NOT a denial:
            // nothing asked securityd for the secret, so nothing can have been denied yet.
            coordinator.recordFailureCategory(ticket, category: .manualReadDeferred)
            AppLog.debug(.keychain, "automatic secret read deferred for service '\(service)'; manual read required")
            return .unavailable
        case false:
            return .missing
        case nil:
            coordinator.recordFailureCategory(ticket, category: .unreadable)
            AppLog.debug(.keychain, "automatic secret read unavailable for service '\(service)'; metadata probe failed")
            return .unavailable
        }
    }

    /// One UI-suppressed secret read, or `nil` when the suppressed window could not be entered.
    /// The shared quiet-read core owns the gate turn, the switch toggling, and the status
    /// classification; this maps its outcome onto the coordinator's categories.
    private func quietSecretRead(
        service: String,
        account: String?,
        ticket: KeychainReadCoordinator.ReadTicket
    ) -> NonInteractiveKeychainRead? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecMatchLimit as String: kSecMatchLimitOne,
            kSecReturnData as String: true,
        ].merging(account.map { [kSecAttrAccount as String: $0] } ?? [:]) { current, _ in current }
        guard let outcome = QuietKeychainSecretRead.perform(
            query: query,
            service: service,
            copyMatching: copyMatching,
            setUserInteractionAllowed: setUserInteractionAllowed
        ) else {
            return nil
        }
        switch outcome {
        case .hit(let data):
            guard let data, let value = String(data: data, encoding: .utf8) else {
                return .value("")
            }
            return .value(value)
        case .missing:
            return .missing
        case .needsApproval:
            // Before settling on the Connect state, check for the partition wall: a credential
            // writer can reset the item's partition list on rotation, which blocks every
            // in-process read while the ACL approvals remain intact. When the item's own ACL
            // proves the `security` helper still reads it silently, recover through it — the
            // user's Always Allow is being honored, not bypassed, and no dialog can appear.
            if let value = partitionWallFallback(service, account) {
                AppLog.info(.keychain, "read service '\(service)' via the security helper: the item's partition list excludes this app (likely reset by the owning app); ACL approvals remain intact")
                return .value(value)
            }
            coordinator.recordFailureCategory(ticket, category: .manualReadDeferred)
            return .unavailable
        case .unreadable:
            coordinator.recordFailureCategory(ticket, category: .unreadable)
            return .unavailable
        }
    }

    /// Attributes-only existence probe used on the launch path: an in-process Security-framework
    /// query (no subprocess) that never requests the secret or evaluates its ACL. A failed probe
    /// reports `nil` ("unknown"), never a definite answer, so callers can pick their safe side.
    func genericPasswordExists(service: String) -> Bool? {
        coordinator.probe(service: service, account: nil) {
            rawGenericPasswordExists(service: service, account: nil)
        }
    }

    func genericPasswordExists(service: String, account: String) -> Bool? {
        coordinator.probe(service: service, account: account) {
            rawGenericPasswordExists(service: service, account: account)
        }
    }

    func lastReadFailure(service: String, account: String) -> KeychainReadFailure? {
        coordinator.lastFailureCategory(service: service, account: account)
    }

    func lastReadFailure(service: String) -> KeychainReadFailure? {
        coordinator.lastFailureCategory(service: service, account: nil)
    }

    func lastReadFailureForCurrentUser(service: String) -> KeychainReadFailure? {
        coordinator.lastFailureCategory(service: service, account: currentUserAccount())
    }

    func genericPasswordForCurrentUserExists(service: String) -> Bool? {
        let account = currentUserAccount()
        return coordinator.probe(service: service, account: account) {
            rawGenericPasswordExists(service: service, account: account)
        }
    }

    private func rawGenericPasswordExists(service: String, account: String?) -> Bool? {
        let query = NonInteractiveKeychainMetadataQuery.applying(to: [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ].merging(account.map { [kSecAttrAccount as String: $0] } ?? [:]) { current, _ in current })
        let status = copyMatching(query as CFDictionary, nil)
        switch status {
        case errSecSuccess: return true
        case errSecItemNotFound: return false
        default: return nil
        }
    }

    func readGenericPasswordForCurrentUser(service: String) throws -> String? {
        try promptFreeValue(service: service, account: currentUserAccount())
    }

    func readGenericPassword(service: String, account: String) throws -> String? {
        try promptFreeValue(service: service, account: account)
    }

    func genericPasswordAttributeFingerprint(service: String, account: String) -> String? {
        coordinator.probe(service: service, account: account) {
            attributeFingerprint(service: service, account: account)
        }
    }

    /// Attributes-only fingerprint (no `kSecReturnData`, so the item's ACL is never evaluated):
    /// prompt-free, in-process, microseconds. `nil` means the item is absent or the probe failed —
    /// the coordinator treats both as "cannot cache". Deliberately RAW (not routed through
    /// `coordinator.probe`): the coordinated read paths invoke it while already holding the item's
    /// flight, which the probe gate would wait on.
    private func attributeFingerprint(service: String, account: String?) -> String? {
        guard let attributes = genericPasswordAttributes(service: service, account: account) else {
            return nil
        }
        return Self.fingerprint(attributes)
    }

    /// Keychain modification dates have one-second resolution. If a manual read occurs in the same
    /// second as a secret-only update, hashing the attributes immediately could bind the old secret
    /// to the new item's indistinguishable fingerprint for the rest of the process. Wait until the
    /// observed modification second closes, query the attributes again, and only then perform the
    /// one user-approved secret read. Continuous updates are bounded to two seconds and return no
    /// cacheable fingerprint rather than delaying the refresh indefinitely.
    private func stabilizedAttributeFingerprint(service: String, account: String?) -> String? {
        let deadline = metadataNow().addingTimeInterval(Self.metadataStabilizationLimit)
        while let attributes = genericPasswordAttributes(service: service, account: account) {
            guard let modifiedAt = attributes[kSecAttrModificationDate as String] as? Date else {
                return nil
            }
            let now = metadataNow()
            let stableAt = modifiedAt.addingTimeInterval(Self.metadataTimestampResolution)
            guard stableAt > now else { return Self.fingerprint(attributes) }
            guard stableAt <= deadline else { return nil }
            waitForMetadataStability(stableAt.timeIntervalSince(now) + 0.01)
        }
        return nil
    }

    private func genericPasswordAttributes(service: String, account: String?) -> [String: Any]? {
        let query = NonInteractiveKeychainMetadataQuery.applying(to: [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecMatchLimit as String: kSecMatchLimitOne,
            kSecReturnAttributes as String: true,
        ].merging(account.map { [kSecAttrAccount as String: $0] } ?? [:]) { current, _ in current })
        var item: CFTypeRef?
        let status = copyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess,
              let attributes = item as? [String: Any]
        else {
            return nil
        }
        return attributes
    }

    private static func fingerprint(_ attributes: [String: Any]) -> String? {
        // The query never requests `kSecReturnData`, so this contains metadata only. Normalize every
        // attribute before hashing; callers receive no raw account, path, dates, labels, or access
        // group, and an in-place `-U` update changes the modification-date component.
        let normalized = attributes.map { key, value in
            "\(key)=\(Self.stableKeychainAttribute(value))"
        }.sorted().joined(separator: "\n")
        guard !normalized.isEmpty else { return nil }
        return SHA256.hash(data: Data(normalized.precomposedStringWithCanonicalMapping.utf8)).hexString
    }

    private static func stableKeychainAttribute(_ value: Any) -> String {
        switch value {
        case let value as Data:
            return value.base64EncodedString()
        case let value as Date:
            return String(value.timeIntervalSinceReferenceDate)
        case let value as String:
            return value
        case let value as NSNumber:
            return value.stringValue
        default:
            return String(describing: value)
        }
    }

    private func currentUserAccount() -> String {
        ProcessInfo.processInfo.environment["USER"]?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        ?? NSUserName()
    }
}

enum KeychainError: Error, LocalizedError {
    case writeFailed(String)
    case readFailed(String)

    var errorDescription: String? {
        switch self {
        case .writeFailed(let message):
            return message.isEmpty ? "Keychain write failed." : message
        case .readFailed(let message):
            return message.isEmpty ? "Keychain read failed." : message
        }
    }
}
