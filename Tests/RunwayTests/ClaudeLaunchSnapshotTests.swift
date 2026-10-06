import XCTest
@testable import Runway

/// The first 429 after a relaunch: `ClaudeProvider`'s last-good usage is memory-only, so without the
/// launch cache it could only answer with a bare badge, which then replaced the limits just painted
/// from disk and overwrote the cache. These tests run a real provider behind a real `WidgetDataStore`
/// and snapshot cache, one "launch" at a time, and pin the account gate that decides when the cached
/// limits may stand in.
@MainActor
final class ClaudeLaunchSnapshotTests: XCTestCase {
    private func makeDefaults(_ name: String) -> UserDefaults {
        let suiteName = "ClaudeLaunchSnapshotTests.\(name).\(UUID().uuidString)"
        let defaults = UserDefaults(testSuiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        return defaults
    }

    private func makeFiles() -> FakeFiles {
        FakeFiles([
            Fixture.credentialsPath: Fixture.credentials(),
            Fixture.statePath: Fixture.stateFile()
        ])
    }

    /// What the previous session left on disk for the Claude card.
    private func seedCache(
        _ defaults: UserDefaults,
        lines: [MetricLine] = [
            .progress(label: "Session", used: 25, limit: 100, format: .percent, resetsAt: Fixture.future),
            .progress(label: "Weekly", used: 40, limit: 100, format: .percent, resetsAt: Fixture.future)
        ],
        warning: String? = nil,
        stamp: String? = Fixture.identityKey
    ) {
        ProviderSnapshotCache(userDefaults: defaults).store(
            ProviderSnapshot(
                providerID: "claude",
                displayName: "Claude",
                plan: "Pro",
                lines: lines,
                refreshedAt: Fixture.now.addingTimeInterval(-3600),
                warning: warning
            ),
            producedByIdentityKey: stamp
        )
    }

    /// One app launch: a fresh provider (no in-memory last-good usage), a fresh cache instance over
    /// the same defaults, and a store that paints from it — exactly what `AppContainer` assembles.
    private func launch(
        defaults: UserDefaults,
        files: FakeFiles,
        keychain: KeychainReading = FakeKeychain(),
        http: HTTPClient,
        identityKeys: [String: String] = ["claude": Fixture.identityKey],
        logHome: URL? = nil
    ) -> WidgetDataStore {
        let provider = ClaudeProvider(
            authStore: ClaudeAuthStore(
                environment: FakeEnvironment(["CLAUDE_CONFIG_DIR": "/tmp/claude"]),
                files: files,
                keychain: keychain,
                now: { Fixture.now }
            ),
            usageClient: ClaudeUsageClient(httpClient: http),
            logUsageScanner: ClaudeLogFixture.scanner(home: logHome),
            now: { Fixture.now },
            pricing: { TestPricing.bundled }
        )
        return WidgetDataStore(
            registry: WidgetRegistry.from([provider]),
            providers: [provider],
            cache: ProviderSnapshotCache(userDefaults: defaults, now: { Fixture.now }),
            defaults: defaults,
            now: { Fixture.now },
            providerIdentityKeys: identityKeys
        )
    }

    private func used(_ snapshot: ProviderSnapshot?, _ label: String) -> Double? {
        guard case .progress(_, let used, _, _, _, _, _)? = snapshot?.line(label: label) else { return nil }
        return used
    }

    private func badgeText(_ snapshot: ProviderSnapshot?, _ label: String) -> String? {
        guard case .badge(_, let text, _, _)? = snapshot?.line(label: label) else { return nil }
        return text
    }

    private func values(_ snapshot: ProviderSnapshot?, _ label: String) -> [MetricValue]? {
        guard case .values(_, let values, _, _, _, _)? = snapshot?.line(label: label) else { return nil }
        return values
    }

    private func assertBareBadge(_ snapshot: ProviderSnapshot?, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(badgeText(snapshot, "Status")?.hasPrefix("Rate limited"), true, file: file, line: line)
        XCTAssertNil(snapshot?.line(label: "Session"), file: file, line: line)
        XCTAssertNil(snapshot?.line(label: "Weekly"), file: file, line: line)
        XCTAssertEqual(snapshot?.warning?.hasPrefix("Updates blocked by Anthropic"), true, file: file, line: line)
    }

    // MARK: - The fix

    func testFirst429AfterRelaunchKeepsCachedLimitsUnderTheRateLimitNotice() async throws {
        let defaults = makeDefaults("keeps")
        // The cached entry is itself a rate-limited snapshot from the previous session, with spend
        // tiles: only its live limits may come back, never its notice or its tiles.
        seedCache(defaults, lines: [
            .progress(label: "Session", used: 25, limit: 100, format: .percent, resetsAt: Fixture.future),
            .progress(label: "Weekly", used: 40, limit: 100, format: .percent, resetsAt: Fixture.future),
            .text(label: "Note", value: "Live usage rate limited - retry in ~3m"),
            .values(label: "Today", values: [MetricValue(number: 999, kind: .dollars, estimated: true)])
        ], warning: "Updates blocked by Anthropic. Stale.")
        let logHome = try ClaudeLogFixture.makeHome(files: [
            "project-a/session.jsonl": ClaudeLogFixture.usageLine(
                timestamp: "2026-02-20T16:00:00.000Z", input: 100, output: 50, costUSD: 0.25
            )
        ])
        let http = FakeHTTPClient(response: Fixture.rateLimited)
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
        // Spend is rescanned from this Mac's logs, never copied from the cached entry.
        XCTAssertEqual(values(snapshot, "Today"), [
            MetricValue(number: 0.25, kind: .dollars, estimated: true),
            MetricValue(number: 150, kind: .count, label: "tokens")
        ])
        XCTAssertEqual(http.requests.count, 1)

        // The next launch still finds usable limits on disk, under the same account stamp.
        let reread = ProviderSnapshotCache(userDefaults: defaults)
        XCTAssertEqual(used(reread.loadSnapshots(providerIDs: ["claude"])["claude"], "Session"), 25)
        XCTAssertEqual(reread.producedByIdentityKey(providerID: "claude"), Fixture.identityKey)
    }

    // MARK: - The gate

    func testEntryStampedByAnotherAccountFallsBackToTheBareBadge() async {
        let defaults = makeDefaults("mismatch")
        seedCache(defaults, stamp: "acct-other|org-1")
        let store = launch(defaults: defaults, files: makeFiles(), http: FakeHTTPClient(response: Fixture.rateLimited))
        XCTAssertNil(store.snapshots["claude"], "the swap guard already refuses to paint it")

        await store.refresh(providerID: "claude")

        assertBareBadge(store.snapshots["claude"])
    }

    func testUnstampedEntryFallsBackToTheBareBadge() async {
        let defaults = makeDefaults("unstamped")
        seedCache(defaults, stamp: nil)
        let store = launch(defaults: defaults, files: makeFiles(), http: FakeHTTPClient(response: Fixture.rateLimited))

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
            http: FakeHTTPClient(response: Fixture.rateLimited),
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
        let store = launch(defaults: defaults, files: files, http: FakeHTTPClient(response: Fixture.rateLimited))
        // `claude /login` as another account between the launch account pass and the first refresh.
        files.files[Fixture.statePath] = Fixture.stateFile(account: "ACCT-B")

        await store.refresh(providerID: "claude")
        assertBareBadge(store.snapshots["claude"])

        // Even if the state file reads as the old account again, the dropped limits do not return.
        files.files[Fixture.statePath] = Fixture.stateFile()
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
        files.files[Fixture.credentialsPath] = Fixture.credentials(accessToken: "file-token")
        let service = ClaudeAuthStore(
            environment: FakeEnvironment(["CLAUDE_CONFIG_DIR": "/tmp/claude"]), files: files, keychain: keychain
        ).keychainServiceCandidates().first!
        keychain.currentUserValues[service] = Fixture.credentials(accessToken: "keychain-token")
        let http = RoutingHTTPClient { request in
            request.headers["Authorization"] == "Bearer keychain-token"
                ? HTTPResponse(statusCode: 401, headers: [:], body: Data())
                : Fixture.rateLimited
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
        let calls = Counter()
        let http = RoutingHTTPClient { _ in calls.next() == 1 ? Fixture.usage(session: 60) : Fixture.rateLimited }
        let store = launch(defaults: defaults, files: files, http: http)

        await store.refresh(providerID: "claude")
        XCTAssertEqual(used(store.snapshots["claude"], "Session"), 60)

        // A later 429 serves the real last-good usage, not the launch cache.
        await store.refresh(providerID: "claude", force: true)
        XCTAssertEqual(used(store.snapshots["claude"], "Session"), 60)
        XCTAssertNil(store.snapshots["claude"]?.line(label: "Weekly"))

        // A rotated token clears last-good usage; the launch cache must not resurface behind it.
        files.files[Fixture.credentialsPath] = Fixture.credentials(accessToken: "rotated")
        await store.refresh(providerID: "claude", force: true)
        assertBareBadge(store.snapshots["claude"])
    }

    // MARK: - What is reused

    func testWindowPastItsResetIsDropped() async {
        let defaults = makeDefaults("expired-window")
        seedCache(defaults, lines: [
            .progress(label: "Session", used: 90, limit: 100, format: .percent, resetsAt: Fixture.now.addingTimeInterval(-60)),
            .progress(label: "Weekly", used: 40, limit: 100, format: .percent, resetsAt: Fixture.future)
        ])
        let store = launch(defaults: defaults, files: makeFiles(), http: FakeHTTPClient(response: Fixture.rateLimited))

        await store.refresh(providerID: "claude")

        XCTAssertNil(store.snapshots["claude"]?.line(label: "Session"), "a reset window must not show its pre-reset value")
        XCTAssertEqual(used(store.snapshots["claude"], "Weekly"), 40)
        XCTAssertNil(store.snapshots["claude"]?.line(label: "Status"))
    }

    func testEveryWindowPastItsResetFallsBackToTheBareBadge() async {
        let defaults = makeDefaults("all-expired")
        seedCache(defaults, lines: [
            .progress(label: "Session", used: 90, limit: 100, format: .percent, resetsAt: Fixture.now.addingTimeInterval(-60))
        ])
        let store = launch(defaults: defaults, files: makeFiles(), http: FakeHTTPClient(response: Fixture.rateLimited))

        await store.refresh(providerID: "claude")

        assertBareBadge(store.snapshots["claude"])
    }

    func testResetGrantsPastTheirDeadlineAreDropped() {
        let past = Fixture.now.addingTimeInterval(-60)
        let soon = Fixture.now.addingTimeInterval(3600)
        func cached(_ count: Double, _ expiries: [Date]) -> ProviderSnapshot {
            ProviderSnapshot(providerID: "claude", displayName: "Claude", lines: [.values(
                label: "Rate Limit Resets",
                values: [MetricValue(number: count, kind: .count, label: "available")],
                expiriesAt: expiries
            )])
        }

        // Three grants, one known deadline passed: two remain, one of them without a deadline.
        XCTAssertEqual(
            ClaudeLiveUsageCache.currentLiveLimits(in: cached(3, [past, soon]), now: Fixture.now),
            [.values(
                label: "Rate Limit Resets",
                values: [MetricValue(number: 2, kind: .count, label: "available")],
                expiriesAt: [soon]
            )]
        )
        XCTAssertEqual(
            ClaudeLiveUsageCache.currentLiveLimits(in: cached(2, [past, past]), now: Fixture.now),
            [.values(label: "Rate Limit Resets", values: [MetricValue(number: 0, kind: .count, label: "available")])]
        )
    }

    /// Every row the live endpoint can produce must be a known live-limit label, or that row would
    /// silently vanish on a relaunch's first 429 while its neighbors stay.
    func testEveryMappedLiveRowIsALiveLimitLabel() throws {
        let body = #"{"five_hour":{"utilization":1},"seven_day":{"utilization":2},"seven_day_sonnet":{"utilization":3},"limits":[{"kind":"weekly_scoped","percent":4,"scope":{"model":{"display_name":"Fable"}}}],"extra_usage":{"is_enabled":true,"used_credits":500,"monthly_limit":1000}}"#
        let mapped = try ClaudeUsageMapper.mapUsageResponse(
            HTTPResponse(statusCode: 200, headers: [:], body: Data(body.utf8)),
            credentials: ClaudeOAuth()
        )

        XCTAssertEqual(mapped.lines.count, 5)
        XCTAssertTrue(Set(mapped.lines.map(\.label)).isSubset(of: ClaudeUsageMapper.liveLimitLabels))
    }

    // MARK: - Which login the cache is bound to

    private func state(
        accessToken: String = "token",
        source: ClaudeCredentialState.Source = .file,
        identityKey: String? = Fixture.identityKey
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
                .progress(label: "Session", used: 25, limit: 100, format: .percent, resetsAt: Fixture.future)
            ]),
            producedByIdentityKey: Fixture.identityKey
        )
        return cache
    }

    func testRotatedTokenOfTheSameAccountStillGetsTheCachedLimits() {
        // A relaunch usually meets a token Claude Code (or Runway's own renewal) rotated since the
        // cache was written, so the launch cache is bound to the account, not the token pair.
        var cache = heldCache()
        cache.activate(for: state(accessToken: "old"))
        cache.activate(for: state(accessToken: "rotated"))

        XCTAssertEqual(cache.launchCachedUsage(for: state(accessToken: "rotated"), now: Fixture.now)?.lines.map(\.label), ["Session"])
    }

    func testLoginWithoutStateFileIdentityNeverGetsTheCachedLimits() {
        // Desktop and fallback candidates carry no identity: the state file does not describe them.
        var cache = heldCache()
        let desktop = state(source: .desktop, identityKey: nil)
        cache.activate(for: desktop)

        XCTAssertNil(cache.launchCachedUsage(for: desktop, now: Fixture.now))
        // Unknown is not a login change: the described login can still use the cache afterwards.
        XCTAssertNotNil(cache.launchCachedUsage(for: state(), now: Fixture.now))
    }

    func testStateFileIdentityRidesOnlyOnTheHighestPriorityStoredLogin() {
        let files = makeFiles()
        let keychain = ServiceKeychain()
        let store = ClaudeAuthStore(
            environment: FakeEnvironment(["CLAUDE_CONFIG_DIR": "/tmp/claude"]), files: files, keychain: keychain
        )
        XCTAssertEqual(store.loadCredentialSet().candidates.map(\.stateFileIdentityKey), [Fixture.identityKey])

        keychain.currentUserValues[store.keychainServiceCandidates().first!] = Fixture.credentials(accessToken: "keychain-token")
        let candidates = store.loadCredentialSet().candidates
        XCTAssertEqual(candidates.map(\.oauth.accessToken), ["keychain-token", "token"])
        XCTAssertEqual(candidates.map(\.stateFileIdentityKey), [Fixture.identityKey, nil])
    }

    func testConfigDirCardReadsItsOwnStateFileIdentity() {
        let store = ClaudeAuthStore(
            environment: FakeEnvironment(),
            files: FakeFiles([
                "/Users/dev/.claude-work/.credentials.json": Fixture.credentials(),
                "/Users/dev/.claude-work/.claude.json": Fixture.stateFile(account: "ACCT-WORK"),
                "/Users/dev/.claude.json": Fixture.stateFile()
            ]),
            keychain: FakeKeychain(),
            scope: .configDir(path: "/Users/dev/.claude-work", keychainLiteral: "/Users/dev/.claude-work")
        )

        XCTAssertEqual(store.loadCredentialSet().candidates.map(\.stateFileIdentityKey), ["acct-work|org-1"])
    }
}

