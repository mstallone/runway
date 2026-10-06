import XCTest
@testable import Runway

/// The first 429 after a relaunch: `ClaudeProvider`'s last-good usage is memory-only, so without the
/// launch cache it could only answer with a bare badge, which then replaced the limits just painted
/// from disk and overwrote the cache. These tests run a real provider behind a real `WidgetDataStore`
/// and snapshot cache, one "launch" at a time, and pin the account gate that decides when the cached
/// limits may stand in.
@MainActor
final class ClaudeLaunchSnapshotTests: ClaudeLaunchSnapshotTestCase {
    // MARK: - The fix

    func testFirst429AfterRelaunchKeepsCachedLimitsUnderTheRateLimitNotice() async throws {
        let defaults = makeDefaults("keeps")
        // The cached entry is itself a rate-limited snapshot from the previous session, with spend
        // tiles: only its live limits may come back, never its notice or its tiles.
        seedCache(defaults, lines: [
            .progress(label: "Session", used: 25, limit: 100, format: .percent, resetsAt: ClaudeLaunchFixture.future),
            .progress(label: "Weekly", used: 40, limit: 100, format: .percent, resetsAt: ClaudeLaunchFixture.future),
            .text(label: "Note", value: "Live usage rate limited - retry in ~3m"),
            .values(label: "Today", values: [MetricValue(number: 999, kind: .dollars, estimated: true)])
        ], warning: "Updates blocked by Anthropic. Stale.")
        let logHome = try ClaudeLogFixture.makeHome(files: [
            "project-a/session.jsonl": ClaudeLogFixture.usageLine(
                timestamp: "2026-02-20T16:00:00.000Z", input: 100, output: 50, costUSD: 0.25
            )
        ])
        let http = FakeHTTPClient(response: ClaudeLaunchFixture.rateLimited)
        let store = launch(defaults: defaults, files: makeFiles(), http: http, logHome: logHome)
        XCTAssertEqual(used(store.snapshots["claude"], "Session"), 25, "launch paints the cached limits")

        let outcome = await store.refresh(providerID: "claude")

        XCTAssertEqual(outcome, .refreshed)
        let snapshot = store.snapshots["claude"]
        XCTAssertEqual(used(snapshot, "Session"), 25)
        XCTAssertEqual(used(snapshot, "Weekly"), 40)
        XCTAssertNil(snapshot?.line(label: "Status"), "cached limits, not the bare badge")
        let notes = snapshot?.lines.filter { $0.label == "Note" } ?? []
        XCTAssertEqual(notes, [.text(label: "Note", value: "Live usage rate limited - retry in ~10m")])
        XCTAssertEqual(
            snapshot?.warning,
            "Updates blocked by Anthropic. Be patient — manual refreshes will make it worse. Retrying in ~10m."
        )
        XCTAssertEqual(snapshot?.resolvedWarningAction, .wait)
        XCTAssertEqual(snapshot?.refreshedAt, ClaudeLaunchFixture.now.addingTimeInterval(-3600), "the limits' own time, not the 429's")
        // Spend is rescanned from this Mac's logs, never copied from the cached entry.
        XCTAssertEqual(values(snapshot, "Today"), [
            MetricValue(number: 0.25, kind: .dollars, estimated: true),
            MetricValue(number: 150, kind: .count, label: "tokens")
        ])
        XCTAssertEqual(http.requests.count, 1)

        // The next launch still finds usable limits on disk, under the same account stamp.
        let reread = ProviderSnapshotCache(userDefaults: defaults)
        XCTAssertEqual(used(reread.loadSnapshots(providerIDs: ["claude"])["claude"], "Session"), 25)
        XCTAssertEqual(reread.producedByIdentityKey(providerID: "claude"), ClaudeLaunchFixture.identityKey)
    }

    // MARK: - The gate

    func testEntryStampedByAnotherAccountFallsBackToTheBareBadge() async {
        let defaults = makeDefaults("mismatch")
        seedCache(defaults, stamp: "acct-other|org-1")
        let store = launch(defaults: defaults, files: makeFiles(), http: FakeHTTPClient(response: ClaudeLaunchFixture.rateLimited))
        XCTAssertNil(store.snapshots["claude"], "the swap guard already refuses to paint it")

        await store.refresh(providerID: "claude")

        assertBareBadge(store.snapshots["claude"])
    }

