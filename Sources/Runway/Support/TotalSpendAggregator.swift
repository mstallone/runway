import Foundation

/// The spend period the Total Spend card can show. Today and 30 Days still match the per-provider
/// spend tiles; 7 Days is card-only and is summed from each snapshot's daily history.
enum TotalSpendPeriod: String, CaseIterable, Identifiable, Sendable {
    case today = "Today"
    case last7 = "Last 7 Days"
    case last30 = "Last 30 Days"

    var id: String { rawValue }

    /// Compact segment title for the period switcher — "Last 30 Days" doesn't fit three-across
    /// in the 320pt popover without shrinking every segment.
    var shortLabel: String {
        switch self {
        case .today: "Today"
        case .last7: "7 Days"
        case .last30: "30 Days"
        }
    }

    /// Spend-tile label used when a snapshot has no daily history (tests, and Today / 30 Days
    /// fallback). 7 Days has no matching tile.
    var lineLabel: String? {
        switch self {
        case .today: "Today"
        case .last7: nil
        case .last30: "Last 30 Days"
        }
    }

    /// Calendar days in the window, including today. 30 Days uses the same window as Usage Trend
    /// (`today` plus `UsageHistoryWindow.previousDays`) so the stacked bars add up to the pie.
    var dayCount: Int { previousDays + 1 }

    /// Days strictly before today. Zero for Today, six for 7 Days.
    var previousDays: Int {
        switch self {
        case .today: 0
        case .last7: 6
        case .last30: UsageHistoryWindow.previousDays
        }
    }

    /// Oldest-first calendar days covering this period, keyed `yyyy-MM-dd`.
    func days(through now: Date, calendar: Calendar = .current) -> [(key: String, date: Date)] {
        let today = calendar.startOfDay(for: now)
        return (0...previousDays).reversed().compactMap { offset in
            guard let date = calendar.date(byAdding: .day, value: -offset, to: today) else { return nil }
            return (DailyUsageAccumulator.dayKey(from: date, calendar: calendar), date)
        }
    }
}

/// Pie (period composition) vs stacked bars (one bar per calendar day). Persisted on the card.
enum TotalSpendChartKind: String, CaseIterable, Identifiable, Sendable {
    case pie
    case bar

    var id: String { rawValue }

    var title: String {
        switch self {
        case .pie: "Pie"
        case .bar: "Bar"
        }
    }

    var systemImage: String {
        switch self {
        case .pie: "chart.pie"
        case .bar: "chart.bar.xaxis"
        }
    }
}

/// Which quantity the Total Spend card's ring, center, and legend show. The title menu persists this
/// choice; the aggregator always collects both dollars and tokens so flipping modes doesn't re-scan.
/// Raw value `apiSpend` is kept so existing installs don't lose their stored Cost selection.
enum TotalSpendMetric: String, CaseIterable, Identifiable, Sendable {
    /// Menu order is declaration order: Cost → Cost/MTok → Tokens. Cost is the default.
    case cost = "apiSpend"
    case costPerMtok
    case tokens

    var id: String { rawValue }

    var title: String {
        switch self {
        case .cost: "Cost"
        case .costPerMtok: "Cost/MTok"
        case .tokens: "Tokens"
        }
    }

    /// Empty-state copy when no provider qualifies for this metric in the selected period.
    var emptyMessage: String {
        switch self {
        case .cost: "No cost data for this period"
        case .costPerMtok: "No cost-per-token data for this period"
        case .tokens: "No token data for this period"
        }
    }

    /// Dollar-backed modes can inherit the local-estimate note when any contributor's spend is imputed.
    var usesDollarEstimateNote: Bool {
        switch self {
        case .cost, .costPerMtok: true
        case .tokens: false
        }
    }

    /// Cost and Tokens add across providers (and therefore stack). Cost/MTok is a rate, so a day's
    /// bar is the blended figure rather than a stack of per-provider rates.
    var stacksByProvider: Bool {
        switch self {
        case .cost, .tokens: true
        case .costPerMtok: false
        }
    }
}

