import AppKit
import Observation

/// One timer wakes at the next milestone or expiry, independently of provider refreshes.
/// Data/settings changes, Mac wake, and clock changes reschedule it without polling.
@MainActor
final class ResetExpiryNotificationMonitor {
    private let settings: NotificationSettingsStore
    private let dataStore: WidgetDataStore
    private let evaluator: ResetExpiryNotificationEvaluator
    private let notifications: AppNotifications
    private let now: () -> Date
    private var observing = false

    init(
        settings: NotificationSettingsStore, dataStore: WidgetDataStore,
        evaluator: ResetExpiryNotificationEvaluator = ResetExpiryNotificationEvaluator(),
        notifications: AppNotifications = .shared, now: @escaping () -> Date = Date.init
    ) {
        self.settings = settings
        self.dataStore = dataStore
        self.evaluator = evaluator
        self.notifications = notifications
        self.now = now
    }

    func start() -> Task<Void, Never> {
        Task {
            let (events, continuation) = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
            var timer: Timer?
            let wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
                forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
            ) { _ in continuation.yield(()) }
            let clockObserver = NotificationCenter.default.addObserver(
                forName: .NSSystemClockDidChange, object: nil, queue: .main
            ) { _ in continuation.yield(()) }
            defer {
                timer?.invalidate()
                NSWorkspace.shared.notificationCenter.removeObserver(wakeObserver)
                NotificationCenter.default.removeObserver(clockObserver)
                continuation.finish()
            }
            continuation.yield(())
            for await _ in events {
                guard !Task.isCancelled else { break }
                timer?.invalidate()
                armObservation(continuation)
                let evaluatedAt = now()
                await evaluator.evaluate(
                    metrics: dataStore.resetExpiryNotificationMetrics(),
                    enabled: settings.resetExpiryReminders,
                    now: evaluatedAt,
                    post: { reminder in
                        await notifications.post(
                            idPrefix: "reset-expiry", title: reminder.title,
                            subtitle: reminder.subtitle, body: reminder.body(now: now()),
                            replacingIdentifier: reminder.identifier,
                            shouldPost: { self.isCurrent(reminder) }
                        )
                    },
                    remove: { notifications.remove(identifiers: $0) },
                    isCurrent: isCurrent
                )
                settings.resetReminderError = evaluator.errorMessage
                if let deadline = Self.nextWakeDate(
                    metrics: dataStore.resetExpiryNotificationMetrics(),
                    enabled: settings.resetExpiryReminders, after: evaluatedAt,
                    retryDelivery: evaluator.needsDeliveryRetry
                ) {
                    let next = Timer(timeInterval: max(0, deadline.timeIntervalSince(now())), repeats: false) { _ in
                        continuation.yield(())
                    }
                    RunLoop.main.add(next, forMode: .common)
                    timer = next
                }
            }
        }
    }

    /// Use the evaluation's start time so a milestone crossed while awaiting permission is
    /// scheduled immediately, rather than skipped. Expiry itself wakes us to remove the alert.
    static func nextWakeDate(
        metrics: [ResetExpiryNotificationEvaluator.Metric], enabled: Bool,
        after date: Date, retryDelivery: Bool = false
    ) -> Date? {
        guard enabled else { return nil }
        var dates = metrics.flatMap { metric in
            let offsets = metric.canNotify ? ResetExpiryNotificationEvaluator.thresholds + [0] : [0]
            return metric.expiries.flatMap { expiry in
                offsets.map { ResetExpiryNotificationEvaluator.normalizedExpiry(expiry).addingTimeInterval(-$0) }
            }
        }
        if retryDelivery { dates.append(date.addingTimeInterval(RefreshSetting.interval)) }
        return dates.filter { $0 > date }.min()
    }

    /// Recheck after permission/delivery awaits: a used credit, changed setting, or crossed
    /// milestone must not produce an obsolete alert or consume the next reminder.
    private func isCurrent(_ reminder: ResetExpiryNotificationEvaluator.Reminder) -> Bool {
        guard settings.resetExpiryReminders,
              ResetExpiryNotificationEvaluator.milestone(expiry: reminder.expiry, now: now()) == reminder.milestone
        else { return false }
        return dataStore.resetExpiryNotificationMetrics().contains { metric in
            metric.canNotify && metric.key == reminder.metricKey
                && metric.expiries.filter {
                    ResetExpiryNotificationEvaluator.normalizedExpiry($0) == reminder.expiry
                }.count == reminder.count
        }
    }

    /// Arm once per observed change, not once per timer tick, to avoid accumulating observers.
    private func armObservation(_ continuation: AsyncStream<Void>.Continuation) {
        guard !observing else { return }
        observing = true
        withObservationTracking {
            _ = settings.resetExpiryReminders
            _ = dataStore.resetExpiryNotificationMetrics()
        } onChange: { [weak self] in
            Task { @MainActor in
                self?.observing = false
                continuation.yield(())
            }
        }
    }
}
