import Foundation
import Security

/// Renews an expired Claude OAuth token the way the legacy edition did — and the way CodexBar's
/// desync bug (steipete/CodexBar#1161) proved it must be done: by writing the rotated credential
/// back to the exact store Claude Code reads, so there is only ever ONE token chain.
///
/// Anthropic's refresh tokens are single-use and rotating: whoever presents the current refresh
/// token consumes it and receives the next one. A second rotator that keeps its result to itself
/// strands Claude Code on a consumed token and forces a re-login (the #1161 failure); a rotation
/// attempted while Claude Code is active races its own proactive renewal (the `refresh_token_reused`
/// class of failure, issue #516 on the Codex side). Every guard here exists to close one of those:
///
/// - **Reactive only.** Renewal runs when the stored token is already expired by at least
///   `expiryGrace`. Claude Code refreshes ~5 minutes BEFORE expiry, so a token that stayed expired
///   this long proves no live session owns the chain.
/// - **Single chain.** The current store is re-read immediately before the network call; if it no
///   longer holds the refresh token about to be consumed, the OTHER writer rotated first and its
///   fresher credential is adopted instead of racing it.
/// - **Write-back is a precondition, not a hope.** For keychain sources the fallback write path is
///   verified (the security helper's silent authorization) BEFORE the refresh token is consumed;
///   if no write path exists, no rotation happens and today's renewal notice stands.
/// - **`invalid_grant` is terminal.** The chain is gone; only a real `claude` login mints a new
///   one. The provider backs off instead of retrying.
///
/// The kill switch: `defaults write com.mattstallone.runway runway.claude.disableTokenRefresh -bool true`.
struct ClaudeTokenRenewal: Sendable {
    static let expiryGrace: TimeInterval = 10 * 60
    /// After a failed attempt the provider waits this long before trying again.
    static let attemptCooldown: TimeInterval = 15 * 60
    static let killSwitchDefaultsKey = "runway.claude.disableTokenRefresh"

    enum Outcome: Sendable {
        /// Rotation succeeded and the store now holds the new chain.
        case renewed(ClaudeOAuth)
        /// The store already held a fresher credential (another writer rotated first) — use it.
        case adopted(ClaudeOAuth)
        /// A guard declined without touching the network; retrying next cycle is free.
        case skipped
        /// The network attempt failed (or the chain is revoked); the caller should back off.
        case attemptFailed
    }

    var refresher = ClaudeTokenRefresher()
    var writeBack = ClaudeCredentialWriteBack()
    var keychain: any KeychainReading = SecurityKeychainAccessor()
    var files: any TextFileAccessing = LocalTextFileAccessor()
    var environment: any EnvironmentReading = ProcessEnvironmentReader()
    var isDisabled: @Sendable () -> Bool = {
        UserDefaults.standard.bool(forKey: ClaudeTokenRenewal.killSwitchDefaultsKey)
    }
    var now: @Sendable () -> Date = Date.init
    var currentAccount: @Sendable () -> String = {
        ProcessInfo.processInfo.environment["USER"]?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
            ?? NSUserName()
    }

    /// One renewal attempt for the credential `state` was loaded from. `credentialsFilePath` is
    /// the store's file location, used only for `.file`-sourced credentials.
    func renew(state: ClaudeCredentialState, credentialsFilePath: String) async -> Outcome {
        guard !isDisabled() else {
            AppLog.info(LogTag.auth("claude"), "token renewal disabled by \(Self.killSwitchDefaultsKey)")
            return .skipped
        }
        guard let consumedRefreshToken = state.oauth.refreshToken?.nilIfEmpty else { return .skipped }
        // An unknown expiry cannot prove Claude Code is idle, so it never renews.
        guard let expiresAt = state.oauth.expiresAt,
              now().timeIntervalSince1970 * 1000 - expiresAt >= Self.expiryGrace * 1000
        else {
            AppLog.info(LogTag.auth("claude"), "token renewal deferred: expired too recently — a live Claude Code session may still own the rotation")
            return .skipped
        }

        // Resolve the store this credential came from; only stores Runway can write back to are
        // eligible, and that ability is verified BEFORE the refresh token is consumed.
        let store: RenewalStore
        switch state.source {
        case .keychainCurrentUser(let service):
            let account = currentAccount()
            guard writeBack.canWriteKeychain(service: service, account: account) else {
                AppLog.warn(LogTag.auth("claude"), "token renewal skipped: no verified write path to the keychain item")
                return .skipped
            }
            store = .keychain(service: service, account: account)
        case .file:
            store = .file(path: credentialsFilePath)
        case .keychainLegacy, .desktop, .environment:
            // The legacy service-wide item's account is unknown (a write could target the wrong
            // login), Desktop's credential belongs to the Desktop app's own storage, and an
            // environment token has no refresh token to rotate.
            return .skipped
        }

        // Re-read the store right before consuming: if it no longer holds this refresh token,
        // another writer already rotated — adopt its fresher credential instead of racing it.
        guard let currentBlob = readCurrentBlob(from: store) else { return .skipped }
        guard let parsed = ClaudeAuthStore.parseCredentials(currentBlob),
              let currentOAuth = parsed.claudeAiOauth
        else { return .skipped }
        guard currentOAuth.refreshToken == consumedRefreshToken else {
            AppLog.info(LogTag.auth("claude"), "token renewal unnecessary: the store already holds a fresher credential; adopting it")
            return .adopted(currentOAuth)
        }

        let endpoint = ClaudeAuthStore.resolveTokenRefreshEndpoint(environment: environment)
        switch await refresher.refresh(refreshToken: consumedRefreshToken, endpoint: endpoint, now: now()) {
        case .refreshed(let accessToken, let refreshToken, let newExpiresAt):
            guard let blob = ClaudeCredentialWriteBack.patchedBlob(
                original: currentBlob,
                accessToken: accessToken,
                refreshToken: refreshToken,
                expiresAt: newExpiresAt
            ) else {
                AppLog.error(LogTag.auth("claude"), "token renewal succeeded but the credential blob could not be patched; the store keeps the consumed token")
                return .attemptFailed
            }
            guard write(blob: blob, to: store) else {
                AppLog.error(LogTag.auth("claude"), "token renewal succeeded but the write-back failed; a `claude` login will mint a fresh chain")
                return .attemptFailed
            }
            AppLog.info(LogTag.auth("claude"), "token renewed and written back to the \(store.label) store")
            var oauth = state.oauth
            oauth.accessToken = accessToken
            if let refreshToken { oauth.refreshToken = refreshToken }
            if let newExpiresAt { oauth.expiresAt = newExpiresAt }
            return .renewed(oauth)
        case .invalidGrant:
            AppLog.warn(LogTag.auth("claude"), "token renewal rejected (invalid_grant): the chain is revoked; run `claude` to log in again")
            return .attemptFailed
        case .failed:
            return .attemptFailed
        }
    }