/// One provider's contribution to a period's total: dollars and tokens from the same spend line,
/// plus whether the dollars are a local estimate (log-scanned providers) or measured (Cursor's CSV).
struct TotalSpendSlice: Identifiable, Equatable {
    let provider: Provider
    /// The card title, resolved by the aggregation's caller through the one name resolver — so the
    /// legend, the ranking tie-break, and the share-card export (which renders outside the SwiftUI
    /// environment and can't resolve for itself) all show the same live name.
    let title: String
    let amountUSD: Double
    let tokenCount: Double
    let estimated: Bool

    var id: String { provider.id }

    /// Dollars per million tokens for this provider alone. `nil` when either side is missing.
    var costPerMtok: Double? {
        guard amountUSD > 0, tokenCount > 0 else { return nil }
        return (amountUSD / tokenCount) * 1_000_000
    }
}

/// One provider's ready-to-draw contribution under a chosen metric: the amount that sizes the ring
/// and ranks the legend, plus the formatted value surfaces read through `MetricFormatter`.
struct TotalSpendProjectedSlice: Identifiable, Equatable {
    let provider: Provider
    /// The already-resolved card title (see `TotalSpendSlice.title`) — what the legend renders.
    let title: String
    let displayAmount: Double
    let estimated: Bool

    var id: String { provider.id }
}

/// One provider's dollars and tokens on a single calendar day — the segment of a stacked bar.
struct TotalSpendDaySlice: Identifiable, Equatable {
    let providerID: String
    let title: String
    let amountUSD: Double
    let tokenCount: Double

    var id: String { providerID }
}

/// One calendar day in the selected period, including idle days so the bar chart stays calendar-true.
struct TotalSpendDay: Identifiable, Equatable {
    let dayKey: String
    let date: Date
    let slices: [TotalSpendDaySlice]

    var id: String { dayKey }

    var axisLabel: String { Formatters.monthDayLabel(date) }

    var totalUSD: Double { slices.reduce(0) { $0 + $1.amountUSD } }
    var totalTokens: Double { slices.reduce(0) { $0 + $1.tokenCount } }

    /// Height of this day's bar under the selected metric (stacked total, or blended rate).
    func amount(for metric: TotalSpendMetric) -> Double {
        switch metric {
        case .cost:
            return totalUSD
        case .tokens:
            return totalTokens
        case .costPerMtok:
            guard totalUSD > 0, totalTokens > 0 else { return 0 }
            return (totalUSD / totalTokens) * 1_000_000
        }
    }

    /// Provider stacks in `rankedIDs` order (legend order). Empty when the day is idle for this metric.
    func stacks(for metric: TotalSpendMetric, rankedIDs: [String]) -> [TotalSpendDaySlice] {
        guard metric.stacksByProvider else { return [] }
        return rankedIDs.compactMap { id in
            guard let slice = slices.first(where: { $0.providerID == id }) else { return nil }
            let value = metric == .cost ? slice.amountUSD : slice.tokenCount
            return value > 0 ? slice : nil
        }
    }
}

/// A period's cross-provider totals under one metric: ranked slices, center value, and estimate flag.
struct TotalSpendProjection: Equatable {
    let metric: TotalSpendMetric
    let slices: [TotalSpendProjectedSlice]
    let centerValue: Double
    let isEstimated: Bool

    var isEmpty: Bool { slices.isEmpty }
}

/// A period's cross-provider raw totals: every spend-capable provider that contributed dollars and/or
/// tokens, plus a calendar-true daily series for the stacked bar chart. Presentation (include / rank /
/// center) is `projection(for:)`.
struct TotalSpend: Equatable {
    let period: TotalSpendPeriod
    let slices: [TotalSpendSlice]
    /// Oldest-first, one entry per calendar day in the period — idle days included so each bar is a day.
    let days: [TotalSpendDay]

    var totalUSD: Double { slices.reduce(0) { $0 + $1.amountUSD } }
    var totalTokens: Double { slices.reduce(0) { $0 + $1.tokenCount } }
    /// The combined number is an estimate as soon as any contributor's dollars are imputed locally.
    var isEstimated: Bool { slices.contains(where: \.estimated) }
    /// Raw storage empty — no provider had dollars or tokens for the period.
    var isEmpty: Bool { slices.isEmpty }

