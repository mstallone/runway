import XCTest
@testable import Runway

/// Limits carried through a rate limit keep the time they were fetched and the account that fetched
/// them: across relaunches, in every surface that shows or exports age, and without making the
/// one-shot CLI refetch on every run.
@MainActor
final class ClaudeCarriedLimitsTests: ClaudeLaunchSnapshotTestCase {
    // MARK: - Age

    func testCarriedLimitsKeepTheirRealAgeAcrossRelaunchesAndRateLimits() async {
        // Friday's fetch, then a rate limit at every later launch: the limits must keep saying Friday.
        let defaults = makeDefaults("age")
        let friday = ClaudeLaunchFixture.now.addingTimeInterval(-3 * 86_400)
        seedCache(defaults, refreshedAt: friday)
        let clock = ClaudeLaunchClock(ClaudeLaunchFixture.now)

        let monday = launch(defaults: defaults, files: makeFiles(), http: FakeHTTPClient(response: ClaudeLaunchFixture.rateLimited), clock: clock)
        XCTAssertEqual(monday.stalenessHint(for: "claude")?.tooltip, "Last updated 3d 0h ago")
        await monday.refresh(providerID: "claude")
        XCTAssertEqual(used(monday.snapshots["claude"], "Weekly"), 40)
        XCTAssertEqual(monday.snapshots["claude"]?.refreshedAt, friday)
        XCTAssertEqual(monday.stalenessHint(for: "claude"), StalenessHint(label: "Outdated", tooltip: "Last updated 3d 0h ago"))
        XCTAssertEqual(
            ProviderSnapshotCache(userDefaults: defaults).loadSnapshots(providerIDs: ["claude"])["claude"]?.refreshedAt,
            friday
        )

        // A week later: relaunch, rate-limited again. Ten days old, not seven and not zero.
        clock.set(ClaudeLaunchFixture.now.addingTimeInterval(7 * 86_400))
        let later = launch(defaults: defaults, files: makeFiles(), http: FakeHTTPClient(response: ClaudeLaunchFixture.rateLimited), clock: clock)
        await later.refresh(providerID: "claude")
        XCTAssertEqual(used(later.snapshots["claude"], "Weekly"), 40)
        XCTAssertEqual(later.snapshots["claude"]?.refreshedAt, friday)
        XCTAssertEqual(later.stalenessHint(for: "claude")?.tooltip, "Last updated 10d 0h ago")
        XCTAssertEqual(
            ProviderSnapshotCache(userDefaults: defaults).loadSnapshots(providerIDs: ["claude"])["claude"]?.refreshedAt,
            friday
        )
    }

    func testLastGoodUsageServedThroughARateLimitKeepsItsFetchTime() async {
        // Without this an in-session rate limit re-dates the limits, and the next launch would
        // inherit that false time from the cache.
        let defaults = makeDefaults("session-age")
        let clock = ClaudeLaunchClock(ClaudeLaunchFixture.now)
        let calls = ClaudeLaunchCounter()
        let http = RoutingHTTPClient { _ in calls.next() == 1 ? ClaudeLaunchFixture.usage(session: 60) : ClaudeLaunchFixture.rateLimited }
        let store = launch(defaults: defaults, files: makeFiles(), http: http, clock: clock)
        await store.refresh(providerID: "claude")
        XCTAssertEqual(store.snapshots["claude"]?.refreshedAt, ClaudeLaunchFixture.now)

        clock.set(ClaudeLaunchFixture.now.addingTimeInterval(20 * 60))
        await store.refresh(providerID: "claude")

        XCTAssertEqual(used(store.snapshots["claude"], "Session"), 60)
        XCTAssertEqual(store.snapshots["claude"]?.resolvedWarningAction, .wait)
        XCTAssertEqual(store.snapshots["claude"]?.refreshedAt, ClaudeLaunchFixture.now)
        XCTAssertEqual(store.stalenessHint(for: "claude")?.label, "Outdated")
    }

    func testRateLimitedBadgeWithNoLimitsIsDatedNow() async {
        let defaults = makeDefaults("badge-age")
        seedCache(defaults, stamp: nil)
        let store = launch(defaults: defaults, files: makeFiles(), http: FakeHTTPClient(response: ClaudeLaunchFixture.rateLimited))
        await store.refresh(providerID: "claude")
        assertBareBadge(store.snapshots["claude"])
        XCTAssertEqual(store.snapshots["claude"]?.refreshedAt, ClaudeLaunchFixture.now)
    }

