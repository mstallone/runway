import CoreGraphics

/// The caret co-animation's first-toggle height guess, split out of `DashboardView` (which keeps
/// only the animation clock): everything here is deterministic row math, unit-tested in
/// `ExpansionHeightEstimatorTests`.
///
/// The guess must mirror the live card's render path (`ResolvedCard.rows`) exactly:
/// - only applicability-filtered rows render (a Copilot seat's other-plan metrics never appear);
/// - when that filtering empties the Always Visible side, the card PROMOTES the applicable
///   On Demand rows above the caret, leaving the expansion metric-less (links only);
/// - each revealed row is priced by its rendered anatomy, with adjacent text rows condensing
///   (per side — the expansion never condenses across the caret).
/// Counting raw saved widgets at a flat per-row constant instead made the panel spring past the
/// real height on a provider's first toggle — and, because the settle's learn step discards
/// implausible values, replay that overshoot on every toggle for providers whose saved rows
/// diverge from their rendered ones.
enum ExpansionHeightEstimator {
    /// One saved widget resolved against the live account: its descriptor id, the row data the
    /// dashboard would render, and whether the account's plan lets it render at all.
    struct Row {
        let id: String
        let data: WidgetData
        let isApplicable: Bool
    }

    /// The rows the caret actually reveals: the applicability-filtered On Demand rows — or none
    /// when an empty (post-filter) Always Visible side promotes them above the caret. A compact
    /// notice prevents promotion and hides unavailable rows, matching the rendered card.
    static func expandedSectionRows(alwaysShown: [Row], expanded: [Row], hasNotice: Bool = false) -> [Row] {
        guard hasNotice || alwaysShown.contains(where: \.isApplicable) else { return [] }
        return expanded.filter { $0.isApplicable && (!hasNotice || $0.data.hasData) }
    }

    /// Ties a learned delta to the provider's revealed composition: the ordered metric IDs (order
    /// matters — adjacent text rows condense) plus quick-links presence. Customizing what sits
    /// behind the caret — or an account/plan change shifting applicability — changes the key, so
    /// a stale height can't retarget the first toggle after either.
    static func deltaKey(providerID: String, revealedRows: [Row], hasLinks: Bool) -> String {
        "\(providerID)|\(revealedRows.map(\.id).joined(separator: ","))\(hasLinks ? "|links" : "")"
    }

    /// The full expansion guess: every revealed row priced by its anatomy, plus the quick-links
    /// row. The real measurement replaces this within a couple of frames (with a small same-spring
    /// correction) and is remembered exactly afterwards.
    static func estimatedDelta(revealedRows: [Row], linkCount: Int) -> CGFloat {
        let datas = revealedRows.map(\.data)
        let condensed = WidgetData.condensedTextRowOffsets(in: datas)
        let segments = MeterTileLayout.segments(Array(datas.enumerated()), data: \.element)
        let rows = segments.reduce(CGFloat(0)) { sum, segment in
            switch segment {
            case .grid(let grid):
                sum + estimatedTileGridHeight(rows: grid.rows.count)
            case .row(let row):
                sum + estimatedRowHeight(row.element, condensedTop: condensed.contains(row.offset))
            }
        }
        let links = estimatedLinksRowHeight(linkCount: linkCount)
        // The hairline between Always Visible and On Demand exists only while the card is open.
        return rows + links + (rows + links > 0 ? separatorRowHeight : 0)
    }

    /// The open card's separator row: a 1pt line inside its vertical padding (see
    /// `WidgetGroupedListView.expandedSeparator`).
    static let separatorRowHeight: CGFloat = 1 + separatorRowPadding * 2
    static let separatorRowPadding: CGFloat = 4

    /// One row's estimated rendered height, mirroring `WidgetRowView`'s anatomy branch by branch
    /// (chart → sparkline, bounded → the exhausted message or a lone tile, unbounded → one
    /// line plus optional subtitle) on the compact density constants. Line heights are rounded-up approximations of
    /// the resolved fonts; the settled measurement still corrects and learns the exact value, this
    /// only has to land close enough that the first toggle's correction is invisible.
    static func estimatedRowHeight(_ data: WidgetData, condensedTop: Bool) -> CGFloat {
        let density = DensitySetting.compact
        let labelLine: CGFloat = 15
        let supportingLine: CGFloat = 14
        if data.isChart, data.hasData {
            // The sparkline lays its label BESIDE the bars (`UsageSparkline` is an HStack), so the
            // row's content height is the taller of the two, not their sum.
            return density.textRowPadding * 2 + max(labelLine, density.trendChartHeight)
        }
        if data.exhaustedWeeklyTitle != nil {
            return density.meterRowPadding * 2 + supportingLine
        }
        let top = condensedTop ? density.condensedTextRowTopPadding : density.textRowPadding
        let subtitle: CGFloat = data.unboundedSubtitle == nil ? 0 : supportingLine
        return top + density.textRowPadding + labelLine + subtitle
    }

    /// A tile grid's estimated height: its padding, its rows of tiles, and the gaps between them
    /// (see `MetricTileGrid`). Every tile is the same height, whatever its state.
    static func estimatedTileGridHeight(rows: Int) -> CGFloat {
        guard rows > 0 else { return 0 }
        return MeterTileLayout.topPadding + MeterTileLayout.bottomPadding
            + CGFloat(rows) * estimatedTileHeight + CGFloat(rows - 1) * MeterTileLayout.rowSpacing
    }

    /// One tile's four lines: name, reading, bar, time (see `MetricTileView`).
    static var estimatedTileHeight: CGFloat {
        let density = DensitySetting.compact
        let nameLine: CGFloat = 14
        let readingLine: CGFloat = 16
        let timeLine: CGFloat = 12
        return nameLine + readingLine + density.meterHeight + MetricTileView.barPadding * 2 + timeLine + 3
    }

    /// The quick-links row's estimated height: small bordered buttons (~22pt) in up-to-three-across
    /// rows with the grid gap, inside the row's text paddings (see `ProviderLinksView`).
    static func estimatedLinksRowHeight(linkCount: Int) -> CGFloat {
        guard linkCount > 0 else { return 0 }
        let density = DensitySetting.compact
        let buttonRows = CGFloat((linkCount + 2) / 3)
        return density.textRowPadding * 2 + buttonRows * 22
            + (buttonRows - 1) * density.expandedGridSpacing
    }
}
