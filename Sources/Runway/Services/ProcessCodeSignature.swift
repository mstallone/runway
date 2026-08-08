import Foundation
import Security

/// Whether this process's code signature can hold a durable macOS Keychain approval.
///
/// "Always Allow" on a Keychain ACL dialog attaches to the requesting binary's code-signing
/// requirement. A certificate-backed signature (Apple Development, Developer ID) has a stable
/// requirement — identifier + certificate — so one approval survives rebuilds. An ad-hoc signature
/// (what a bare `swift build` produces) has no certificate: its requirement is the binary's own
/// hash, so every rebuild is a new identity and every approval dies with the old binary. Prompting
/// from such a build trains the user to keep clicking Always Allow for grants that cannot last,
/// and litters the item's ACL with dead entries — the recurring-prompt report this exists to end.
enum ProcessCodeSignature {
    /// Evaluated once per process; a signature cannot change while the process runs.
    static let canHoldDurableKeychainApprovals: Bool = evaluate()

    private static func evaluate() -> Bool {
        // Fail open on inspection errors: refusing prompts then would lock a properly signed build
        // out of connecting providers, while allowing them merely restores the historical behavior.
        // Loud, so the odd state is diagnosable from a default log.
        var code: SecCode?
        guard SecCodeCopySelf([], &code) == errSecSuccess, let code else {
            AppLog.warn(.keychain, "could not obtain this process's code object; assuming keychain approvals can persist")
            return true
        }
        var staticCode: SecStaticCode?
        guard SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode else {
            AppLog.warn(.keychain, "could not resolve this process's static code; assuming keychain approvals can persist")
            return true
        }
        var info: CFDictionary?
        guard SecCodeCopySigningInformation(staticCode, [], &info) == errSecSuccess,
              let attributes = info as? [String: Any],
              let rawFlags = attributes[kSecCodeInfoFlags as String] as? UInt32
        else {
            AppLog.warn(.keychain, "could not inspect this process's signing information; assuming keychain approvals can persist")
            return true
        }
        return !SecCodeSignatureFlags(rawValue: rawFlags).contains(.adhoc)
    }
}
