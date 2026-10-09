import AppKit

/// The popover's single compact layout definition. Type, rows, provider sections, and management
/// controls all use these values so the app keeps one consistent information-dense rhythm.
enum DensitySetting: Hashable, Sendable {
    case compact

    // MARK: - Type

    /// Row text: metric names (semibold) and their readings share one size.
    var supportingPointSize: CGFloat { 11 }

    /// Provider name in the section header — a touch larger than the metric label below it so the
    /// section title reads as the heaviest thing in the group.
    var headerPointSize: CGFloat { 13 }

    /// Provider mark in the section header.
    var headerIconSize: CGFloat { 14 }

    /// Plan badge beside the provider name — always one step below the supporting text.
    var planBadgePointSize: CGFloat { 10 }

    // MARK: - Dimensions (all on the 4pt grid or its 2pt half-steps)

    /// Capsule meter height — a thin hairline like Claude Code's usage bars.
    var meterHeight: CGFloat { 4 }

    /// Usage Trend sparkline height, kept tight with the rest of the card.
    var trendChartHeight: CGFloat { 14 }

    /// Vertical padding on a text row.
    var textRowPadding: CGFloat { 4 }

    /// Vertical padding on a meter row. Wider than a text row's: each meter is its own reading,
    /// so it needs air above and below to stay scannable.
    var meterRowPadding: CGFloat { 6 }

    /// Spacing between the dashboard's provider sections. Wider than `sectionSpacing`: the
    /// outlined cards have no fill to hold them apart, so the gap does that work.
    var dashboardSectionSpacing: CGFloat { 16 }

    /// Top padding for a text-only row sitting directly under another text-only row — the
    /// neighbor-aware rule makes runs of one-liners read as one cluster.
    var condensedTextRowTopPadding: CGFloat { 1 }

    /// Spacing between provider sections, still clearly wider than the in-card rhythm.
    var sectionSpacing: CGFloat { 8 }

    /// Padding above an account's title line inside a grouped provider card, and below its last
    /// row: the air that separates one account from the next on either side of the hairline.
    var groupedAccountPadding: CGFloat { 8 }

    /// Gap between a grouped provider's header and its card. Wider than a single card's: the
    /// header names several accounts, so it stands a little further off them.
    var groupedHeaderToCardSpacing: CGFloat { 6 }

    /// Gap between a provider header and its card.
    var headerToCardSpacing: CGFloat { 4 }

    /// Vertical gutter inside a metric card (keeps the first/last row off the card edge).
    var cardGutter: CGFloat { 4 }

    /// Vertical padding on a Customize / Settings control row (toggles, pickers).
    var controlRowPadding: CGFloat { 6 }

    /// Top padding above the dashboard list.
    var contentTopPadding: CGFloat { 10 }

    /// Estimated Customize control-row height for the pre-measurement height seed
    /// (row content ≈ 24pt + `controlRowPadding` × 2).
    var estimatedMetricRowHeight: CGFloat { 36 }

    /// Gap between cells in the provider quick-links grid. Kept tight so two narrow cells still read
    /// as one cluster.
    var expandedGridSpacing: CGFloat { 4 }
}