    func testUnstampedEntryFallsBackToTheBareBadge() async {
        let defaults = makeDefaults("unstamped")
        seedCache(defaults, stamp: nil)
        let store = launch(defaults: defaults, files: makeFiles(), http: FakeHTTPClient(response: ClaudeLaunchFixture.rateLimited))

        await store.refresh(providerID: "claude")

        assertBareBadge(store.snapshots["claude"])
    }

    func testUnresolvedCardIdentityFallsBackToTheBareBadge() async {
        let defaults = makeDefaults("unresolved")
        seedCache(defaults)
        // The login and state file are intact; only the launch account pass did not resolve the card.
        let store = launch(
            defaults: defaults,
            files: makeFiles(),
            http: FakeHTTPClient(response: ClaudeLaunchFixture.rateLimited),
            identityKeys: [:]
        )
        XCTAssertEqual(used(store.snapshots["claude"], "Session"), 25, "an unresolved card still paints its cache")

        await store.refresh(providerID: "claude")

        assertBareBadge(store.snapshots["claude"])
    }

    func testLoginChangedSinceLaunchDropsTheCachedLimitsForGood() async {
        let defaults = makeDefaults("relogin")
        seedCache(defaults)
        let files = makeFiles()
        let store = launch(defaults: defaults, files: files, http: FakeHTTPClient(response: ClaudeLaunchFixture.rateLimited))
        // `claude /login` as another account between the launch account pass and the first refresh.
        files.files[ClaudeLaunchFixture.statePath] = ClaudeLaunchFixture.stateFile(account: "ACCT-B")

        await store.refresh(providerID: "claude")
        assertBareBadge(store.snapshots["claude"])

        // Even if the state file reads as the old account again, the dropped limits do not return.
        files.files[ClaudeLaunchFixture.statePath] = ClaudeLaunchFixture.stateFile()
        await store.refresh(providerID: "claude", force: true)
        assertBareBadge(store.snapshots["claude"])
    }

    func testFallbackCandidateNeverGetsTheCachedLimits() async {
        // The keychain login (the one the state file describes) is rejected, and the file login
        // behind it — possibly another account — is the one that gets the 429.
        let defaults = makeDefaults("fallback")
        seedCache(defaults)
        let keychain = ServiceKeychain()
        let files = makeFiles()
        files.files[ClaudeLaunchFixture.credentialsPath] = ClaudeLaunchFixture.credentials(accessToken: "file-token")
        let service = ClaudeAuthStore(
            environment: FakeEnvironment(["CLAUDE_CONFIG_DIR": "/tmp/claude"]), files: files, keychain: keychain
        ).keychainServiceCandidates().first!
        keychain.currentUserValues[service] = ClaudeLaunchFixture.credentials(accessToken: "keychain-token")
        let http = RoutingHTTPClient { request in
            request.headers["Authorization"] == "Bearer keychain-token"
                ? HTTPResponse(statusCode: 401, headers: [:], body: Data())
                : ClaudeLaunchFixture.rateLimited
        }
        let store = launch(defaults: defaults, files: files, keychain: keychain, http: http)

        await store.refresh(providerID: "claude")

        XCTAssertEqual(http.requests.map { $0.headers["Authorization"] }, ["Bearer keychain-token", "Bearer file-token"])
        assertBareBadge(store.snapshots["claude"])
    }

    func testSuccessfulFetchDiscardsTheCachedLimits() async {
        let defaults = makeDefaults("discard")
        seedCache(defaults)
        let files = makeFiles()
        let calls = ClaudeLaunchCounter()
        let http = RoutingHTTPClient { _ in calls.next() == 1 ? ClaudeLaunchFixture.usage(session: 60) : ClaudeLaunchFixture.rateLimited }
        let store = launch(defaults: defaults, files: files, http: http)

        await store.refresh(providerID: "claude")
        XCTAssertEqual(used(store.snapshots["claude"], "Session"), 60)

        // A later 429 serves the real last-good usage, not the launch cache.
        await store.refresh(providerID: "claude", force: true)
        XCTAssertEqual(used(store.snapshots["claude"], "Session"), 60)
        XCTAssertNil(store.snapshots["claude"]?.line(label: "Weekly"))

        // A rotated token clears last-good usage; the launch cache must not resurface behind it.
        files.files[ClaudeLaunchFixture.credentialsPath] = ClaudeLaunchFixture.credentials(accessToken: "rotated")
        await store.refresh(providerID: "claude", force: true)
        assertBareBadge(store.snapshots["claude"])
    }

    // MARK: - What is reused

