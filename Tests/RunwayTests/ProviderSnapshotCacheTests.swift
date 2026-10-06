import XCTest
@testable import Runway

/// Guards the in-memory write-through mirror: reads must reflect writes, a second store must not drop
/// the first, and the mirror must stay a cache over real persistence (a fresh instance reads from disk).
final class ProviderSnapshotCacheTests: XCTestCase {
    private func makeDefaults() -> UserDefaults {
        UserDefaults(testSuiteName: "providerSnapshotCache.test.\(UUID().uuidString)")!
    }

    private func snapshot(_ id: String, used: Double, now: Date) -> ProviderSnapshot {
        ProviderSnapshot(
            providerID: id,
            displayName: id.capitalized,
            lines: [.progress(label: "Session", used: used, limit: 100, format: .percent)],
            refreshedAt: now
        )
    }

    func testStoreAccumulatesAcrossProvidersAndReadsReflectWrites() {
        let defaults = makeDefaults()
        let now = Date()
        let cache = ProviderSnapshotCache(userDefaults: defaults, storageKey: "k", ttl: 9_999, now: { now })

        cache.store(snapshot("alpha", used: 10, now: now))
        cache.store(snapshot("beta", used: 20, now: now))

        // The second store must not drop the first, and reads come back from the mirror unchanged.
        XCTAssertEqual(cache.loadSnapshots(providerIDs: ["alpha", "beta"]).count, 2)
        XCTAssertEqual(cache.snapshot(providerID: "alpha")?.lines.first,
                       .progress(label: "Session", used: 10, limit: 100, format: .percent))
        XCTAssertEqual(cache.snapshot(providerID: "beta")?.lines.first,
                       .progress(label: "Session", used: 20, limit: 100, format: .percent))
    }

    func testDeferredStorePersistsOnlyOnPersistPending() {
        let defaults = makeDefaults()
        let now = Date()
        let cache = ProviderSnapshotCache(userDefaults: defaults, storageKey: "k", ttl: 9_999, now: { now })

        cache.store(snapshot("alpha", used: 10, now: now), persist: false)
        cache.store(snapshot("beta", used: 20, now: now), persist: false)

        // The mirror reflects both writes immediately; disk gets nothing until the batch-end flush.
        XCTAssertEqual(cache.loadSnapshots(providerIDs: ["alpha", "beta"]).count, 2)
        let beforeFlush = ProviderSnapshotCache(userDefaults: defaults, storageKey: "k", ttl: 9_999, now: { now })
        XCTAssertTrue(beforeFlush.loadSnapshots(providerIDs: ["alpha", "beta"]).isEmpty)

        cache.persistPending()
        let afterFlush = ProviderSnapshotCache(userDefaults: defaults, storageKey: "k", ttl: 9_999, now: { now })
        XCTAssertEqual(afterFlush.loadSnapshots(providerIDs: ["alpha", "beta"]).count, 2)
    }

    func testWritesPersistForAFreshInstance() {
        let defaults = makeDefaults()
        let now = Date()
        ProviderSnapshotCache(userDefaults: defaults, storageKey: "k", ttl: 9_999, now: { now })
            .store(snapshot("alpha", used: 42, now: now))

        // A fresh instance starts with an empty mirror, so the *display* read (`loadSnapshots`) proves the
        // write reached disk — the mirror is a cache over persistence, not a replacement for it. (The
        // freshness gate `snapshot(providerID:)` deliberately treats this disk-loaded value as stale; see
        // `testRelaunchLoadedSnapshotIsStaleEvenWithinTTL`.)
        let reloaded = ProviderSnapshotCache(userDefaults: defaults, storageKey: "k", ttl: 9_999, now: { now })
        XCTAssertEqual(reloaded.loadSnapshots(providerIDs: ["alpha"])["alpha"]?.lines.first,
                       .progress(label: "Session", used: 42, limit: 100, format: .percent))
    }