    func testOneShotCLIDoesNotCallAnthropicMoreOftenWhileCarryingOldLimits() async {
        // Each `runway` run is a new process: no in-memory cooldown, only the cache's persisted
        // freshness window. Old-dated limits must not make every run look stale and refetch.
        let defaults = makeDefaults("cli")
        seedCache(defaults, refreshedAt: ClaudeLaunchFixture.now.addingTimeInterval(-3 * 86_400))
        let http = FakeHTTPClient(response: ClaudeLaunchFixture.rateLimited)
        let clock = ClaudeLaunchClock(ClaudeLaunchFixture.now)
        func run() async -> WidgetDataStore.RefreshOutcome {
            await launch(defaults: defaults, files: makeFiles(), http: http, clock: clock, oneShotCLI: true)
                .refresh(providerID: "claude")
        }
        func isFreshForCLI() -> Bool {
            // `UsageReader`'s own "needs a refresh" test.
            ProviderSnapshotCache(userDefaults: defaults, allowsPersistedFreshness: true, now: { clock.now })
                .snapshot(providerID: "claude") != nil
        }

        XCTAssertFalse(isFreshForCLI(), "a three-day-old entry is stale before anything checks it")
        let first = await run()
        XCTAssertEqual(first, .refreshed)
        XCTAssertEqual(http.requests.count, 1)

        clock.set(ClaudeLaunchFixture.now.addingTimeInterval(60))
        XCTAssertTrue(isFreshForCLI())
        let second = await run()
        XCTAssertEqual(second, .cacheHit)
        clock.set(ClaudeLaunchFixture.now.addingTimeInterval(4 * 60))
        let third = await run()
        XCTAssertEqual(third, .cacheHit)
        XCTAssertEqual(http.requests.count, 1, "runs inside the five-minute window never reach the endpoint")

        clock.set(ClaudeLaunchFixture.now.addingTimeInterval(6 * 60))
        XCTAssertFalse(isFreshForCLI())
        let fourth = await run()
        XCTAssertEqual(fourth, .refreshed)
        XCTAssertEqual(http.requests.count, 2)
    }

    // MARK: - The stamp

    func testEntryIsStampedWithTheAccountThatFetchedItNotTheLaunchAccount() async {
        // Launch as A; `claude /login` as B while Runway runs; B's limits are fetched and cached.
        let defaults = makeDefaults("aba")
        let files = makeFiles()
        let first = launch(defaults: defaults, files: files, http: FakeHTTPClient(response: ClaudeLaunchFixture.usage(session: 77)))
        files.files[ClaudeLaunchFixture.statePath] = ClaudeLaunchFixture.stateFile(account: "ACCT-B")
        files.files[ClaudeLaunchFixture.credentialsPath] = ClaudeLaunchFixture.credentials(accessToken: "b-token")
        await first.refresh(providerID: "claude")
        XCTAssertEqual(used(first.snapshots["claude"], "Session"), 77)
        XCTAssertEqual(
            ProviderSnapshotCache(userDefaults: defaults).producedByIdentityKey(providerID: "claude"),
            "acct-b|org-1"
        )

        // Back to A, relaunch, rate-limited: B's 77% is neither painted nor carried on A's card.
        let relaunched = launch(defaults: defaults, files: makeFiles(), http: FakeHTTPClient(response: ClaudeLaunchFixture.rateLimited))
        XCTAssertNil(relaunched.snapshots["claude"])
        await relaunched.refresh(providerID: "claude")
        assertBareBadge(relaunched.snapshots["claude"])
    }

    private func stamp(_ defaults: UserDefaults) -> String? {
        ProviderSnapshotCache(userDefaults: defaults).producedByIdentityKey(providerID: "claude")
    }

    /// Launch as A, then `claude /login` as B before the refresh.
    private func filesReloggedAsB(scopes: String = "user:profile") -> FakeFiles {
        FakeFiles([
            ClaudeLaunchFixture.statePath: ClaudeLaunchFixture.stateFile(account: "ACCT-B"),
            ClaudeLaunchFixture.credentialsPath:
                #"{"claudeAiOauth":{"accessToken":"b-token","refreshToken":"b-refresh","subscriptionType":"max","scopes":["\#(scopes)"]}}"#
        ])
    }