    func testWindowPastItsResetIsDropped() async {
        let defaults = makeDefaults("expired-window")
        seedCache(defaults, lines: [
            .progress(label: "Session", used: 90, limit: 100, format: .percent, resetsAt: ClaudeLaunchFixture.now.addingTimeInterval(-60)),
            .progress(label: "Weekly", used: 40, limit: 100, format: .percent, resetsAt: ClaudeLaunchFixture.future)
        ])
        let store = launch(defaults: defaults, files: makeFiles(), http: FakeHTTPClient(response: ClaudeLaunchFixture.rateLimited))

        await store.refresh(providerID: "claude")

        XCTAssertNil(store.snapshots["claude"]?.line(label: "Session"), "a reset window must not show its pre-reset value")
        XCTAssertEqual(used(store.snapshots["claude"], "Weekly"), 40)
        XCTAssertNil(store.snapshots["claude"]?.line(label: "Status"))
    }

    func testEveryWindowPastItsResetFallsBackToTheBareBadge() async {
        let defaults = makeDefaults("all-expired")
        seedCache(defaults, lines: [
            .progress(label: "Session", used: 90, limit: 100, format: .percent, resetsAt: ClaudeLaunchFixture.now.addingTimeInterval(-60))
        ])
        let store = launch(defaults: defaults, files: makeFiles(), http: FakeHTTPClient(response: ClaudeLaunchFixture.rateLimited))

        await store.refresh(providerID: "claude")

        assertBareBadge(store.snapshots["claude"])
    }

    func testRowsWithoutAResetTimeAreNeverCarried() async {
        // Nothing bounds a row with no reset: an unstarted Session and Extra Usage (capped or not)
        // would otherwise ride every later 429 until a fetch succeeds.
        let defaults = makeDefaults("no-reset")
        seedCache(defaults, lines: [
            .progress(label: "Session", used: 0, limit: 100, format: .percent),
            .progress(label: "Weekly", used: 40, limit: 100, format: .percent, resetsAt: ClaudeLaunchFixture.future),
            .progress(label: "Extra usage spent", used: 50, limit: 100, format: .dollars)
        ])
        let store = launch(defaults: defaults, files: makeFiles(), http: FakeHTTPClient(response: ClaudeLaunchFixture.rateLimited))
        await store.refresh(providerID: "claude")
        XCTAssertEqual(
            store.snapshots["claude"]?.lines.map(\.label).filter(ClaudeUsageMapper.liveLimitLabels.contains),
            ["Weekly"]
        )

        let uncapped = makeDefaults("no-reset-uncapped")
        seedCache(uncapped, lines: [
            .values(label: "Extra usage spent", values: [MetricValue(number: 50, kind: .dollars)])
        ])
        let second = launch(defaults: uncapped, files: makeFiles(), http: FakeHTTPClient(response: ClaudeLaunchFixture.rateLimited))
        await second.refresh(providerID: "claude")
        assertBareBadge(second.snapshots["claude"])
        XCTAssertNil(second.snapshots["claude"]?.line(label: "Extra usage spent"))
    }

    /// Every row the live endpoint can produce must be a known live-limit label, or that row would
    /// silently vanish on a relaunch's first 429 while its neighbors stay.
    func testEveryMappedLiveRowIsALiveLimitLabel() throws {
        let body = #"{"five_hour":{"utilization":1},"seven_day":{"utilization":2},"seven_day_sonnet":{"utilization":3},"limits":[{"kind":"weekly_scoped","percent":4,"scope":{"model":{"display_name":"Fable"}}}],"extra_usage":{"is_enabled":true,"used_credits":500,"monthly_limit":1000},"cedar_ember":{"eligible":false}}"#
        let mapped = try ClaudeUsageMapper.mapUsageResponse(
            HTTPResponse(statusCode: 200, headers: [:], body: Data(body.utf8)),
            credentials: ClaudeOAuth()
        )

        XCTAssertEqual(mapped.lines.count, 6)
        XCTAssertTrue(Set(mapped.lines.map(\.label)).isSubset(of: ClaudeUsageMapper.liveLimitLabels))
    }

    // MARK: - Which login the cache is bound to

    private func state(
        accessToken: String = "token",
        source: ClaudeCredentialState.Source = .file,
        identityKey: String? = ClaudeLaunchFixture.identityKey
    ) -> ClaudeCredentialState {
        ClaudeCredentialState(
            oauth: ClaudeOAuth(accessToken: accessToken, refreshToken: "refresh-\(accessToken)"),
            source: source,
            inferenceOnly: false,
            stateFileIdentityKey: identityKey
        )
    }

