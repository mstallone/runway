import SwiftUI

/// The selected period's split by provider: a share bar or ring with a ranked legend, shared by the
/// live card and the share-card export so the PNG can't drift from what's on screen. Groups come
/// ranked by the selected metric from `TotalSpend.projection`, so the chart reads in the same order
/// the legend reads top-down.
///
/// Accounts are grouped under their provider: one segment, one color, and one legend row per
/// provider, however many accounts it has. A provider with several accounts opens to list them.
///
/// A period or metric switch **morphs** the chart: segments are identity-keyed by provider family,
/// so each one slides and resizes to its new share and never swaps color with a neighbor. Swift
/// Charts' `SectorMark` can't do that for the ring (it matches sectors by position), so the ring
/// draws its own `RingSectorShape` per family.
struct TotalSpendBreakdown: View {
    enum Style {
        case bar
        case ring
    }

    let projection: TotalSpendProjection
    var style: Style = .bar
    /// The families whose accounts are listed. `nil` renders a static, fully collapsed legend with
    /// no disclosure controls — the share-card export.
    var expanded: Binding<Set<String>>?

    private let density = DensitySetting.compact

    private static let barHeight = TotalSpendCardHeight.barHeight
    private static let barGap: CGFloat = 2
    private static let ringDiameter = TotalSpendCardHeight.ringDiameter
    /// Wide enough for "100%" at the supporting size, so the amounts beside it stay in one column.
    private static let shareColumnWidth: CGFloat = 32
    private static let chevronWidth: CGFloat = 8

    var body: some View {
        switch style {
        case .bar:
            VStack(spacing: TotalSpendCardHeight.barToLegendSpacing) {
                shareBar
                legend
            }
        case .ring:
            HStack(spacing: 14) {
                ring
                legend
            }
        }
    }

    // MARK: - Chart

    private var shareBar: some View {
        GeometryReader { proxy in
            let segments = projection.segments
            let gaps = Self.barGap * CGFloat(max(0, segments.count - 1))
            let usableWidth = max(0, proxy.size.width - gaps)
            HStack(spacing: Self.barGap) {
                ForEach(segments) { segment in
                    Rectangle()
                        .fill(TotalSpendPalette.color(for: segment.family))
                        .frame(width: usableWidth * segment.fraction)
                }
            }
        }
        .frame(height: Self.barHeight)
        .clipShape(Capsule())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityLabel)
    }

    private var ring: some View {
        ZStack {
            ForEach(ringArcs) { arc in
                RingSectorShape(startFraction: arc.start, endFraction: arc.end)
                    .fill(TotalSpendPalette.color(for: arc.family))
            }
            Text(MetricFormatter.totalSpendTile(projection.centerValue, metric: projection.metric))
                .font(.system(size: 12, weight: .semibold, design: .rounded))
                .foregroundStyle(.primary)
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                .padding(.horizontal, 12)
        }
        .frame(width: Self.ringDiameter, height: Self.ringDiameter)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityLabel)
    }

    private struct RingArc: Identifiable, Equatable {
        let family: String
        let start: Double
        let end: Double

        var id: String { family }
    }

    private var ringArcs: [RingArc] {
        var cursor = 0.0
        return projection.segments.map { segment in
            defer { cursor += segment.fraction }
            return RingArc(family: segment.family, start: cursor, end: cursor + segment.fraction)
        }
    }

    private var accessibilityLabel: String {
        let total = MetricFormatter.totalSpend(projection.centerValue, metric: projection.metric, style: .full)
        switch projection.metric {
        case .cost:
            return "Total cost \(total) across \(projection.groups.count) providers"
        case .tokens:
            return "Total tokens \(total) across \(projection.groups.count) providers"
        case .costPerMtok:
            return "Blended cost per megatoken \(total) across \(projection.groups.count) providers"
        }
    }

    // MARK: - Legend

    private var legend: some View {
        VStack(alignment: .leading, spacing: TotalSpendCardHeight.legendRowSpacing) {
            ForEach(projection.groups) { group in
                VStack(alignment: .leading, spacing: 0) {
                    groupRow(group)
                    if group.isExpandable, expanded != nil {
                        VStack(alignment: .leading, spacing: TotalSpendCardHeight.legendRowSpacing) {
                            ForEach(group.members) { member in
                                row(title: member.title, amount: member.displayAmount, color: nil)
                            }
                        }
                        .padding(.leading, 15)
                        .padding(.top, TotalSpendCardHeight.legendRowSpacing)
                        .accordionReveal(isExpanded(group))
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        // Inset to the section header's text edge.
        .padding(.horizontal, 4)
    }

    private func isExpanded(_ group: TotalSpendGroup) -> Bool {
        group.isExpandable && (expanded?.wrappedValue.contains(group.family) ?? false)
    }

    @ViewBuilder
    private func groupRow(_ group: TotalSpendGroup) -> some View {
        // Beside the ring the legend has half the width, so the account count yields to the name.
        let title = group.isExpandable && style == .bar
            ? "\(group.title) · \(group.members.count) accounts"
            : group.title
        let content = row(
            title: title,
            amount: group.displayAmount,
            color: TotalSpendPalette.color(for: group.family),
            chevron: group.isExpandable && expanded != nil ? (isExpanded(group) ? "chevron.down" : "chevron.right") : nil
        )
        if group.isExpandable, let expanded {
            Button {
                if expanded.wrappedValue.contains(group.family) {
                    expanded.wrappedValue.remove(group.family)
                } else {
                    expanded.wrappedValue.insert(group.family)
                }
            } label: {
                content.contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityValue(isExpanded(group) ? "Expanded" : "Collapsed")
        } else {
            content
        }
    }

    private func row(title: String, amount: Double, color: Color?, chevron: String? = nil) -> some View {
        HStack(spacing: 6) {
            TotalSpendLegendRow(
                title: title,
                value: MetricFormatter.totalSpend(amount, metric: projection.metric, style: legendValueStyle),
                color: color,
                fontSize: density.supportingPointSize
            )
            // The ring leaves the legend half the width, so the share column yields to the names.
            if style == .bar, let share = projection.shareLabel(forAmount: amount) {
                Text(share)
                    .font(.system(size: density.supportingPointSize))
                    .foregroundStyle(.tertiary)
                    .monospacedDigit()
                    .lineLimit(1)
                    .frame(width: Self.shareColumnWidth, alignment: .trailing)
            }
            if hasDisclosure {
                Image(systemName: chevron ?? "chevron.right")
                    .font(.system(size: 8, weight: .semibold))
                    .foregroundStyle(.tertiary)
                    .frame(width: Self.chevronWidth)
                    .opacity(chevron == nil ? 0 : 1)
            }
        }
    }

    /// Reserve the chevron column on every row once any provider can open, so amounts stay aligned.
    private var hasDisclosure: Bool {
        expanded != nil && projection.groups.contains(where: \.isExpandable)
    }

    /// Legend amounts: tokens always abbreviated. Dollar modes keep exact cents beside the bar and
    /// abbreviate beside the ring, where the legend has half the width.
    private var legendValueStyle: MetricFormatter.Style {
        switch (projection.metric, style) {
        case (.tokens, _), (_, .ring): .row
        case (.cost, .bar), (.costPerMtok, .bar): .full
        }
    }
}
