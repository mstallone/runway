import Foundation
import Security

/// Reads a foreign keychain secret through `/usr/bin/security` when the in-process read is blocked
/// by the item's PARTITION LIST — and only after proving, from prompt-free ACL metadata, that the
/// helper is fully authorized, so the subprocess can never raise a dialog.
///
/// Background: "Always Allow" entries live in an item's ACL, but macOS also checks the requesting
/// app's partition (its team id, or `apple-tool:` for Apple's CLI tools) against the item's
/// partition list — the user-consent layer an app can never edit for itself. Some credential
/// writers rewrite that list on rotation (Claude Code's updater was observed dropping the
/// user-consented `teamid:` entry on 2026-08-08): the app's ACL grants survive, but every
/// in-process read then fails errSecAuthFailed, and repairing the list needs the user's keychain
/// password. The affected items are CREATED by Apple's `security` tool, though, so the tool's own
/// partition (`apple-tool:`) and ACL entry survive the rewrite — reading through the helper is
/// silent, needs no consent, and recovers the provider automatically.
///
/// This is deliberately NOT a primary read path: an approval granted to a helper process could
/// never turn into a durable grant for Runway (see `SecurityKeychainAccessor`). It runs only when
/// the in-process quiet read reports the approval wall, and only when `helperIsSilentlyAuthorized`
/// proves from the item's ACL that the helper holds the decrypt right with no passphrase
/// requirement and its partition is listed. The SecKeychain*/SecACL* calls are deprecated like the
/// rest of the classic-keychain surface, but they are the only API over these legacy items — and
/// all of them are metadata-only, incapable of prompting.
struct PartitionWallFallbackReader: Sendable {
    private static let helperPath = "/usr/bin/security"
    /// The partition-list ACL tag as `SecACLCopyAuthorizations` reports it (verified on
    /// macOS 26.6; the SDK exports no constant for it).
    private static let partitionListTag = "ACLAuthorizationPartitionID"

    var runner: ProcessRunning = SystemProcessRunner()
    /// Test seam; production proves authorization from the real item ACL.
    var isSilentlyAuthorized: @Sendable (String, String?) -> Bool = Self.helperIsSilentlyAuthorized

    /// The secret, or `nil` when the helper is not provably silent or the read fails. Never logs
    /// or throws the value; the caller owns caching and classification.
    func read(service: String, account: String?) -> String? {
        guard isSilentlyAuthorized(service, account) else { return nil }
        var arguments = ["find-generic-password", "-s", service]
        if let account {
            arguments += ["-a", account]
        }
        arguments.append("-w")
        guard let result = try? runner.run(
            executable: Self.helperPath,
            arguments: arguments,
            environment: [:],
            timeout: 5
        ), result.succeeded else {
            AppLog.warn(.keychain, "partition-wall fallback read failed for service '\(service)'")
            return nil
        }
        var output = result.stdout
        if output.hasSuffix("\n") {
            output.removeLast()
        }
        return output
    }

    /// Whether the item's own ACL proves the helper reads it silently: a decrypt entry that names
    /// the helper (or admits any app) with no passphrase requirement, and a partition list — when
    /// one exists — that includes `apple-tool:`. Every call here is metadata-only; a data-protection
    /// item (no classic item ref) or any inspection failure answers `false`, never a guess.
    static func helperIsSilentlyAuthorized(service: String, account: String?) -> Bool {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecMatchLimit as String: kSecMatchLimitOne,
            kSecReturnRef as String: true,
        ]
        if let account {
            query[kSecAttrAccount as String] = account
        }
        var itemRef: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &itemRef) == errSecSuccess,
              let itemRef,
              CFGetTypeID(itemRef) == SecKeychainItemGetTypeID()
        else {
            return false
        }
        let item = unsafeDowncast(itemRef, to: SecKeychainItem.self)
        var accessRef: SecAccess?
        guard SecKeychainItemCopyAccess(item, &accessRef) == errSecSuccess, let accessRef else {
            return false
        }
        var aclListRef: CFArray?
        guard SecAccessCopyACLList(accessRef, &aclListRef) == errSecSuccess,
              let acls = aclListRef as? [SecACL]
        else {
            return false
        }

        var helperMayDecryptSilently = false
        for acl in acls {
            let authorizations = (SecACLCopyAuthorizations(acl) as? [String]) ?? []
            var appsRef: CFArray?
            var descriptionRef: CFString?
            var promptSelector = SecKeychainPromptSelector()
            guard SecACLCopyContents(acl, &appsRef, &descriptionRef, &promptSelector) == errSecSuccess else {
                return false
            }
            if authorizations.contains(kSecACLAuthorizationDecrypt as String) {
                guard !promptSelector.contains(.requirePassphase) else { continue }
                guard let apps = appsRef as? [SecTrustedApplication] else {
                    // A nil application list authorizes every app.
                    helperMayDecryptSilently = true
                    continue
                }
                for app in apps {
                    var dataRef: CFData?
                    guard SecTrustedApplicationCopyData(app, &dataRef) == errSecSuccess,
                          let data = dataRef as Data?
                    else { continue }
                    let path = String(decoding: data.prefix(while: { $0 != 0 }), as: UTF8.self)
                    if path == helperPath {
                        helperMayDecryptSilently = true
                    }
                }
            }
            if authorizations.contains(Self.partitionListTag) {
                // The entry's description is a hex-encoded XML plist of partition strings when
                // securityd wrote it, or a plain partition string after some updates rewrite it
                // (a `teamid:`-stamping in-process update stores it undecorated).
                guard let raw = descriptionRef as String? else { return false }
                let decoded = decodedHexString(raw) ?? raw
                guard decoded.contains("apple-tool:") else { return false }
            }
        }
        return helperMayDecryptSilently
    }

    private static func decodedHexString(_ hex: String) -> String? {
        guard hex.count.isMultiple(of: 2) else { return nil }
        var bytes: [UInt8] = []
        bytes.reserveCapacity(hex.count / 2)
        var index = hex.startIndex
        while index < hex.endIndex {
            let next = hex.index(index, offsetBy: 2)
            guard let byte = UInt8(hex[index..<next], radix: 16) else { return nil }
            bytes.append(byte)
            index = next
        }
        return String(decoding: bytes, as: UTF8.self)
    }
}
