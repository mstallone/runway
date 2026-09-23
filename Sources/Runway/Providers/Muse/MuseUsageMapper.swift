import Foundation

struct MuseMappedUsage: Equatable, Sendable {
    var plan: String?
    var lines: [MetricLine]
    var observedAt: Date?
}

/// The server-rendered dashboard carries weighted subscription totals. This follows the
/// usage-page approach discovered in OpenUsage PR #1248; no GraphQL tokens or inference probe.
/// https://github.com/robinebers/openusage/pull/1248
enum MuseUsageMapper {
    static func map(_ body: Data) throws -> MuseMappedUsage {
        guard body.count <= 10 * 1024 * 1024,
              let html = String(data: body, encoding: .utf8)
        else { throw MuseUsageError.invalidResponse }
        guard let marker = html.range(of: #""subscription_quota_usage"\s*:\s*"#, options: .regularExpression) else {
            throw MuseUsageError.quotaUnavailable
        }
        let value = html[marker.upperBound...]
        if value.hasPrefix("null") { throw MuseUsageError.quotaUnavailable }
        guard let raw = objectPrefix(value), let quota = ProviderParse.jsonObject(Data(raw.utf8)) else {
            throw MuseUsageError.invalidResponse
        }
        // Both windows must be valid: absence must never create a reassuring zero bar.
        let window = try progressLine(quota, prefix: "window", label: "Five-Hour Usage", period: MetricPeriod.sessionMs)
        let weekly = try progressLine(quota, prefix: "weekly", label: "Weekly Usage", period: MetricPeriod.weekMs)
        return MuseMappedUsage(
            plan: displayPlan(quota["tier"] as? String), lines: [window, weekly],
            observedAt: resetDate(quota["as_of"])
        )
    }

    /// Balanced braces must ignore quoted braces and escaped quotes inside other fields.
    private static func objectPrefix(_ text: Substring) -> Substring? {
        guard text.first == "{" else { return nil }
        var depth = 0
        var quoted = false
        var escaped = false
        for index in text.indices {
            let character = text[index]
            if quoted {
                if escaped { escaped = false }
                else if character == "\\" { escaped = true }
                else if character == "\"" { quoted = false }
            } else if character == "\"" {
                quoted = true
            } else if character == "{" {
                depth += 1
            } else if character == "}" {
                depth -= 1
                if depth == 0 { return text[...index] }
            }
        }
        return nil
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
