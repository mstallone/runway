import Foundation
import Observation

/// A separate clock keeps the 15-minute reminder timely even while a provider refresh is slow.
/// Observation wakes the same serial loop for settings/data changes; the timer does no network work.
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
            let timer = Task {
                while !Task.isCancelled {
                    continuation.yield(())
                    do { try await Task.sleep(for: .seconds(30)) } catch { break }
                }
            }
            defer {
                timer.cancel()
                continuation.finish()
            }
            for await _ in events {
                guard !Task.isCancelled else { break }
                armObservation(continuation)
                await evaluator.evaluate(
                    metrics: dataStore.resetExpiryNotificationMetrics(),
                    enabled: settings.resetExpiryReminders,
                    now: now(),
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
            }
        }
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
