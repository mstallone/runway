import XCTest
@testable import Runway

@MainActor
final class ResetExpiryNotificationTests: XCTestCase {
    private let expiry = Date(timeIntervalSince1970: 2_000_000_000)
    private var suite: String!
    private var defaults: UserDefaults!

    override func setUp() async throws {
        suite = "ResetExpiryNotificationTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)!
    }

    override func tearDown() async throws {
        defaults.removePersistentDomain(forName: suite)
    }

    private func metric(key: String = "codex:account-a") -> ResetExpiryNotificationEvaluator.Metric {
        .init(key: key, providerName: "Work Codex", expiries: [expiry])
    }

    @MainActor private final class Sink {
        var posts: [ResetExpiryNotificationEvaluator.Reminder] = []
        var removed: [String] = []
        var succeeds = true
        func post(_ reminder: ResetExpiryNotificationEvaluator.Reminder) async -> Bool {
            posts.append(reminder)
            return succeeds
        }
        func remove(_ identifiers: [String]) { removed += identifiers }
    }

    private func evaluate(
        _ evaluator: ResetExpiryNotificationEvaluator, sink: Sink,
        remaining: TimeInterval, enabled: Bool = true,
        metrics: [ResetExpiryNotificationEvaluator.Metric]? = nil
    ) async {
        await evaluator.evaluate(
            metrics: metrics ?? [metric()], enabled: enabled,
            now: expiry.addingTimeInterval(-remaining), post: sink.post, remove: sink.remove
        )
    }

    func testAllFiveThresholdsReplaceTheSameResetAndDoNotRepeat() async {
        let evaluator = ResetExpiryNotificationEvaluator(defaults: defaults)
        let sink = Sink()
        let thresholds = ResetExpiryNotificationEvaluator.thresholds
        XCTAssertEqual(thresholds, [172800, 86400, 7200, 3600, 900])
        for (index, threshold) in thresholds.enumerated() {
            await evaluate(evaluator, sink: sink, remaining: threshold + 1)
            XCTAssertEqual(sink.posts.count, index)
            await evaluate(evaluator, sink: sink, remaining: threshold)
            await evaluate(evaluator, sink: sink, remaining: threshold - 1)
            XCTAssertEqual(sink.posts.count, index + 1)
        }
        XCTAssertEqual(Set(sink.posts.map(\.identifier)).count, 1)
        let durations = ["48 hours", "24 hours", "2 hours", "1 hour", "15 minutes"]
        for (index, duration) in durations.enumerated() {
            XCTAssertTrue(sink.posts[index].body(now: expiry.addingTimeInterval(-thresholds[index])).contains(duration))
        }
        XCTAssertEqual(sink.posts[0].subtitle, "Work Codex · Rate Limit Resets")
    }

    func testRestartAndDismissalDoNotRepeatButNextMilestoneStillFires() async {
        let sink = Sink()
        await evaluate(ResetExpiryNotificationEvaluator(defaults: defaults), sink: sink, remaining: 48 * 3600)
        let restarted = ResetExpiryNotificationEvaluator(defaults: defaults)
        // No delivered-notifications query: dismissal does not reset persisted history.
        await evaluate(restarted, sink: sink, remaining: 30 * 3600)
        XCTAssertEqual(sink.posts.count, 1)
        await evaluate(restarted, sink: sink, remaining: 24 * 3600)
        XCTAssertEqual(sink.posts.count, 2)
        XCTAssertEqual(sink.posts[0].identifier, sink.posts[1].identifier)
    }

    func testPendingRevalidationKeepsExistingAlertButDoesNotSendNextMilestone() async {
        let sink = Sink()
        await evaluate(ResetExpiryNotificationEvaluator(defaults: defaults), sink: sink, remaining: 48 * 3600)
        let restarted = ResetExpiryNotificationEvaluator(defaults: defaults)
        var cached = metric()
        cached.canNotify = false
        await evaluate(restarted, sink: sink, remaining: 24 * 3600, metrics: [cached])
        XCTAssertEqual(sink.posts.count, 1)
        XCTAssertTrue(sink.removed.isEmpty)
        await evaluate(restarted, sink: sink, remaining: 23 * 3600)
        XCTAssertEqual(sink.posts.count, 2)
    }

    func testLateLaunchAndWakeOnlyDeliverTheMostUrgentCurrentReminder() async {
        let evaluator = ResetExpiryNotificationEvaluator(defaults: defaults)
        let sink = Sink()
        await evaluate(evaluator, sink: sink, remaining: 90 * 60)
        XCTAssertEqual(sink.posts.count, 1)
        await evaluate(evaluator, sink: sink, remaining: 10 * 60)
        XCTAssertEqual(sink.posts.count, 2)
        XCTAssertTrue(sink.posts.last!.body(now: expiry.addingTimeInterval(-600)).contains("10 minutes"))
        await evaluate(evaluator, sink: sink, remaining: 0)
        XCTAssertEqual(sink.posts.count, 2)
        XCTAssertEqual(sink.removed, [sink.posts[0].identifier])
    }