    /// Filters, ranks, and computes the center value for the title menu's selected metric.
    func projection(for metric: TotalSpendMetric) -> TotalSpendProjection {
        let included: [(slice: TotalSpendSlice, display: Double)] = slices.compactMap { slice in
            switch metric {
            case .cost:
                guard slice.amountUSD > 0 else { return nil }
                return (slice, slice.amountUSD)
            case .tokens:
                guard slice.tokenCount > 0 else { return nil }
                return (slice, slice.tokenCount)
            case .costPerMtok:
                guard let rate = slice.costPerMtok else { return nil }
                return (slice, rate)
            }
        }

        let ranked = included.sorted { lhs, rhs in
            if lhs.display != rhs.display { return lhs.display > rhs.display }
            return lhs.slice.title.localizedStandardCompare(rhs.slice.title) == .orderedAscending
        }

        let projected = ranked.map {
            TotalSpendProjectedSlice(
                provider: $0.slice.provider,
                title: $0.slice.title,
                displayAmount: $0.display,
                estimated: $0.slice.estimated
            )
        }

        let center: Double
        let estimated: Bool
        switch metric {
        case .cost:
            center = ranked.reduce(0) { $0 + $1.slice.amountUSD }
            estimated = ranked.contains { $0.slice.estimated }
        case .tokens:
            center = ranked.reduce(0) { $0 + $1.slice.tokenCount }
            estimated = false
        case .costPerMtok:
            let usd = ranked.reduce(0) { $0 + $1.slice.amountUSD }
            let tokens = ranked.reduce(0) { $0 + $1.slice.tokenCount }
            center = tokens > 0 ? (usd / tokens) * 1_000_000 : 0
            estimated = ranked.contains { $0.slice.estimated }
        }

        return TotalSpendProjection(metric: metric, slices: projected, centerValue: center, isEstimated: estimated)
    }
}

/// Sums per-provider daily spend into one cross-provider total — the data source for the dashboard's
/// Total Spend card. Pure and synchronous: it reads already-refreshed `ProviderSnapshot`s and never
/// fetches. Prefers each snapshot's daily history so pie totals and stacked bars share one window;
/// falls back to the Today / Last 30 Days spend tiles when history is missing. Idle days are excluded
/// from the pie and kept as zero-height bars, never fabricated as zero slices.
enum TotalSpendAggregator {
    /// The total for one period across `providers` (pass them in display order; ties keep it).
    /// Slices keep provider display order input only as a stable traversal; metric projection re-ranks.
    /// `title` resolves each provider's card title — the live card passes the account-registry
    /// resolver so slices carry renames; the default is the baked derived name for callers without
    /// registry access (tests).
    static func total(
        for period: TotalSpendPeriod,
        providers: [Provider],
        snapshots: [String: ProviderSnapshot],
        now: Date = Date(),
        calendar: Calendar = .current,
        title: (Provider) -> String = { $0.displayName }
    ) -> TotalSpend {
        let window = period.days(through: now, calendar: calendar)
        let dayKeys = Set(window.map(\.key))
        let slices = providers.compactMap { provider -> TotalSpendSlice? in
            guard let snapshot = snapshots[provider.id] else { return nil }
            return slice(
                provider: provider,
                snapshot: snapshot,
                period: period,
                dayKeys: dayKeys,
                title: title(provider)
            )
        }
        return TotalSpend(
            period: period,
            slices: slices,
            days: filledDays(
                dayColumns(window: window, providers: providers, snapshots: snapshots, title: title),
                period: period,
                slices: slices
            )
        )
    }

    private static func slice(
        provider: Provider,
        snapshot: ProviderSnapshot,
        period: TotalSpendPeriod,
        dayKeys: Set<String>,
        title: String
    ) -> TotalSpendSlice? {
        if snapshot.usageHistory != nil {
            return sliceFromHistory(provider: provider, snapshot: snapshot, dayKeys: dayKeys, title: title)
        }
        return sliceFromSpendTile(provider: provider, snapshot: snapshot, period: period, title: title)
    }