    func testRateLimitedBadgeIsStampedWithTheAccountTheStateFileNamed() async {
        // The badge snapshot carries B's plan. Stamped as launch account A it would paint on A's
        // card at the next launch as A.
        let defaults = makeDefaults("badge-stamp")
        let store = launch(defaults: defaults, files: filesReloggedAsB(), http: FakeHTTPClient(response: ClaudeLaunchFixture.rateLimited))
        await store.refresh(providerID: "claude")
        assertBareBadge(store.snapshots["claude"])
        XCTAssertEqual(store.snapshots["claude"]?.plan, "Max")
        XCTAssertEqual(stamp(defaults), "acct-b|org-1")

        // The cooldown path (no request) stamps the same way.
        await store.refresh(providerID: "claude", force: true)
        XCTAssertEqual(stamp(defaults), "acct-b|org-1")

        // Next launch as A: B's badge is discarded, and nothing of it can be carried.
        let http = FakeHTTPClient(response: ClaudeLaunchFixture.rateLimited)
        let asA = launch(defaults: defaults, files: makeFiles(), http: http)
        XCTAssertNil(asA.snapshots["claude"])
        await asA.refresh(providerID: "claude")
        assertBareBadge(asA.snapshots["claude"])
        XCTAssertEqual(asA.snapshots["claude"]?.plan, "Pro")
        XCTAssertEqual(stamp(defaults), ClaudeLaunchFixture.identityKey)
    }

    func testSpendOnlySnapshotsAreStampedWithTheAccountTheStateFileNamed() async {
        // A login that cannot read live usage: the snapshot is local spend plus B's plan badge.
        let scoped = makeDefaults("scope-stamp")
        let http = FakeHTTPClient(response: ClaudeLaunchFixture.rateLimited)
        let noScope = launch(defaults: scoped, files: filesReloggedAsB(scopes: "user:inference"), http: http)
        await noScope.refresh(providerID: "claude")
        XCTAssertEqual(noScope.snapshots["claude"]?.warning, ClaudeUsageMapper.missingProfileScopeWarning)
        XCTAssertTrue(http.requests.isEmpty)
        XCTAssertEqual(stamp(scoped), "acct-b|org-1")

        // A rejected token with nothing to fall back to: the renewal notice over local spend.
        let renewal = makeDefaults("renewal-stamp")
        let rejected = launch(
            defaults: renewal,
            files: filesReloggedAsB(),
            http: FakeHTTPClient(response: HTTPResponse(statusCode: 401, headers: [:], body: Data()))
        )
        await rejected.refresh(providerID: "claude")
        XCTAssertEqual(rejected.snapshots["claude"]?.loginRequired, true)
        XCTAssertEqual(stamp(renewal), "acct-b|org-1")
    }

    func testLoginWithoutAccountEvidenceKeepsTheLaunchStampOnARateLimit() async {
        // The keychain login the state file describes is rejected; the file login behind it gets the
        // 429. The state file does not describe that login, so its badge is stamped as before.
        let defaults = makeDefaults("fallback-stamp")
        let files = filesReloggedAsB()
        let keychain = ServiceKeychain()
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
        assertBareBadge(store.snapshots["claude"])
        XCTAssertEqual(stamp(defaults), ClaudeLaunchFixture.identityKey)
    }

    func testUnresolvedCardStaysUnstampedWhateverTheProviderNames() async {
        let defaults = makeDefaults("unresolved-stamp")
        let store = launch(
            defaults: defaults,
            files: makeFiles(),
            http: FakeHTTPClient(response: ClaudeLaunchFixture.usage(session: 10)),
            identityKeys: [:]
        )
        await store.refresh(providerID: "claude")
        let cache = ProviderSnapshotCache(userDefaults: defaults)
        XCTAssertNotNil(cache.loadSnapshots(providerIDs: ["claude"])["claude"])
        XCTAssertNil(cache.producedByIdentityKey(providerID: "claude"))
    }

    func testFetchWithNoAccountEvidenceKeepsTheLaunchStamp() async {
        // No state file to read at fetch time: the entry is stamped as it always was.
        let defaults = makeDefaults("no-evidence")
        let files = makeFiles()
        files.files[ClaudeLaunchFixture.statePath] = nil
        let store = launch(defaults: defaults, files: files, http: FakeHTTPClient(response: ClaudeLaunchFixture.usage(session: 10)))
        await store.refresh(providerID: "claude")
        XCTAssertEqual(
            ProviderSnapshotCache(userDefaults: defaults).producedByIdentityKey(providerID: "claude"),
            ClaudeLaunchFixture.identityKey
        )
    }
}
