import AppKit
import XCTest
@testable import Runway

@MainActor
final class WidgetDataStoreResetExpiryTests: XCTestCase {
    private let expiry = Date(timeIntervalSince1970: 2_000_000_000)
    private var suite: String!
    private var defaults: UserDefaults!

    override func setUp() async throws {
        suite = "WidgetDataStoreResetExpiryTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)!
    }

    override func tearDown() async throws {
        defaults.removePersistentDomain(forName: suite)
    }

    private final class Runtime: ProviderRuntime {
        private(set) var refreshCount = 0
        let provider: Provider
        var snapshot: ProviderSnapshot
        init(id: String = "codex") {
            provider = Provider(id: id, displayName: "Codex", icon: .providerMark("codex"))
            snapshot = ProviderSnapshot(providerID: id, displayName: "Codex", lines: [])
        }
        var widgetDescriptors: [WidgetDescriptor] {
            [.values(id: "\(provider.id).resets", provider: provider, title: "Rate Limit Resets",
                     metricLabel: "Rate Limit Resets", showsResetExpiries: true),
             .values(id: "\(provider.id).other", provider: provider, title: "Other", metricLabel: "Other")]
        }
        func refresh() async -> ProviderSnapshot {
            refreshCount += 1
            return snapshot
        }
    }

    private final class Preferences {
        var enabled = true
        var title = "Work Account"
    }

    private func makeStore(
        runtime: Runtime, preferences: Preferences = Preferences(), identity: String? = "account-a",
        cache: ProviderSnapshotCache? = nil
    ) -> WidgetDataStore {
        WidgetDataStore(
            registry: WidgetRegistry(providers: [runtime.provider], descriptors: runtime.widgetDescriptors),
            providers: [runtime],
            cache: cache ?? ProviderSnapshotCache(userDefaults: defaults, storageKey: UUID().uuidString),
            defaults: defaults,
            isProviderEnabled: { _ in preferences.enabled },
            orderedDescriptors: { [] }, // All rows hidden: expiry reminders still cover the account.
            providerIdentityKeys: identity.map { [runtime.provider.id: $0] } ?? [:],
            resolveDisplayName: { _ in preferences.title }
        )
    }

    private func resetLine(count: Double = 1, expiries: [Date]? = nil) -> MetricLine {
        .values(label: "Rate Limit Resets", values: [.init(number: count, kind: .count, label: "available")],
                expiriesAt: expiries ?? [expiry])
    }

    func testHiddenResetRowsStillRemindAndProviderDisableRemovesThem() async {
        let runtime = Runtime()
        runtime.snapshot.lines = [resetLine()]
        let preferences = Preferences()
        let store = makeStore(runtime: runtime, preferences: preferences)
        await store.refreshAll(force: true)
        let metrics = store.resetExpiryNotificationMetrics()
        XCTAssertEqual(metrics.count, 1)
        XCTAssertEqual(metrics.first?.expiries, [expiry])
        XCTAssertEqual(metrics.first?.providerName, "Work Account")
        preferences.title = "Personal Account"
        XCTAssertEqual(store.resetExpiryNotificationMetrics().first?.key, metrics.first?.key)
        XCTAssertEqual(store.resetExpiryNotificationMetrics().first?.providerName, "Personal Account")
        preferences.enabled = false
        XCTAssertTrue(store.resetExpiryNotificationMetrics().isEmpty)
    }

    func testNoSampleExpiriesOrOrdinaryQuotaResetReminders() async {
        let runtime = Runtime()
        let store = makeStore(runtime: runtime)
        XCTAssertTrue(store.resetExpiryNotificationMetrics().isEmpty)
        runtime.snapshot.lines = [
            .progress(label: "Rate Limit Resets", used: 50, limit: 100, format: .percent, resetsAt: expiry),
            .values(label: "Other", values: [.init(number: 1, kind: .count)], expiriesAt: [expiry])
        ]
        await store.refreshAll(force: true)
        XCTAssertTrue(store.resetExpiryNotificationMetrics().isEmpty)
    }

    func testCountOnlyDataNeverInventsAnExpiryAndZeroCreditsAreRemoved() async {
        let runtime = Runtime()
        let store = makeStore(runtime: runtime)
        runtime.snapshot.lines = [resetLine(expiries: [])]
        await store.refreshAll(force: true)
        XCTAssertEqual(store.resetExpiryNotificationMetrics().first?.expiries, [])
        runtime.snapshot.lines = [resetLine(count: 0)]
        await store.refreshAll(force: true)
        XCTAssertEqual(store.resetExpiryNotificationMetrics().first?.expiries, [])
    }