    private static func sliceFromHistory(
        provider: Provider,
        snapshot: ProviderSnapshot,
        dayKeys: Set<String>,
        title: String
    ) -> TotalSpendSlice? {
        guard let history = snapshot.usageHistory else { return nil }
        var amount = 0.0
        var tokens = 0.0
        var sawCost = false
        for entry in history.series.daily where dayKeys.contains(entry.date) {
            tokens += Double(entry.totalTokens)
            if let cost = entry.costUSD {
                amount += cost
                sawCost = true
            }
        }
        guard (sawCost && amount > 0) || tokens > 0 else { return nil }
        return TotalSpendSlice(
            provider: provider,
            title: title,
            amountUSD: sawCost ? max(amount, 0) : 0,
            tokenCount: max(tokens, 0),
            estimated: dollarsAreEstimated(snapshot)
        )
    }

    private static func sliceFromSpendTile(
        provider: Provider,
        snapshot: ProviderSnapshot,
        period: TotalSpendPeriod,
        title: String
    ) -> TotalSpendSlice? {
        guard let label = period.lineLabel,
              let line = snapshot.line(label: label),
              case .values(_, let values, _, _, _, _) = line else { return nil }

        let dollars = values.filter { $0.kind == .dollars }
        let amount = dollars.reduce(0) { $0 + $1.number }
        let tokens = values
            .filter { $0.kind == .count && $0.label == "tokens" }
            .reduce(0) { $0 + $1.number }
        guard amount > 0 || tokens > 0 else { return nil }

        return TotalSpendSlice(
            provider: provider,
            title: title,
            amountUSD: max(amount, 0),
            tokenCount: max(tokens, 0),
            estimated: dollars.contains(where: \.estimated)
        )
    }

    private static func dayColumns(
        window: [(key: String, date: Date)],
        providers: [Provider],
        snapshots: [String: ProviderSnapshot],
        title: (Provider) -> String
    ) -> [TotalSpendDay] {
        var byProviderDay: [String: [String: (usd: Double, tokens: Double)]] = [:]
        for provider in providers {
            guard let history = snapshots[provider.id]?.usageHistory else { continue }
            var byDay: [String: (usd: Double, tokens: Double)] = [:]
            for entry in history.series.daily {
                var value = byDay[entry.date] ?? (0, 0)
                value.tokens += Double(entry.totalTokens)
                if let cost = entry.costUSD { value.usd += cost }
                byDay[entry.date] = value
            }
            byProviderDay[provider.id] = byDay
        }

        return window.map { key, date in
            let slices = providers.compactMap { provider -> TotalSpendDaySlice? in
                guard let value = byProviderDay[provider.id]?[key],
                      value.usd > 0 || value.tokens > 0 else { return nil }
                return TotalSpendDaySlice(
                    providerID: provider.id,
                    title: title(provider),
                    amountUSD: max(value.usd, 0),
                    tokenCount: max(value.tokens, 0)
                )
            }
            return TotalSpendDay(dayKey: key, date: date, slices: slices)
        }
    }

    /// Tile-only snapshots (no daily history) still have a Today total. Copy that composition onto
    /// today's single bar so pie and bar don't disagree for the one-day window.
    private static func filledDays(
        _ days: [TotalSpendDay],
        period: TotalSpendPeriod,
        slices: [TotalSpendSlice]
    ) -> [TotalSpendDay] {
        guard period == .today,
              let only = days.first,
              only.slices.isEmpty,
              !slices.isEmpty else { return days }
        return [
            TotalSpendDay(
                dayKey: only.dayKey,
                date: only.date,
                slices: slices.map {
                    TotalSpendDaySlice(
                        providerID: $0.provider.id,
                        title: $0.title,
                        amountUSD: $0.amountUSD,
                        tokenCount: $0.tokenCount
                    )
                }
            )
        ]
    }

    private static func dollarsAreEstimated(_ snapshot: ProviderSnapshot) -> Bool {
        snapshot.lines.contains { line in
            guard case .values(_, let values, _, _, _, _) = line else { return false }
            return values.contains { $0.kind == .dollars && $0.estimated }
        }
    }
}
