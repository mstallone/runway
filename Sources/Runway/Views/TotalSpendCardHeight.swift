import CoreGraphics

/// The part of the Total Spend card's height that changes with its state — rows listed, breakdown
/// shown or folded away — as plain arithmetic on the same constants the views lay out with. The
/// card uses the difference between two states to retarget the panel inside the animation that
/// changes them, so the panel edge moves with the rows instead of chasing them. Fixed chrome (the
/// period tiles, the table's header and total) is the same in every state and left out.
enum TotalSpendCardHeight {
    /// The breakdown panel's top inset under the tiles.
    static let tilesToBreakdownSpacing: CGFloat = 11
    static let barHeight: CGFloat = 8
    static let barToLegendSpacing: CGFloat = 9
    static let ringDiameter: CGFloat = 92
    static let legendRowSpacing: CGFloat = 6
    static let tableRowSpacing: CGFloat = 5
    /// The breakdown panel's bottom inset.
    static let breakdownBottomPadding: CGFloat = 10
    static let emptyStatePadding: CGFloat = 10

    static func variable(
        layout: TotalSpendLayout,
        projections: [TotalSpendProjection],
        period: TotalSpendPeriod,
        collapsed: Bool,
        expanded: Set<String>,
        rowHeight: CGFloat
    ) -> CGFloat {
        switch layout {
        case .table:
            let table = TotalSpendTable.make(projections: projections, metric: projections.first?.metric ?? .cost)
            let rows = table.rows.reduce(0) { count, row in
                count + 1 + (row.isExpandable && expanded.contains(row.id) ? row.members.count : 0)
            }
            return CGFloat(rows) * (rowHeight + tableRowSpacing)
        case .bar, .pie:
            guard !collapsed else { return 0 }
            let index = TotalSpendPeriod.allCases.firstIndex(of: period) ?? 0
            guard projections.indices.contains(index), !projections[index].isEmpty else {
                return tilesToBreakdownSpacing + rowHeight + emptyStatePadding * 2 + breakdownBottomPadding
            }
            let rows = projections[index].groups.reduce(0) { count, group in
                count + 1 + (group.isExpandable && expanded.contains(group.family) ? group.members.count : 0)
            }
            let legend = CGFloat(rows) * rowHeight + CGFloat(max(0, rows - 1)) * legendRowSpacing
            let breakdown = layout == .pie
                ? max(ringDiameter, legend)
                : barHeight + barToLegendSpacing + legend
            return tilesToBreakdownSpacing + breakdown + breakdownBottomPadding
        }
    }
}
