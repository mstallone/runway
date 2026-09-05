import Foundation

struct MuseMappedUsage: Equatable, Sendable {
    var plan: String?
    var lines: [MetricLine]
}

/// Normalizes `POST /muse-code/key`. The payload also carries an API key snapshot; this mapper
/// never reads that field. Percents and reset times come from `subs_usage` only.
enum MuseUsageMapper {
    static func map(_ body: Data) throws -> MuseMappedUsage {
        guard let root = ProviderParse.jsonObject(body) else {
            throw MuseUsageError.invalidResponse
        }

        switch ProviderParse.bool(root["is_subs_active"]) {
        case false?:
            throw MuseUsageError.noSubscription
        case true?:
            break
        case nil:
            throw MuseUsageError.invalidResponse
        }

        guard let usage = root["subs_usage"] as? [String: Any] else {
            throw MuseUsageError.invalidResponse
        }

        var lines: [MetricLine] = []
        if let window = usage["window"] as? [String: Any],
           let line = progressLine(
            window,
            label: "Five-Hour Usage",
            defaultPeriodMs: MetricPeriod.sessionMs,
            durationKey: "window_duration_mins"
           )
        {
            lines.append(line)
        }
        if let weekly = usage["weekly"] as? [String: Any],
           let line = progressLine(
            weekly,
            label: "Weekly Usage",
            defaultPeriodMs: MetricPeriod.weekMs,
            durationKey: nil
           )
        {
            lines.append(line)
        }
        guard !lines.isEmpty else {
            throw MuseUsageError.invalidResponse
        }

        return MuseMappedUsage(plan: displayPlan(root["subs_tier_name"] as? String), lines: lines)
    }

    /// Card badge is `Muse · Power Usage`, not `Muse · Muse Code Power Usage`.
    static func displayPlan(_ name: String?) -> String? {
        guard let trimmed = name?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .nilIfEmpty
        else {
            return nil
        }
        let prefix = "Muse Code "
        if trimmed.lowercased().hasPrefix(prefix.lowercased()) {
            return String(trimmed.dropFirst(prefix.count)).nilIfEmpty ?? trimmed
        }
        return trimmed
    }

    private static func progressLine(
        _ object: [String: Any],
        label: String,
        defaultPeriodMs: Int,
        durationKey: String?
    ) -> MetricLine? {
        guard let usedPercent = ProviderParse.number(object["used_percent"]) else {
            return nil
        }
        return .progress(
            label: label,
            used: ProviderParse.clampPercent(usedPercent),
            limit: 100,
            format: .percent,
            resetsAt: resetDate(object["resets_at"]),
            periodDurationMs: periodDurationMs(object, durationKey: durationKey) ?? defaultPeriodMs
        )
    }

    /// Muse reports unix seconds. Values that look like milliseconds are scaled down.
    private static func resetDate(_ raw: Any?) -> Date? {
        guard let value = ProviderParse.number(raw), value > 0 else { return nil }
        let seconds = value > 10_000_000_000 ? value / 1000 : value
        return Date(timeIntervalSince1970: seconds)
    }

    private static func periodDurationMs(_ object: [String: Any], durationKey: String?) -> Int? {
        guard let durationKey,
              let minutes = ProviderParse.number(object[durationKey]),
              minutes > 0
        else {
            return nil
        }
        let milliseconds = minutes * 60 * 1000
        guard milliseconds <= Double(Int.max) else { return nil }
        return Int(milliseconds)
    }
}