    private enum RenewalStore {
        case keychain(service: String, account: String)
        case file(path: String)

        var label: String {
            switch self {
            case .keychain: "keychain"
            case .file: "file"
            }
        }
    }

    private func readCurrentBlob(from store: RenewalStore) -> String? {
        switch store {
        case .keychain(let service, _):
            // The coordinator's change-gated cache answers this from the read that produced the
            // candidate; a concurrent rotation moves the fingerprint and forces a fresh read.
            switch keychain.readGenericPasswordForCurrentUserWithoutUserInteraction(service: service) {
            case .value(let value): return value
            case .missing, .unavailable: return nil
            }
        case .file(let path):
            return try? files.readTextIfPresent(path)
        }
    }

    private func write(blob: String, to store: RenewalStore) -> Bool {
        switch store {
        case .keychain(let service, let account):
            return writeBack.writeKeychain(service: service, account: account, blob: blob)
        case .file(let path):
            do {
                try files.writeText(path, blob)
                return true
            } catch {
                AppLog.error(LogTag.auth("claude"), "credentials file write-back failed: \(error.localizedDescription)")
                return false
            }
        }
    }
}

/// The OAuth token-endpoint call, exactly as Claude Code's public client performs it.
struct ClaudeTokenRefresher: Sendable {
    enum Outcome: Sendable, Equatable {
        case refreshed(accessToken: String, refreshToken: String?, expiresAt: Double?)
        /// The presented refresh token is consumed or revoked — only a real login recovers.
        case invalidGrant
        case failed
    }

    /// Claude Code's own scope set (from the legacy edition, which shipped this for years).
    static let scopes = "user:profile user:inference user:sessions:claude_code user:mcp_servers user:file_upload"

    var httpClient: any HTTPClient = URLSessionHTTPClient()

    func refresh(
        refreshToken: String,
        endpoint: ClaudeAuthStore.TokenRefreshEndpoint,
        now: Date
    ) async -> Outcome {
        guard let url = URL(string: endpoint.url) else {
            AppLog.error(LogTag.auth("claude"), "token renewal impossible: invalid refresh endpoint URL")
            return .failed
        }
        let payload: [String: Any] = [
            "grant_type": "refresh_token",
            "refresh_token": refreshToken,
            "client_id": endpoint.clientID,
            "scope": Self.scopes,
        ]
        guard let body = try? JSONSerialization.data(withJSONObject: payload) else { return .failed }
        let response: HTTPResponse
        do {
            response = try await httpClient.send(HTTPRequest(
                method: "POST",
                url: url,
                headers: ["Content-Type": "application/json"],
                body: body,
                timeout: 15
            ))
        } catch {
            AppLog.warn(LogTag.auth("claude"), "token renewal request failed: \(error.localizedDescription)")
            return .failed
        }
        if response.statusCode == 400 || response.statusCode == 401 {
            let decoded = (try? JSONSerialization.jsonObject(with: response.body)) as? [String: Any]
            let code = (decoded?["error"] as? String) ?? (decoded?["error_description"] as? String) ?? "?"
            AppLog.warn(LogTag.auth("claude"), "token renewal rejected (\(response.statusCode): \(code))")
            return code == "invalid_grant" ? .invalidGrant : .failed
        }
        guard (200..<300).contains(response.statusCode),
              let decoded = (try? JSONSerialization.jsonObject(with: response.body)) as? [String: Any],
              let accessToken = (decoded["access_token"] as? String)?.nilIfEmpty
        else {
            AppLog.warn(LogTag.auth("claude"), "token renewal returned an unusable response (status \(response.statusCode))")
            return .failed
        }
        let expiresAt = (decoded["expires_in"] as? Double).map { now.timeIntervalSince1970 * 1000 + $0 * 1000 }
        return .refreshed(
            accessToken: accessToken,
            refreshToken: (decoded["refresh_token"] as? String)?.nilIfEmpty,
            expiresAt: expiresAt
        )
    }
}
