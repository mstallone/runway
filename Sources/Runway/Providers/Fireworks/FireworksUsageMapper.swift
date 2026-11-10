import Foundation

/// Builds the Monthly Spend meter from the Fireworks `quotas` payload and picks the account from the
/// `accounts` payload.
enum FireworksUsageMapper {
    static let monthlySpendQuotaID = "monthly-spend-usd"

    /// The `monthly-spend-usd` quota as a dollar meter: `usage` against the enforced `value`, resetting
    /// at the start of the next UTC month. Throws when the payload is malformed or carries no such
    /// quota, so an uncapped account reads as unavailable rather than as "No data".
    static func monthlySpendLine(from body: Data, now: Date) throws -> MetricLine {
        guard let object = ProviderParse.jsonObject(body),
              let quotas = object["quotas"] as? [[String: Any]]
        else {
            throw FireworksUsageError.invalidResponse
        }
        guard let quota = quotas.first(where: { quotaID($0["name"]) == monthlySpendQuotaID }) else {
            throw FireworksUsageError.monthlySpendUnavailable
        }
        guard let limit = ProviderParse.number(quota["value"]), limit > 0 else {
            throw FireworksUsageError.invalidResponse
        }
        // A quota with no spend yet omits `usage`; that is a measured zero.
        let used = max(0, ProviderParse.number(quota["usage"]) ?? 0)
        return .progress(
            label: "Monthly Spend",
            used: used,
            limit: limit,
            format: .dollars,
            resetsAt: nextMonthStart(after: now),
            periodDurationMs: MetricPeriod.monthMs
        )
    }

    /// The single account visible to the key, or `nil` when it sees none or several, since the right
    /// one can't be inferred.
    static func soleAccountID(from body: Data) -> String? {
        guard let accounts = ProviderParse.jsonObject(body)?["accounts"] as? [[String: Any]],
              accounts.count == 1,
              let name = accounts[0]["name"] as? String
        else {
            return nil
        }
        let id = FireworksAuthStore.normalizedAccountID(name)
        return id.isEmpty ? nil : id
    }

    /// Fireworks budgets follow the calendar month in UTC.
    static func nextMonthStart(after date: Date) -> Date? {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        guard let monthStart = calendar.date(from: calendar.dateComponents([.year, .month], from: date)) else {
            return nil
        }
        return calendar.date(byAdding: .month, value: 1, to: monthStart)
    }

    /// The last path segment of a quota resource name (`accounts/acme/quotas/monthly-spend-usd`).
    private static func quotaID(_ name: Any?) -> String? {
        (name as? String)?.split(separator: "/").last.map(String.init)
    }
}