    /// #697 core guarantee: a snapshot persisted by a *previous* session and reloaded on launch must not
    /// satisfy the refresh gate, even when its `refreshedAt` is still well within TTL — otherwise the app
    /// would wait out the previous session's remaining interval before refetching. It must still *display*
    /// (instant paint), so `loadSnapshots` returns it.
    func testRelaunchLoadedSnapshotIsStaleEvenWithinTTL() {
        let defaults = makeDefaults()
        let now = Date()
        // Session 1 writes a snapshot 1s ago — comfortably inside the 9_999s TTL.
        ProviderSnapshotCache(userDefaults: defaults, storageKey: "k", ttl: 9_999, now: { now })
            .store(snapshot("alpha", used: 42, now: now.addingTimeInterval(-1)))

        // Session 2 (fresh instance = relaunch) reloads it from disk.
        let relaunched = ProviderSnapshotCache(userDefaults: defaults, storageKey: "k", ttl: 9_999, now: { now })
        // Display still paints the last-known value...
        XCTAssertNotNil(relaunched.loadSnapshots(providerIDs: ["alpha"])["alpha"])
        // ...but the refresh gate treats it as stale, forcing a refresh on the first post-launch pass.
        XCTAssertNil(relaunched.snapshot(providerID: "alpha"))
    }

    /// Acceptance criterion 2: a snapshot written *this* session still short-circuits a redundant refresh
    /// within that session (no refresh storm) — the gate is "written this session AND within TTL", not
    /// "written this session" alone.
    func testSnapshotWrittenThisSessionStaysFreshWithinTTL() {
        let defaults = makeDefaults()
        let now = Date()
        let cache = ProviderSnapshotCache(userDefaults: defaults, storageKey: "k", ttl: 9_999, now: { now })

        cache.store(snapshot("alpha", used: 42, now: now))
        XCTAssertEqual(cache.snapshot(providerID: "alpha")?.lines.first,
                       .progress(label: "Session", used: 42, limit: 100, format: .percent))
    }

    /// A snapshot written this session still expires once it ages past TTL, so the periodic loop resumes
    /// refetching on the normal cadence (the session-write flag widens freshness on launch, it doesn't
    /// pin a snapshot fresh forever).
    func testSnapshotWrittenThisSessionExpiresAfterTTL() {
        let defaults = makeDefaults()
        var now = Date()
        let cache = ProviderSnapshotCache(userDefaults: defaults, storageKey: "k", ttl: 100, now: { now })

        cache.store(snapshot("alpha", used: 42, now: now))
        now = now.addingTimeInterval(101)
        XCTAssertNil(cache.snapshot(providerID: "alpha"))
    }

    // MARK: - Check-time freshness

    private func oldSnapshot(_ id: String, now: Date, wait: Bool) -> ProviderSnapshot {
        ProviderSnapshot(
            providerID: id,
            displayName: id.capitalized,
            lines: [.progress(label: "Session", used: 10, limit: 100, format: .percent)],
            refreshedAt: now.addingTimeInterval(-3 * 86_400),
            warning: wait ? "Blocked. Be patient." : nil,
            warningAction: wait ? .wait : nil
        )
    }

    func testCheckTimeIsClearedByALaterOrdinaryWrite() {
        // A check time left behind after the rate limit ends would measure every later entry from
        // that old check: stale forever, so each one-shot CLI run would refetch.
        let defaults = makeDefaults()
        var now = Date(timeIntervalSince1970: 1_800_000_000)
        let cache = ProviderSnapshotCache(userDefaults: defaults, storageKey: "k", ttl: 300, now: { now })

        cache.store(oldSnapshot("alpha", now: now, wait: true), checkedAt: now)
        XCTAssertNotNil(cache.snapshot(providerID: "alpha"), "fresh from the check, whatever the values' age")

        now = now.addingTimeInterval(600)
        var recovered = oldSnapshot("alpha", now: now, wait: false)
        recovered.refreshedAt = now
        cache.store(recovered)
        XCTAssertNotNil(cache.snapshot(providerID: "alpha"), "measured from refreshedAt again, not the old check")

        // And the other direction: with no check time an old-dated snapshot is stale at once.
        cache.store(oldSnapshot("alpha", now: now, wait: false))
        XCTAssertNil(cache.snapshot(providerID: "alpha"))

        // The cleared state is what reached disk.
        let reread = ProviderSnapshotCache(
            userDefaults: defaults, storageKey: "k", ttl: 300, allowsPersistedFreshness: true, now: { now }
        )
        XCTAssertNil(reread.snapshot(providerID: "alpha"))
    }