    func testFailedDeliveryRetriesWithoutConsumingMilestone() async {
        let evaluator = ResetExpiryNotificationEvaluator(defaults: defaults)
        let sink = Sink()
        sink.succeeds = false
        await evaluate(evaluator, sink: sink, remaining: 3600)
        XCTAssertNotNil(evaluator.errorMessage)
        sink.succeeds = true
        await evaluate(evaluator, sink: sink, remaining: 3590)
        await evaluate(evaluator, sink: sink, remaining: 3580)
        XCTAssertEqual(sink.posts.count, 2)
        XCTAssertNil(evaluator.errorMessage)
    }

    func testDisableWithdrawsAndReenableDoesNotResurrectDismissedMilestone() async {
        let evaluator = ResetExpiryNotificationEvaluator(defaults: defaults)
        let sink = Sink()
        await evaluate(evaluator, sink: sink, remaining: 7200)
        await evaluate(evaluator, sink: sink, remaining: 7100, enabled: false)
        XCTAssertEqual(sink.removed, [sink.posts[0].identifier])
        await evaluate(evaluator, sink: sink, remaining: 7000)
        XCTAssertEqual(sink.posts.count, 1)
        await evaluate(evaluator, sink: sink, remaining: 3600)
        XCTAssertEqual(sink.posts.count, 2)
    }

    func testRedeemedOrMissingCreditsAreWithdrawnAndRecoveryKeepsHistory() async {
        let evaluator = ResetExpiryNotificationEvaluator(defaults: defaults)
        let sink = Sink()
        await evaluate(evaluator, sink: sink, remaining: 7200)
        await evaluate(evaluator, sink: sink, remaining: 7100, metrics: [])
        XCTAssertEqual(sink.removed, [sink.posts[0].identifier])
        await evaluate(evaluator, sink: sink, remaining: 7000)
        XCTAssertEqual(sink.posts.count, 1)
    }

    func testDifferentAccountsAndExpiriesStayIndependent() async {
        let evaluator = ResetExpiryNotificationEvaluator(defaults: defaults)
        let sink = Sink()
        let metrics = [metric(), metric(key: "codex:account-b"),
                       .init(key: "grok", providerName: "Grok", expiries: [expiry, expiry.addingTimeInterval(60)])]
        await evaluate(evaluator, sink: sink, remaining: 3600, metrics: metrics)
        XCTAssertEqual(sink.posts.count, 4)
        XCTAssertEqual(Set(sink.posts.map(\.identifier)).count, 4)
        await evaluate(evaluator, sink: sink, remaining: 3500, metrics: [metric()])
        XCTAssertEqual(sink.removed.count, 3)
        XCTAssertFalse(sink.removed.contains(ResetExpiryNotificationEvaluator.identifier(key: metric().key, expiry: expiry)))
    }

    func testSharedExpiryProducesOneAccurateGroupedReminder() async {
        let evaluator = ResetExpiryNotificationEvaluator(defaults: defaults)
        let sink = Sink()
        await evaluate(evaluator, sink: sink, remaining: 900, metrics: [
            .init(key: "grok", providerName: "Grok", expiries: [expiry, expiry])
        ])
        XCTAssertEqual(sink.posts.count, 1)
        XCTAssertTrue(sink.posts[0].body(now: expiry.addingTimeInterval(-900)).contains("2 unused resets expire"))
    }

    func testGroupedCountChangeWithdrawsOldAlertWithoutRepeatingMilestone() async {
        let evaluator = ResetExpiryNotificationEvaluator(defaults: defaults)
        let sink = Sink()
        let group = ResetExpiryNotificationEvaluator.Metric(
            key: metric().key, providerName: "Work Codex", expiries: [expiry, expiry]
        )
        await evaluate(evaluator, sink: sink, remaining: 24 * 3600, metrics: [group])
        await evaluate(evaluator, sink: sink, remaining: 23 * 3600)
        XCTAssertEqual(sink.removed, [sink.posts[0].identifier])
        XCTAssertEqual(sink.posts.count, 1)
        let restarted = ResetExpiryNotificationEvaluator(defaults: defaults)
        await evaluate(restarted, sink: sink, remaining: 22 * 3600)
        XCTAssertEqual(sink.posts.count, 1)
        await evaluate(restarted, sink: sink, remaining: 2 * 3600)
        XCTAssertEqual(sink.posts.count, 2)
        XCTAssertEqual(sink.posts[1].count, 1)
    }