/// Fixture values, outside the main-actor test class so the fakes' `@Sendable` closures can read them.
private enum Fixture {
    static let now = RunwayISO8601.date(from: "2026-02-20T16:00:00.000Z")!
    static let future = RunwayISO8601.date(from: "2099-01-01T00:00:00.000Z")!
    static let identityKey = "acct-a|org-1"
    static let credentialsPath = "/tmp/claude/.credentials.json"
    static let statePath = "/tmp/claude/.claude.json"
    static let rateLimited = HTTPResponse(statusCode: 429, headers: ["retry-after": "600"], body: Data())

    static func credentials(accessToken: String = "token") -> String {
        #"{"claudeAiOauth":{"accessToken":"\#(accessToken)","refreshToken":"refresh-\#(accessToken)","subscriptionType":"pro","scopes":["user:profile"]}}"#
    }

    static func stateFile(account: String = "ACCT-A") -> String {
        #"{"oauthAccount":{"accountUuid":"\#(account)","organizationUuid":"ORG-1"}}"#
    }

    static func usage(session: Double) -> HTTPResponse {
        HTTPResponse(
            statusCode: 200,
            headers: [:],
            body: Data(#"{"five_hour":{"utilization":\#(session),"resets_at":"2099-01-01T00:00:00.000Z"}}"#.utf8)
        )
    }
}

private final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0
    func next() -> Int {
        lock.lock(); defer { lock.unlock() }
        value += 1
        return value
    }
}
