import SwiftUI

/// The period switch and the headline numbers in one control: each tile shows its period's
/// combined total. The tiles are bare text on the popover, all three at full strength, and the
/// surface that marks the selection is drawn by the card behind them (`JoinedTabShape`), joined to
/// the breakdown it opens. With no selection the card is collapsed to this headline alone.
/// Pointing at an unselected tile dims its text a step; there is no hover background.
struct TotalSpendPeriodTiles: View {
    /// One projection per `TotalSpendPeriod.allCases` entry, in that order.
    let projections: [TotalSpendProjection]
    /// `nil` while the card is collapsed to its headline.
    let selection: TotalSpendPeriod?
    let select: (TotalSpendPeriod) -> Void

    @Environment(\.popoverIsVisible) private var popoverIsVisible
    @State private var hovered: TotalSpendPeriod?

    /// The gap between tiles; `JoinedTabShape` lays its tab out with the same value.
    static let spacing: CGFloat = 8

    var body: some View {
        HStack(spacing: Self.spacing) {
            ForEach(Array(zip(TotalSpendPeriod.allCases, projections)), id: \.0) { candidate, projection in
                periodTile(candidate, projection: projection)
            }
        }
        // `NSPanel.orderOut` may not deliver a hover exit, so clear the highlight at the panel's
        // authoritative close signal instead of reopening with a tile still lit.
        .onChange(of: popoverIsVisible) { _, isVisible in
            if !isVisible { hovered = nil }
        }
    }

    private func periodTile(_ candidate: TotalSpendPeriod, projection: TotalSpendProjection) -> some View {
        let isSelected = candidate == selection
        // Every total stays at full strength so all three are readable at a glance; the surface
        // behind the selected one marks the selection. Pointing at another total dims it a step,
        // which is the cue that it responds to a click.
        let isDimmed = hovered == candidate && !isSelected
        return Button {
            select(candidate)
        } label: {
            VStack(alignment: .leading, spacing: 1) {
                Text(candidate.shortLabel)
                    .font(.system(size: 10, weight: isSelected ? .semibold : .medium))
                    .foregroundStyle(isDimmed ? AnyShapeStyle(.tertiary) : AnyShapeStyle(.secondary))
                    .lineLimit(1)
                Text(tileValue(projection))
                    .font(.system(size: 15, weight: .semibold, design: .rounded))
                    .foregroundStyle(isDimmed ? AnyShapeStyle(.secondary) : AnyShapeStyle(.primary))
                    .monospacedDigit()
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
            }
            // The value may shrink to fit its width, never to give up height to a neighbor.
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 10)
            .padding(.top, 6)
            .padding(.bottom, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { inside in
            if inside { hovered = candidate } else if hovered == candidate { hovered = nil }
        }
        .animation(.easeOut(duration: 0.12), value: hovered)
        .accessibilityLabel("\(candidate.rawValue), \(tileAccessibilityValue(projection))")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    /// A period with nothing for the active metric shows a dash — never a fabricated zero.
    private func tileValue(_ projection: TotalSpendProjection) -> String {
        guard !projection.isEmpty else { return "–" }
        return MetricFormatter.totalSpendTile(projection.centerValue, metric: projection.metric)
    }

    private func tileAccessibilityValue(_ projection: TotalSpendProjection) -> String {
        guard !projection.isEmpty else { return "No data" }
        return MetricFormatter.totalSpend(projection.centerValue, metric: projection.metric, style: .full)
    }
}
