import SwiftUI

/// Pie or stacked-bar body shared by the live Total Spend card and the share-card export.
struct TotalSpendChartBody: View {
    let projection: TotalSpendProjection
    let days: [TotalSpendDay]
    let chartKind: TotalSpendChartKind

    var body: some View {
        switch chartKind {
        case .pie:
            TotalSpendRingContent(projection: projection)
        case .bar:
            TotalSpendBarContent(projection: projection, days: days)
        }
    }
}

/// Shared number formatting for the Total Spend ring, bars, and legend so the three surfaces
/// never disagree on cents vs compact tokens.
enum TotalSpendFormat {
    static func string(_ value: Double, metric: TotalSpendMetric, style: MetricFormatter.Style) -> String {
        switch metric {
        case .cost:
            return MetricFormatter.number(value, kind: .dollars, style: style)
        case .tokens:
            return MetricFormatter.number(value, kind: .count, style: style)
        case .costPerMtok:
            return MetricFormatter.costPerMtok(value, style: style)
        }
    }

    static func legendStyle(for metric: TotalSpendMetric) -> MetricFormatter.Style {
        switch metric {
        case .tokens: .row
        case .cost, .costPerMtok: .full
        }
    }
}

/// Ranked legend shared by the ring and the stacked bars.
struct TotalSpendLegend: View {
    let projection: TotalSpendProjection

    private let density = DensitySetting.compact

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            ForEach(projection.slices) { slice in
                TotalSpendLegendRow(
                    title: slice.title,
                    value: TotalSpendFormat.string(
                        slice.displayAmount,
                        metric: projection.metric,
                        style: TotalSpendFormat.legendStyle(for: projection.metric)
                    ),
                    color: TotalSpendPalette.color(for: slice.provider.id),
                    fontSize: density.supportingPointSize
                )
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Stacked (or blended) daily bars for the Total Spend card: one bar per calendar day in the
/// selected period, sharing the ring's legend and brand colors. Cost and Tokens stack by provider;
/// Cost/MTok is a rate, so each day is a single bar at the blended figure. Hovering a column swaps
/// the header to that day's total, the same reveal the Usage Trend detail uses.
struct TotalSpendBarContent: View {
    let projection: TotalSpendProjection
    let days: [TotalSpendDay]

    @State private var hoveredDayKey: String?

    private static let chartHeight: CGFloat = 96
    private static let minBarWidth: CGFloat = 3
    private static let idleBarHeight: CGFloat = 2

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            chart
            axis
            TotalSpendLegend(projection: projection)
        }
    }

    private var hoveredDay: TotalSpendDay? {
        days.first { $0.dayKey == hoveredDayKey }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            if let day = hoveredDay {
                Text(day.axisLabel)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.primary)
                Spacer(minLength: 8)
                Text(formattedAmount(day.amount(for: projection.metric)))
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                    .foregroundStyle(.primary)
                    .monospacedDigit()
            } else {
                let center = MetricFormatter.totalSpendRingCenter(
                    projection.centerValue,
                    metric: projection.metric
                )
                Text(center.primary)
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                    .foregroundStyle(.primary)
                    .monospacedDigit()
                Text(center.unit)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.tertiary)
                Spacer(minLength: 0)
            }
        }
        .animation(.easeOut(duration: 0.12), value: hoveredDayKey)
    }

    private var rankedIDs: [String] {
        projection.slices.map(\.provider.id)
    }

    private var peak: Double {
        max(1, days.map { $0.amount(for: projection.metric) }.max() ?? 1)
    }

    private var barSpacing: CGFloat {
        days.count <= 7 ? 2 : 1
    }

    private var chart: some View {
        HStack(alignment: .bottom, spacing: barSpacing) {
            ForEach(days) { day in
                Color.clear
                    .frame(minWidth: Self.minBarWidth, maxWidth: .infinity)
                    .frame(height: Self.chartHeight)
                    .overlay(alignment: .bottom) {
                        bar(for: day)
                    }
                    .contentShape(Rectangle())
                    .onContinuousHover { phase in
                        if case .active = phase { hoveredDayKey = day.dayKey }
                    }
                    .opacity(hoveredDayKey == nil || hoveredDayKey == day.dayKey ? 1 : 0.35)
            }
        }
        .frame(height: Self.chartHeight)
        .onContinuousHover { phase in
            if case .ended = phase { hoveredDayKey = nil }
        }
        .animation(.easeOut(duration: 0.12), value: hoveredDayKey)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityLabel)
    }

    @ViewBuilder
    private func bar(for day: TotalSpendDay) -> some View {
        let amount = day.amount(for: projection.metric)
        if amount <= 0 {
            RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                .fill(.quaternary)
                .frame(height: Self.idleBarHeight)
        } else if projection.metric.stacksByProvider {
            let stacks = day.stacks(for: projection.metric, rankedIDs: rankedIDs)
            let total = stacks.reduce(0.0) { sum, slice in
                sum + (projection.metric == .cost ? slice.amountUSD : slice.tokenCount)
            }
            let height = barHeight(amount)
            VStack(spacing: 0) {
                // Legend order is largest first; reverse so the biggest spender sits at the base.
                ForEach(Array(stacks.reversed())) { slice in
                    let value = projection.metric == .cost ? slice.amountUSD : slice.tokenCount
                    let share = total > 0 ? value / total : 0
                    TotalSpendPalette.color(for: slice.providerID)
                        .frame(height: height * share)
                }
            }
            .frame(height: height, alignment: .bottom)
            .clipShape(RoundedRectangle(cornerRadius: 2, style: .continuous))
        } else {
            RoundedRectangle(cornerRadius: 2, style: .continuous)
                .fill(.secondary)
                .frame(height: barHeight(amount))
        }
    }

    private func barHeight(_ value: Double) -> CGFloat {
        let height = Self.chartHeight
        guard value > 0 else { return Self.idleBarHeight }
        let ratio = min(1, value / peak)
        return max(height * 0.08, height * ratio)
    }

    private var axis: some View {
        HStack(spacing: barSpacing) {
            ForEach(Array(days.enumerated()), id: \.element.id) { index, day in
                Text(showsAxisLabel(index: index) ? day.axisLabel : "")
                    .font(.system(size: 8, weight: .medium))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
                    .frame(minWidth: Self.minBarWidth, maxWidth: .infinity)
                    .opacity(showsAxisLabel(index: index) ? 1 : 0)
            }
        }
    }

    private func showsAxisLabel(index: Int) -> Bool {
        let count = days.count
        if count <= 7 { return true }
        return index == 0 || index == count - 1 || index == count / 2
    }

    private var accessibilityLabel: String {
        let center = TotalSpendFormat.string(projection.centerValue, metric: projection.metric, style: .full)
        let range: String
        if let first = days.first, let last = days.last {
            range = "\(first.axisLabel) to \(last.axisLabel)"
        } else {
            range = "this period"
        }
        switch projection.metric {
        case .cost:
            return "Daily cost \(center) from \(range), \(days.count) days"
        case .tokens:
            return "Daily tokens \(center) from \(range), \(days.count) days"
        case .costPerMtok:
            return "Daily cost per megatoken \(center) from \(range), \(days.count) days"
        }
    }

    private func formattedAmount(_ value: Double) -> String {
        TotalSpendFormat.string(
            value,
            metric: projection.metric,
            style: TotalSpendFormat.legendStyle(for: projection.metric)
        )
    }
}