    func testFractionalExpiryKeepsHistoryAcrossSnapshotCacheRoundTrip() async throws {
        let fractionalExpiry = expiry.addingTimeInterval(0.875)
        let live = ResetExpiryNotificationEvaluator.Metric(
            key: metric().key, providerName: "Work Codex", expiries: [fractionalExpiry]
        )
        let sink = Sink()
        await evaluate(ResetExpiryNotificationEvaluator(defaults: defaults), sink: sink,
                       remaining: 23 * 3600, metrics: [live])
        ProviderSnapshotCache(userDefaults: defaults, storageKey: "fractional-cache").store(
            ProviderSnapshot(providerID: "codex", displayName: "Codex", lines: [
                .values(label: "Rate Limit Resets", values: [.init(number: 1, kind: .count)],
                        expiriesAt: [fractionalExpiry])
            ])
        )
        let cache = ProviderSnapshotCache(userDefaults: defaults, storageKey: "fractional-cache")
        let snapshot = try XCTUnwrap(cache.loadSnapshots(providerIDs: ["codex"])["codex"])
        guard case .values(_, _, _, let expiries, _, _) = snapshot.lines[0] else {
            return XCTFail("Expected reset-credit values")
        }
        XCTAssertEqual(expiries, [expiry], "The persisted cache drops fractional seconds")
        let cached = ResetExpiryNotificationEvaluator.Metric(
            key: live.key, providerName: live.providerName, expiries: expiries
        )
        let restarted = ResetExpiryNotificationEvaluator(defaults: defaults)
        await evaluate(restarted, sink: sink, remaining: 22 * 3600, metrics: [cached])
        await evaluate(restarted, sink: sink, remaining: 21 * 3600, metrics: [live])
        XCTAssertEqual(sink.posts.count, 1, "Neither loading cache nor refreshing may repeat a dismissed milestone")
        XCTAssertTrue(sink.removed.isEmpty)
        await evaluate(restarted, sink: sink, remaining: 3600, metrics: [live])
        XCTAssertEqual(sink.posts.count, 2)
        XCTAssertEqual(sink.posts[0].identifier, sink.posts[1].identifier)
    }

    func testExpiredCreditNeverAlertsAndClockGoingBackDoesNotRepeat() async {
        let evaluator = ResetExpiryNotificationEvaluator(defaults: defaults)
        let sink = Sink()
        await evaluate(evaluator, sink: sink, remaining: 0)
        XCTAssertTrue(sink.posts.isEmpty)
        await evaluate(evaluator, sink: sink, remaining: 7200)
        await evaluate(evaluator, sink: sink, remaining: 24 * 3600)
        XCTAssertEqual(sink.posts.count, 1)
    }

    func testSettingsDefaultOffAndPersistOptIn() {
        let settings = NotificationSettingsStore(defaults: defaults)
        XCTAssertFalse(settings.resetExpiryReminders)
        XCTAssertFalse(settings.anyEnabled)
        settings.resetExpiryReminders = true
        let reloaded = NotificationSettingsStore(defaults: defaults)
        XCTAssertTrue(reloaded.resetExpiryReminders)
        XCTAssertTrue(reloaded.anyEnabled)
    }

    func testDeliveryErrorClearsWhenFailedCreditDisappears() async {
        let evaluator = ResetExpiryNotificationEvaluator(defaults: defaults)
        let sink = Sink()
        sink.succeeds = false
        await evaluate(evaluator, sink: sink, remaining: 3600)
        XCTAssertNotNil(evaluator.errorMessage)
        await evaluate(evaluator, sink: sink, remaining: 3500, metrics: [])
        XCTAssertNil(evaluator.errorMessage)
    }

    func testDeliveryThatBecomesObsoleteIsWithdrawnWithoutConsumingMilestone() async {
        let evaluator = ResetExpiryNotificationEvaluator(defaults: defaults)
        let sink = Sink()
        var current = true
        await evaluator.evaluate(
            metrics: [metric()], enabled: true, now: expiry.addingTimeInterval(-3600),
            post: { reminder in
                let sent = await sink.post(reminder)
                current = false
                return sent
            },
            remove: sink.remove, isCurrent: { _ in current }
        )
        XCTAssertEqual(sink.removed, [sink.posts[0].identifier])
        XCTAssertNil(evaluator.errorMessage)
        await evaluate(evaluator, sink: sink, remaining: 3590)
        XCTAssertEqual(sink.posts.count, 2)
    }

    func testSuccessfulCreditIsPersistedBeforeTheNextDeliveryAwaits() async {
        let evaluator = ResetExpiryNotificationEvaluator(defaults: defaults)
        let sink = Sink()
        let later = ResetExpiryNotificationEvaluator.Metric(
            key: "grok", providerName: "Grok", expiries: [expiry.addingTimeInterval(60)]
        )
        var deliveryCount = 0
        await evaluator.evaluate(
            metrics: [metric(), later], enabled: true, now: expiry.addingTimeInterval(-3600),
            post: { _ in
                deliveryCount += 1
                if deliveryCount == 2 {
                    // A restart here must already know about the first successful delivery.
                    await self.evaluate(ResetExpiryNotificationEvaluator(defaults: self.defaults),
                                        sink: sink, remaining: 3590)
                }
                return true
            }, remove: { _ in }
        )
        XCTAssertEqual(deliveryCount, 2)
        XCTAssertTrue(sink.posts.isEmpty)
    }
}
