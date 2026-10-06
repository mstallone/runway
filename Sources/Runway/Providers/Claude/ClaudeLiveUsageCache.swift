import CryptoKit
import Foundation

extension ClaudeUsageMapper {
    /// Labels of the lines `mapUsageResponse` builds from the live usage endpoint. Everything else on a
    /// Claude snapshot is recomputed locally (spend tiles, trend) or is a notice. Add a label here when
    /// `mapUsageResponse` gains a row, or that row drops out of the launch-cached limits below.
    static let liveLimitLabels: Set<String> = [
        "Session", "Weekly", "Sonnet", "Fable", "Extra usage spent"
    ]
}

/// Last successful live-usage result and a rate-limit cooldown, carried across refreshes (the provider
/// is a long-lived singleton). `/api/oauth/usage` rate-limits aggressively, so on a 429 the provider
/// serves the last-good bars with a staleness note instead of blanking the dashboard, and skips the
/// live call entirely until the cooldown expires so it doesn't keep hammering an endpoint that's
/// already limiting it.
///
/// All of it is memory-only, so a relaunch starts with no last-good usage. `launchSnapshot` covers
/// that gap: the limits painted from the on-disk snapshot cache stand in for the first 429, but only
/// under the account gate in `launchCachedUsage`.
struct ClaudeLiveUsageCache {
    static let rateLimitCooldown: TimeInterval = 5 * 60

    private var credentialFingerprint: Data?
    private(set) var lastGoodUsage: ClaudeMappedUsage?
    private(set) var rateLimitedUntil: Date?
    /// The launch-cached snapshot and the account identity stamped on it (see
    /// `ClaudeProvider.adoptLaunchSnapshot`). Dropped on the first successful live fetch, and as
    /// soon as the card's state file names a different account.
    private var launchSnapshot: (snapshot: ProviderSnapshot, identityKey: String)?

    mutating func holdLaunchSnapshot(_ snapshot: ProviderSnapshot, producedByIdentityKey identityKey: String) {
        launchSnapshot = (snapshot, identityKey)
    }

    /// Cache state belongs to the complete access + refresh credential pair. A login change therefore
    /// clears both last-good usage and cooldown, even when the two accounts share an access token.
    /// The launch snapshot is bound to the account instead of the token pair (a relaunch usually
    /// meets a rotated token), so it survives a rotation and goes only when the account changes.
    mutating func activate(for state: ClaudeCredentialState) {
        if let launchSnapshot,
           let currentIdentityKey = state.stateFileIdentityKey,
           currentIdentityKey != launchSnapshot.identityKey
        {
            AppLog.info(LogTag.plugin("claude"), "login changed since launch; dropping launch-cached limits")
            self.launchSnapshot = nil
        }
        let fingerprint = Self.fingerprint(state.oauth)
        guard credentialFingerprint != fingerprint else { return }
        credentialFingerprint = fingerprint
        lastGoodUsage = nil
        rateLimitedUntil = nil
    }

    mutating func recordLiveUsage(_ mapped: ClaudeMappedUsage) {
        lastGoodUsage = mapped
        rateLimitedUntil = nil
        launchSnapshot = nil
    }

    mutating func startCooldown(until: Date) {
        rateLimitedUntil = until
    }

    /// The launch-cached limits a rate-limited refresh may show when there is no last-good usage,
    /// or `nil` to fall back to the bare badge.
    ///
    /// Runway never asks Anthropic which account a token belongs to, so the gate is local evidence
    /// that the login being rate-limited is the one that produced the cache:
    /// - the store only hands over an entry whose account stamp equals the card's launch identity;
    /// - `state` must be the login Claude Code's state file describes (`stateFileIdentityKey` is set
    ///   on the highest-priority stored login only, never on a fallback, Desktop, or environment
    ///   candidate), and the state file read with these credentials must still name that account.
    ///
    /// Only live-limit windows whose reset is still ahead are reused, so nothing outlives its own
    /// window: a row with no reset time (Extra Usage, a Session that has not started) is never
    /// carried, and a window whose reset has passed is dropped rather than shown with its pre-reset
    /// value. Spend tiles are recomputed by the provider and an old notice is not replayed. The
    /// result keeps the cached snapshot's own time, never the time of the 429.
    func launchCachedUsage(for state: ClaudeCredentialState, now: Date) -> ClaudeMappedUsage? {
        guard let launchSnapshot,
              state.stateFileIdentityKey == launchSnapshot.identityKey
        else { return nil }
        let lines = launchSnapshot.snapshot.lines.filter { line in
            guard ClaudeUsageMapper.liveLimitLabels.contains(line.label),
                  case .progress(_, _, _, _, let resetsAt?, _, _) = line
            else { return false }
            return resetsAt > now
        }
        guard !lines.isEmpty else { return nil }
        return ClaudeMappedUsage(
            plan: launchSnapshot.snapshot.plan,
            lines: lines,
            limitsFetchedAt: launchSnapshot.snapshot.refreshedAt,
            limitsIdentityKey: launchSnapshot.identityKey
        )
    }

    private static func fingerprint(_ credentials: ClaudeOAuth) -> Data {
        let access = Data((credentials.accessToken ?? "").utf8)
        let refresh = Data((credentials.refreshToken ?? "").utf8)
        var pair = Data(SHA256.hash(data: access))
        pair.append(contentsOf: SHA256.hash(data: refresh))
        return Data(SHA256.hash(data: pair))
    }
}
