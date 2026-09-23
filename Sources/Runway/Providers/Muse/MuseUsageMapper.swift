import Foundation

struct MuseMappedUsage: Equatable, Sendable {
    var plan: String?
    var lines: [MetricLine]
    var observedAt: Date?
}

/// Maps the JSON response used by the Meta developer dashboard's subscription-quota API.
enum MuseUsageMapper {
    static func map(_ body: Data) throws -> MuseMappedUsage {
        guard body.count <= 1024 * 1024, let object = ProviderParse.jsonObject(body) else {
            throw MuseUsageError.invalidResponse
        }
        guard let value = object["subscription_quota"] else { throw MuseUsageError.invalidResponse }
        if value is NSNull { throw MuseUsageError.quotaUnavailable }
        guard let quota = value as? [String: Any] else { throw MuseUsageError.invalidResponse }
        // Both windows must be valid: absence must never create a reassuring zero bar.
        let window = try progressLine(quota, prefix: "window", label: "Five-Hour Usage", period: MetricPeriod.sessionMs)
        let weekly = try progressLine(quota, prefix: "weekly", label: "Weekly Usage", period: MetricPeriod.weekMs)
        return MuseMappedUsage(
            plan: displayPlan(quota["tier"] as? String), lines: [window, weekly],
            observedAt: resetDate(quota["as_of"])
        )
    }

    static func displayPlan(_ name: String?) -> String? {
        guard let trimmed = name?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty,
              trimmed.contains(where: { $0.isLetter })
        else { return nil } // The API sometimes supplies only an opaque numeric tier ID.
        let prefix = "Muse Code "
        if trimmed.lowercased().hasPrefix(prefix.lowercased()) {
            return String(trimmed.dropFirst(prefix.count)).nilIfEmpty
        }
        return trimmed
    }

    private static func progressLine(
        _ object: [String: Any], prefix: String, label: String, period: Int
    ) throws -> MetricLine {
        guard let used = ProviderParse.number(object["\(prefix)_weighted_used"]), used >= 0,
              let limit = ProviderParse.number(object["\(prefix)_weighted_limit"]), limit > 0
        else { throw MuseUsageError.invalidResponse }
        let percent = used / limit * 100
        guard percent.isFinite else { throw MuseUsageError.invalidResponse }
        return .progress(
            label: label, used: min(percent, 100), limit: 100, format: .percent,
            resetsAt: resetDate(object["\(prefix)_resets_at"]), periodDurationMs: period
        )
    }

    private static func resetDate(_ raw: Any?) -> Date? {
        guard let seconds = ProviderParse.number(raw), seconds > 0, seconds <= 64_092_211_200 else { return nil }
        return Date(timeIntervalSince1970: seconds)
    }
}