    func testAccountSwapAtSameCardCannotReuseReminderHistory() async {
        let runtime = Runtime()
        runtime.snapshot.lines = [resetLine()]
        let first = makeStore(runtime: runtime, identity: "account-a")
        let second = makeStore(runtime: runtime, identity: "account-b")
        await first.refreshAll(force: true)
        await second.refreshAll(force: true)
        XCTAssertNotEqual(first.resetExpiryNotificationMetrics().first?.key,
                          second.resetExpiryNotificationMetrics().first?.key)
    }

    func testCachedCreditCannotAlertBeforeInitialRevalidation() async {
        let runtime = Runtime()
        runtime.snapshot.lines = [resetLine()]
        ProviderSnapshotCache(userDefaults: defaults, storageKey: "launch-cache")
            .store(runtime.snapshot, producedByIdentityKey: "account-a")
        let cache = ProviderSnapshotCache(userDefaults: defaults, storageKey: "launch-cache")
        let store = makeStore(runtime: runtime, cache: cache)
        let evaluator = ResetExpiryNotificationEvaluator(defaults: defaults)
        var posts = 0
        let evaluate = {
            await evaluator.evaluate(
                metrics: store.resetExpiryNotificationMetrics(), enabled: true,
                now: self.expiry.addingTimeInterval(-3600), post: { _ in posts += 1; return true }, remove: { _ in }
            )
        }
        await evaluate()
        XCTAssertEqual(posts, 0, "Cached credits may have been used while Runway was closed")
        runtime.snapshot.lines = [resetLine(count: 0, expiries: [])]
        await store.refreshAll(force: true)
        await evaluate()
        XCTAssertEqual(posts, 0)
        runtime.snapshot.lines = [resetLine(expiries: [expiry.addingTimeInterval(60)])]
        await store.refreshAll(force: true)
        await evaluate()
        XCTAssertEqual(posts, 1, "A successful refresh enables future reminders")
    }

    func testSeparateCardsKeepDistinctReminderKeysEvenForTheSameAccount() async {
        let firstRuntime = Runtime()
        firstRuntime.snapshot.lines = [resetLine()]
        let first = makeStore(runtime: firstRuntime)
        await first.refreshAll(force: true)
        let secondRuntime = Runtime(id: "codex@abc123")
        secondRuntime.snapshot.lines = [resetLine()]
        let second = makeStore(runtime: secondRuntime)
        await second.refreshAll(force: true)
        let metrics = first.resetExpiryNotificationMetrics() + second.resetExpiryNotificationMetrics()
        XCTAssertEqual(Set(metrics.map(\.key)).count, 2)
        var posts = 0
        await ResetExpiryNotificationEvaluator(defaults: defaults).evaluate(
            metrics: metrics, enabled: true, now: expiry.addingTimeInterval(-3600),
            post: { _ in posts += 1; return true }, remove: { _ in }
        )
        XCTAssertEqual(posts, 2)
    }

    func testMonitorWithdrawsOnSettingChangeWithoutWaitingForTimerOrRefresh() async {
        let runtime = Runtime()
        runtime.snapshot.lines = [resetLine()]
        let store = makeStore(runtime: runtime)
        await store.refreshAll(force: true)
        let settings = NotificationSettingsStore(defaults: defaults)
        settings.resetExpiryReminders = true
        let client = RecordingNotificationClient()
        let posted = expectation(description: "Reminder posted")
        let withdrawn = expectation(description: "Reminder withdrawn")
        client.didAdd = { posted.fulfill() }
        client.didRemove = { withdrawn.fulfill() }
        let monitor = ResetExpiryNotificationMonitor(
            settings: settings, dataStore: store,
            evaluator: ResetExpiryNotificationEvaluator(defaults: defaults),
            notifications: AppNotifications(client: client), now: { self.expiry.addingTimeInterval(-3600) }
        )
        let task = monitor.start()
        defer { task.cancel() }
        await fulfillment(of: [posted], timeout: 1)
        settings.resetExpiryReminders = false
        await fulfillment(of: [withdrawn], timeout: 1)
        XCTAssertTrue(client.delivered.isEmpty)
        XCTAssertNil(settings.resetReminderError)
        task.cancel()
        await task.value
    }