    private func heldCache() -> ClaudeLiveUsageCache {
        var cache = ClaudeLiveUsageCache()
        cache.holdLaunchSnapshot(
            ProviderSnapshot(providerID: "claude", displayName: "Claude", lines: [
                .progress(label: "Session", used: 25, limit: 100, format: .percent, resetsAt: ClaudeLaunchFixture.future)
            ]),
            producedByIdentityKey: ClaudeLaunchFixture.identityKey
        )
        return cache
    }

    func testRotatedTokenOfTheSameAccountStillGetsTheCachedLimits() {
        // A relaunch usually meets a token Claude Code (or Runway's own renewal) rotated since the
        // cache was written, so the launch cache is bound to the account, not the token pair.
        var cache = heldCache()
        cache.activate(for: state(accessToken: "old"))
        cache.activate(for: state(accessToken: "rotated"))

        XCTAssertEqual(cache.launchCachedUsage(for: state(accessToken: "rotated"), now: ClaudeLaunchFixture.now)?.lines.map(\.label), ["Session"])
    }

    func testLoginWithoutStateFileIdentityNeverGetsTheCachedLimits() {
        // Desktop and fallback candidates carry no identity: the state file does not describe them.
        var cache = heldCache()
        let desktop = state(source: .desktop, identityKey: nil)
        cache.activate(for: desktop)

        XCTAssertNil(cache.launchCachedUsage(for: desktop, now: ClaudeLaunchFixture.now))
        // Unknown is not a login change: the described login can still use the cache afterwards.
        XCTAssertNotNil(cache.launchCachedUsage(for: state(), now: ClaudeLaunchFixture.now))
    }

    func testStateFileIdentityRidesOnlyOnTheHighestPriorityStoredLogin() {
        let files = makeFiles()
        let keychain = ServiceKeychain()
        let store = ClaudeAuthStore(
            environment: FakeEnvironment(["CLAUDE_CONFIG_DIR": "/tmp/claude"]), files: files, keychain: keychain
        )
        XCTAssertEqual(store.loadCredentialSet().candidates.map(\.stateFileIdentityKey), [ClaudeLaunchFixture.identityKey])

        keychain.currentUserValues[store.keychainServiceCandidates().first!] = ClaudeLaunchFixture.credentials(accessToken: "keychain-token")
        let candidates = store.loadCredentialSet().candidates
        XCTAssertEqual(candidates.map(\.oauth.accessToken), ["keychain-token", "token"])
        XCTAssertEqual(candidates.map(\.stateFileIdentityKey), [ClaudeLaunchFixture.identityKey, nil])
    }

    func testBorrowedDefaultHomeKeychainItemCarriesNoIdentity() {
        // `CLAUDE_CONFIG_DIR` with no keychain item of its own falls back to the default home's
        // item, which that dir's state file does not describe.
        let files = FakeFiles([ClaudeLaunchFixture.statePath: ClaudeLaunchFixture.stateFile()])
        let keychain = ServiceKeychain()
        let store = ClaudeAuthStore(
            environment: FakeEnvironment(["CLAUDE_CONFIG_DIR": "/tmp/claude"]), files: files, keychain: keychain
        )
        let services = store.keychainServiceCandidates()
        XCTAssertEqual(services.count, 2)
        keychain.currentUserValues[services[1]] = ClaudeLaunchFixture.credentials(accessToken: "default-home")
        XCTAssertEqual(store.loadCredentialSet().candidates.map(\.stateFileIdentityKey), [nil])

        keychain.currentUserValues[services[0]] = ClaudeLaunchFixture.credentials(accessToken: "own")
        XCTAssertEqual(store.loadCredentialSet().candidates.first?.stateFileIdentityKey, ClaudeLaunchFixture.identityKey)
    }

    func testConfigDirCardReadsItsOwnStateFileIdentity() {
        let store = ClaudeAuthStore(
            environment: FakeEnvironment(),
            files: FakeFiles([
                "/Users/dev/.claude-work/.credentials.json": ClaudeLaunchFixture.credentials(),
                "/Users/dev/.claude-work/.claude.json": ClaudeLaunchFixture.stateFile(account: "ACCT-WORK"),
                "/Users/dev/.claude.json": ClaudeLaunchFixture.stateFile()
            ]),
            keychain: FakeKeychain(),
            scope: .configDir(path: "/Users/dev/.claude-work", keychainLiteral: "/Users/dev/.claude-work")
        )

        XCTAssertEqual(store.loadCredentialSet().candidates.map(\.stateFileIdentityKey), ["acct-work|org-1"])
    }
}
