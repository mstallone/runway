import Foundation

/// Reminds about unused reset credits, independently of quota-window/pace alerts. Providers expose
/// expiry instants rather than credit IDs, so credits expiring in the same second share one reminder.
/// History survives relaunch and temporary missing data; dismissing an alert never resets a milestone.
@MainActor
final class ResetExpiryNotificationEvaluator {
    struct Metric {
        /// The metric's card ID plus Runway's existing launch-resolved account identity, if known.
        let key: String
        let providerName: String
        let expiries: [Date]
        var canNotify = true
    }

    struct Reminder {
        let metricKey: String
        let expiry: Date
        let milestone: TimeInterval
        let count: Int
        let identifier: String
        let title: String
        let subtitle: String

        /// Format at delivery time: a permission prompt may have been open for hours.
        func body(now: Date) -> String {
            let minutes = max(1, Int(ceil(expiry.timeIntervalSince(now) / 60)))
            let hours = minutes / 60
            let minutesPart = minutes % 60
            var parts: [String] = []
            if hours > 0 { parts.append("\(hours) \(hours == 1 ? "hour" : "hours")") }
            if minutesPart > 0 { parts.append("\(minutesPart) \(minutesPart == 1 ? "minute" : "minutes")") }
            let subject = count == 1 ? "An unused reset expires" : "\(count) unused resets expire"
            let exact = expiry.formatted(date: .abbreviated, time: .shortened)
            return "\(subject) in \(parts.joined(separator: " ")) (\(exact)). Use before expiry."
        }
    }

    private struct State: Codable {
        let expiry: Date
        var milestone: TimeInterval
        var count: Int?
        var visible: Bool
    }

    static let thresholds: [TimeInterval] = [48 * 3600, 24 * 3600, 2 * 3600, 3600, 15 * 60]
    private static let storageKey = "runway.notifications.resetExpiryHistory.v1"
    private let defaults: UserDefaults
    private var states: [String: State] = [:]
    private var storageError: String?
    private var deliveryError: String?
    var errorMessage: String? { storageError ?? deliveryError }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let data = defaults.data(forKey: Self.storageKey) {
            do {
                states = try JSONDecoder().decode([String: State].self, from: data)
            } catch {
                AppLog.error(.notifications, "reset reminder history could not be read: \(error.localizedDescription)")
                storageError = "Reset reminder history could not be read. A previous reminder may appear again."
            }
        }
    }

    /// The most urgent threshold reached, with no catch-up burst after sleep or a late first fetch.
    static func milestone(expiry: Date, now: Date) -> TimeInterval? {
        let remaining = expiry.timeIntervalSince(now)
        guard remaining > 0 else { return nil }
        return thresholds.last { remaining <= $0 }
    }

    static func identifier(key: String, expiry: Date) -> String {
        "runway-reset-expiry-\(Data(key.utf8).base64EncodedString())-\(normalizedExpiry(expiry).timeIntervalSince1970)"
    }

    /// Match the snapshot cache's whole-second precision so live and launch-loaded credits agree.
    static func normalizedExpiry(_ expiry: Date) -> Date {
        Date(timeIntervalSince1970: floor(expiry.timeIntervalSince1970))
    }

    /// Called serially by the app's reminder loop. Failed delivery does not consume a milestone.
    /// Disabling reminders/providers, losing expiry data, or using a credit withdraws its alert,
    /// while retaining dedup history until expiry in case that same credit becomes visible again.
    func evaluate(
        metrics: [Metric], enabled: Bool, now: Date,
        post: @MainActor (Reminder) async -> Bool,
        remove: @MainActor ([String]) -> Void,
        isCurrent: @MainActor (Reminder) -> Bool = { _ in true }
    ) async {
        let active = enabled ? metrics.flatMap { metric in
            Dictionary(grouping: metric.expiries.map(Self.normalizedExpiry).filter { $0 > now }, by: { $0 })
                .map { expiry, copies in
                    (id: Self.identifier(key: metric.key, expiry: expiry), key: metric.key,
                     expiry: expiry, count: copies.count, provider: metric.providerName, canNotify: metric.canNotify)
                }
        } : []
        let activeCounts = Dictionary(uniqueKeysWithValues: active.map { ($0.id, $0.count) })
        var changed = false
        // A changed group count makes the old text inaccurate. Withdraw it without re-alerting
        // at an already-consumed milestone. Older history without a count is treated the same way.
        let withdrawn = states.filter {
            $0.value.visible && (activeCounts[$0.key] == nil || activeCounts[$0.key] != $0.value.count)
        }.map(\.key)
        if !withdrawn.isEmpty {
            remove(withdrawn)
            for id in withdrawn { states[id]?.visible = false }
            changed = true
        }
        let expired = states.filter { $0.value.expiry <= now }.map(\.key)
        for id in expired { states.removeValue(forKey: id) }
        changed = changed || !expired.isEmpty
        if changed { persist() }

        var failed = false
        for credit in active.sorted(by: { $0.expiry < $1.expiry }) {
            guard !Task.isCancelled else { break }
            guard credit.canNotify else { continue }
            guard let milestone = Self.milestone(expiry: credit.expiry, now: now),
                  milestone < (states[credit.id]?.milestone ?? .infinity)
            else { continue }
            let reminder = Reminder(
                metricKey: credit.key, expiry: credit.expiry, milestone: milestone, count: credit.count,
                identifier: credit.id,
                title: "Reset Expiring Soon",
                subtitle: "\(credit.provider) · Rate Limit Resets"
            )
            guard isCurrent(reminder) else { continue }
            let delivered = await post(reminder)
            guard !Task.isCancelled, isCurrent(reminder) else {
                if delivered {
                    remove([credit.id])
                    states[credit.id]?.visible = false
                    persist()
                }
                continue
            }
            if delivered {
                states[credit.id] = State(expiry: credit.expiry, milestone: milestone, count: credit.count, visible: true)
                // Persist each success before awaiting another delivery or permission response.
                persist()
                AppLog.info(.notifications, "reset expiry reminder delivered: \(credit.provider), \(Int(milestone))s milestone")
            } else {
                failed = true
            }
        }
        deliveryError = failed
            ? "Reset reminders could not be delivered. Check Runway’s notification permission in System Settings. Runway will retry."
            : nil
    }

    private func persist() {
        do {
            defaults.set(try JSONEncoder().encode(states), forKey: Self.storageKey)
            storageError = nil
        } catch {
            AppLog.error(.notifications, "reset reminder history could not be saved: \(error.localizedDescription)")
            storageError = "Reset reminder history could not be saved. Reminders may repeat after restarting Runway."
        }
    }
}
