import Foundation
import Security

/// The ONE place Runway writes a foreign credential store, used exclusively by token renewal to
/// persist a rotated Claude credential back to the store it was read from. Every other consumer
/// holds the read-only `KeychainReading`; keeping the write capability out of that protocol keeps
/// "only the owner may modify a credential" enforced by the type system everywhere else.
///
/// The blob is patched as RAW JSON — only the three rotated fields are replaced — so fields Runway
/// doesn't model survive byte-for-byte. The output is minified: the legacy edition learned that a
/// multi-line value is hex-encoded by the `security` tool on write, which Claude Code then cannot
/// read back (it treats the login as invalid).
struct ClaudeCredentialWriteBack: Sendable {
    private static let helperPath = "/usr/bin/security"

    var stdinRunner: any StdinProcessRunning = SystemProcessRunner()
    var helperIsSilentlyAuthorized: @Sendable (String, String?) -> Bool = PartitionWallFallbackReader.helperIsSilentlyAuthorized

    /// Whether SOME write path to this item is verified before a refresh token is consumed: the
    /// helper's silent authorization is checkable up front and also covers the in-process path's
    /// partition-wall failure mode, so it is the precondition renewal requires.
    func canWriteKeychain(service: String, account: String) -> Bool {
        helperIsSilentlyAuthorized(service, account)
    }

    /// Replace exactly the rotated fields inside the raw credential JSON, preserving everything
    /// else (top-level and within `claudeAiOauth`). Returns minified single-line JSON.
    static func patchedBlob(
        original: String,
        accessToken: String,
        refreshToken: String?,
        expiresAt: Double?
    ) -> String? {
        guard var root = (try? JSONSerialization.jsonObject(with: Data(original.utf8))) as? [String: Any],
              var oauth = root["claudeAiOauth"] as? [String: Any]
        else {
            return nil
        }
        oauth["accessToken"] = accessToken
        if let refreshToken {
            oauth["refreshToken"] = refreshToken
        }
        if let expiresAt {
            // Claude Code stores epoch milliseconds as an integer; keep that shape.
            oauth["expiresAt"] = Int64(expiresAt)
        }
        root["claudeAiOauth"] = oauth
        guard let data = try? JSONSerialization.data(withJSONObject: root),
              let text = String(data: data, encoding: .utf8)
        else {
            return nil
        }
        return text
    }

    /// Write the blob to the item — through the security helper ONLY, over stdin (argv is visible
    /// to the whole login session and this value is a credential).
    ///
    /// Never in-process: securityd rewrites an item's PARTITION LIST to the writer's own partition
    /// on every update. An in-process `SecItemUpdate` therefore stamps the item `teamid:` and
    /// evicts `apple-tool:` — locking Claude Code's own `security`-based tooling out of its own
    /// credential and trapping the user in password dialogs (observed live, 2026-08-08). A helper
    /// write leaves the item in its native `apple-tool:` state: Claude Code keeps silent access,
    /// and Runway reads on through the partition-wall fallback.
    func writeKeychain(service: String, account: String, blob: String) -> Bool {
        guard helperIsSilentlyAuthorized(service, account) else { return false }
        let command = "add-generic-password -U -a \"\(Self.escaped(account))\" -s \"\(Self.escaped(service))\" -w \"\(Self.escaped(blob))\"\n"
        guard let result = try? stdinRunner.run(
            executable: Self.helperPath,
            arguments: ["-i"],
            stdin: command,
            timeout: 5
        ), result.succeeded else {
            AppLog.warn(.keychain, "helper credential write failed for service '\(service)'")
            return false
        }
        return true
    }

    /// `security -i` lexes double-quoted arguments with backslash escapes (verified round-trip on
    /// macOS 26.6); the blob is single-line JSON, so quotes and backslashes are the only specials.
    private static func escaped(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
    }
}