    func testCheckTimeExpiresOneIntervalAfterTheCheck() {
        let defaults = makeDefaults()
        var now = Date(timeIntervalSince1970: 1_800_000_000)
        let cache = ProviderSnapshotCache(userDefaults: defaults, storageKey: "k", ttl: 300, now: { now })
        cache.store(oldSnapshot("alpha", now: now, wait: true), checkedAt: now)

        now = now.addingTimeInterval(299)
        XCTAssertNotNil(cache.snapshot(providerID: "alpha"))
        now = now.addingTimeInterval(2)
        XCTAssertNil(cache.snapshot(providerID: "alpha"))
    }

    func testPayloadWrittenBeforeCheckTimesExistedKeepsItsStampAndFreshness() throws {
        // The released app writes `snapshots` and `producedByIdentityKeys` only.
        let defaults = makeDefaults()
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let entry = try JSONSerialization.jsonObject(with: encoder.encode(snapshot("claude", used: 40, now: now)))
        defaults.set(
            try JSONSerialization.data(withJSONObject: [
                "snapshots": ["claude": entry],
                "producedByIdentityKeys": ["claude": "acct-a|org-1"]
            ]),
            forKey: "k"
        )

        let cache = ProviderSnapshotCache(
            userDefaults: defaults, storageKey: "k", ttl: 300, allowsPersistedFreshness: true,
            now: { now.addingTimeInterval(60) }
        )
        XCTAssertEqual(cache.loadSnapshots(providerIDs: ["claude"])["claude"]?.refreshedAt, now)
        XCTAssertEqual(cache.producedByIdentityKey(providerID: "claude"), "acct-a|org-1")
        XCTAssertFalse(cache.hasStaleAccountStamp(providerID: "claude", currentIdentityKey: "acct-a|org-1"))
        XCTAssertNotNil(cache.snapshot(providerID: "claude"), "fresh by its own refreshedAt")

        let later = ProviderSnapshotCache(
            userDefaults: defaults, storageKey: "k", ttl: 300, allowsPersistedFreshness: true,
            now: { now.addingTimeInterval(600) }
        )
        XCTAssertNil(later.snapshot(providerID: "claude"))
    }

    /// The store decides which writes carry a check time: any provider's wait-style snapshot (Muse
    /// serves an old-dated last-good under one), and nothing else.
    @MainActor
    func testStoreRecordsACheckTimeOnlyForWaitNoticeSnapshots() async {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        func probes(_ snapshots: [ProviderSnapshot], forceFirst: Int = 0) async -> Int {
            let provider = Provider(id: "muse", displayName: "Muse", icon: .providerMark("muse"))
            let runtime = SequenceProviderRuntime(provider: provider, descriptors: [], snapshots: snapshots)
            let defaults = makeDefaults()
            let store = WidgetDataStore(
                registry: WidgetRegistry.from([runtime]),
                providers: [runtime],
                cache: ProviderSnapshotCache(userDefaults: defaults, storageKey: "k", ttl: 300, now: { now }),
                defaults: defaults,
                now: { now }
            )
            for index in 0..<3 {
                await store.refresh(providerID: "muse", force: index < forceFirst)
            }
            return runtime.refreshCount
        }

        let waiting = oldSnapshot("muse", now: now, wait: true)
        let ordinary = oldSnapshot("muse", now: now, wait: false)
        let waitProbes = await probes([waiting])
        XCTAssertEqual(waitProbes, 1, "an old-dated wait-notice snapshot is fresh for one interval from the check")
        let ordinaryProbes = await probes([ordinary])
        XCTAssertEqual(ordinaryProbes, 3, "an old-dated ordinary snapshot is measured from refreshedAt, as before")
        // Wait notice, then recovery (forced), then a plain pass: the recovery cleared the check time.
        let recoveredProbes = await probes([waiting, ordinary], forceFirst: 2)
        XCTAssertEqual(recoveredProbes, 3)
    }
}