    func testCreditUsedDuringDeliveryIsRemovedAndDoesNotLeaveAnError() async {
        let runtime = Runtime()
        runtime.snapshot.lines = [resetLine()]
        let store = makeStore(runtime: runtime)
        await store.refreshAll(force: true)
        let settings = NotificationSettingsStore(defaults: defaults)
        settings.resetExpiryReminders = true
        let client = RecordingNotificationClient()
        let withdrawn = expectation(description: "Obsolete delivery withdrawn")
        client.beforeAdd = { _ in
            runtime.snapshot.lines = [self.resetLine(count: 0, expiries: [])]
            await store.refreshAll(force: true)
        }
        client.didRemove = { withdrawn.fulfill() }
        let monitor = ResetExpiryNotificationMonitor(
            settings: settings, dataStore: store,
            evaluator: ResetExpiryNotificationEvaluator(defaults: defaults),
            notifications: AppNotifications(client: client), now: { self.expiry.addingTimeInterval(-3600) }
        )
        let task = monitor.start()
        defer { task.cancel() }
        await fulfillment(of: [withdrawn], timeout: 1)
        XCTAssertTrue(client.delivered.isEmpty)
        XCTAssertNil(settings.resetReminderError)
        task.cancel()
        await task.value
    }

    func testMilestoneCrossedDuringPermissionWaitIsDeliveredImmediately() async {
        let runtime = Runtime()
        runtime.snapshot.lines = [resetLine()]
        let store = makeStore(runtime: runtime)
        await store.refreshAll(force: true)
        let settings = NotificationSettingsStore(defaults: defaults)
        settings.resetExpiryReminders = true
        let client = RecordingNotificationClient()
        var now = expiry.addingTimeInterval(-901)
        client.status = .notDetermined
        client.authorize = {
            now = self.expiry.addingTimeInterval(-600)
            return true
        }
        let posted = expectation(description: "Current milestone delivered after permission")
        client.didAdd = { posted.fulfill() }
        let task = ResetExpiryNotificationMonitor(
            settings: settings, dataStore: store,
            evaluator: ResetExpiryNotificationEvaluator(defaults: defaults),
            notifications: AppNotifications(client: client), now: { now }
        ).start()
        defer { task.cancel() }
        await fulfillment(of: [posted], timeout: 1)
        XCTAssertEqual(client.requests.count, 1)
        XCTAssertTrue(client.requests.first?.content.body.contains("10 minutes") == true)
        task.cancel()
        await task.value
    }

    func testTimerWithdrawsAtExpiryWithoutPollingOrRefreshingProvider() async {
        let runtime = Runtime()
        let imminentExpiry = Date(timeIntervalSince1970: floor(Date().timeIntervalSince1970) + 2)
        runtime.snapshot.lines = [resetLine(expiries: [imminentExpiry])]
        let store = makeStore(runtime: runtime)
        await store.refreshAll(force: true)
        let settings = NotificationSettingsStore(defaults: defaults)
        settings.resetExpiryReminders = true
        let client = RecordingNotificationClient()
        let removed = expectation(description: "Alert withdrawn at expiry")
        client.didRemove = { removed.fulfill() }
        let task = ResetExpiryNotificationMonitor(
            settings: settings, dataStore: store,
            evaluator: ResetExpiryNotificationEvaluator(defaults: defaults),
            notifications: AppNotifications(client: client)
        ).start()
        defer { task.cancel() }
        await fulfillment(of: [removed], timeout: 4)
        XCTAssertEqual(client.requests.count, 1)
        XCTAssertTrue(client.delivered.isEmpty)
        XCTAssertEqual(runtime.refreshCount, 1)
        task.cancel()
        await task.value
    }

    func testWakeAndClockChangesReevaluateTheCurrentMilestone() async {
        let runtime = Runtime()
        runtime.snapshot.lines = [resetLine()]
        let store = makeStore(runtime: runtime)
        await store.refreshAll(force: true)
        let settings = NotificationSettingsStore(defaults: defaults)
        settings.resetExpiryReminders = true
        let client = RecordingNotificationClient()
        var posted = expectation(description: "Initial reminder")
        client.didAdd = { posted.fulfill() }
        var now = expiry.addingTimeInterval(-24 * 3600)
        let task = ResetExpiryNotificationMonitor(
            settings: settings, dataStore: store,
            evaluator: ResetExpiryNotificationEvaluator(defaults: defaults),
            notifications: AppNotifications(client: client), now: { now }
        ).start()
        defer { task.cancel() }
        await fulfillment(of: [posted], timeout: 1)

        posted = expectation(description: "Catch up after Mac wake")
        now = expiry.addingTimeInterval(-90 * 60)
        NSWorkspace.shared.notificationCenter.post(name: NSWorkspace.didWakeNotification, object: nil)
        await fulfillment(of: [posted], timeout: 1)

        posted = expectation(description: "Catch up after clock change")
        now = expiry.addingTimeInterval(-10 * 60)
        NotificationCenter.default.post(name: .NSSystemClockDidChange, object: nil)
        await fulfillment(of: [posted], timeout: 1)
        XCTAssertEqual(client.requests.count, 3)
        XCTAssertEqual(client.delivered.count, 1)
        task.cancel()
        await task.value
    }
}
