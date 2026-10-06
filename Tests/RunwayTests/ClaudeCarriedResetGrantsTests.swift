import XCTest
@testable import Runway

/// The Rate Limit Resets row carried through a relaunch's first 429: the same bound as a limit
/// window, applied per reset, and no reminder from a row Anthropic has not revalidated.
@MainActor
final class ClaudeCarriedResetGrantsTests: ClaudeLaunchSnapshotTestCase {
    private let past = ClaudeLaunchFixture.now.addingTimeInterval(-60)
    private let soon = ClaudeLaunchFixture.now.addingTimeInterval(30 * 3600)
    private let later = ClaudeLaunchFixture.now.addingTimeInterval(72 * 3600)

    private func resets(_ count: Double, _ expiries: [Date]) -> MetricLine {
        .values(
            label: ClaudeUsageMapper.resetGrantsLabel,
            values: [MetricValue(number: count, kind: .count, label: "available")],
            expiriesAt: expiries
        )
    }

    private var weekly: MetricLine {
        .progress(label: "Weekly", used: 40, limit: 100, format: .percent, resetsAt: ClaudeLaunchFixture.future)
    }

    private func rateLimitedLaunch(_ defaults: UserDefaults) async -> WidgetDataStore {
        let store = launch(defaults: defaults, files: makeFiles(), http: FakeHTTPClient(response: ClaudeLaunchFixture.rateLimited))
        await store.refresh(providerID: "claude")
        return store
    }

    func testOnlyResetsWithADeadlineStillAheadAreCarried() async {
        // Four resets: one lapsed, two dated ahead, one with no deadline. Nothing bounds the undated
        // one, so it is not carried; the lapsed one is gone.
        let defaults = makeDefaults("grants")
        seedCache(defaults, lines: [weekly, resets(4, [past, soon, later])])

        let store = await rateLimitedLaunch(defaults)

        XCTAssertEqual(store.snapshots["claude"]?.line(label: ClaudeUsageMapper.resetGrantsLabel), resets(2, [soon, later]))
        XCTAssertEqual(used(store.snapshots["claude"], "Weekly"), 40)
    }

    func testRowWithNoDatedResetAheadIsNotCarried() async {
        for (name, row) in [("lapsed", resets(2, [past, past])), ("undated", resets(2, [])), ("none", resets(0, []))] {
            let defaults = makeDefaults("grants-\(name)")
            seedCache(defaults, lines: [weekly, row])
            let store = await rateLimitedLaunch(defaults)
            XCTAssertNil(store.snapshots["claude"]?.line(label: ClaudeUsageMapper.resetGrantsLabel), name)
            XCTAssertEqual(used(store.snapshots["claude"], "Weekly"), 40, name)
        }

        // Alone, such a row leaves nothing to carry.
        let defaults = makeDefaults("grants-only-undated")
        seedCache(defaults, lines: [resets(2, [])])
        let store = await rateLimitedLaunch(defaults)
        assertBareBadge(store.snapshots["claude"])
    }

    func testCarriedResetsDoNotUnlockOrRepeatReminders() async {
        let defaults = makeDefaults("grants-reminders")
        let grants = HTTPResponse(statusCode: 200, headers: [:], body: Data(
            #"{"seven_day":{"utilization":40,"resets_at":"2099-01-01T00:00:00.000Z"},"cedar_ember":{"eligible":true,"grants":[{"resets_left":1,"ends_at":"\#(RunwayISO8601.string(from: soon))"}]}}"#.utf8
        ))
        var posted: [String] = []
        func evaluate(_ store: WidgetDataStore) async {
            // A new evaluator per launch, over the same persisted reminder history.
            await ResetExpiryNotificationEvaluator(defaults: defaults).evaluate(
                metrics: store.resetExpiryNotificationMetrics(), enabled: true, now: ClaudeLaunchFixture.now,
                post: { posted.append($0.identifier); return true }, remove: { _ in }
            )
        }

        // Before the relaunch: a real fetch, and the 48-hour reminder goes out once.
        let first = launch(defaults: defaults, files: makeFiles(), http: FakeHTTPClient(response: grants))
        await first.refresh(providerID: "claude")
        XCTAssertEqual(first.resetExpiryNotificationMetrics().map(\.canNotify), [true])
        await evaluate(first)
        XCTAssertEqual(posted.count, 1)

        // Relaunch into a rate limit: the row is carried, but it cannot start a reminder.
        let carried = await rateLimitedLaunch(defaults)
        XCTAssertEqual(carried.snapshots["claude"]?.line(label: ClaudeUsageMapper.resetGrantsLabel), resets(1, [soon]))
        let metrics = carried.resetExpiryNotificationMetrics()
        XCTAssertEqual(metrics.map(\.expiries), [[soon]])
        XCTAssertEqual(metrics.map(\.canNotify), [false])
        await evaluate(carried)
        XCTAssertEqual(posted.count, 1)

        // The same reset revalidated by a real fetch after another relaunch: still no repeat.
        let revalidated = launch(defaults: defaults, files: makeFiles(), http: FakeHTTPClient(response: grants))
        await revalidated.refresh(providerID: "claude")
        XCTAssertEqual(revalidated.resetExpiryNotificationMetrics().map(\.canNotify), [true])
        await evaluate(revalidated)
        XCTAssertEqual(posted.count, 1)
    }

    func testCarriedResetNeverRemindedBeforeWaitsForARealFetch() async {
        // Only ever seen in the cache this launch: no reminder until Anthropic confirms it.
        let defaults = makeDefaults("grants-unconfirmed")
        seedCache(defaults, lines: [weekly, resets(1, [soon])])
        let store = await rateLimitedLaunch(defaults)
        var posted = 0
        await ResetExpiryNotificationEvaluator(defaults: defaults).evaluate(
            metrics: store.resetExpiryNotificationMetrics(), enabled: true, now: ClaudeLaunchFixture.now,
            post: { _ in posted += 1; return true }, remove: { _ in }
        )
        XCTAssertEqual(store.resetExpiryNotificationMetrics().map(\.expiries), [[soon]])
        XCTAssertEqual(posted, 0)
    }
}
