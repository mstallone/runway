import CoreGraphics

/// How a card lays out its Always Visible or On Demand rows. Limits become a grid of tiles; a
/// short plain value beside them joins that grid; everything else (spend rows with a breakdown,
/// charts, the exhausted-week message) stays a full-width row in its saved place. Shared by the
/// live dashboard, the drag preview, the share export, and the height estimate, so they cannot
/// drift apart.
enum MeterTileLayout {
    struct Tile<Item> {
        let item: Item
        /// How many of the grid's columns the tile spans.
        let weight: Int
    }

    struct Grid<Item> {
        let tiles: [Tile<Item>]
        /// The columns in one row of the grid; the tiles' weights fill it.
        let columns: Int
        /// Whether a plain value sits among the limits (which gives the limits unequal weights, so
        /// the grid is a single row).
        let hasValues: Bool

        /// The tiles in rows of `columns`.
        var rows: [[Tile<Item>]] {
            hasValues ? [tiles] : stride(from: 0, to: tiles.count, by: columns).map {
                Array(tiles[$0..<min($0 + columns, tiles.count)])
            }
        }
    }

    enum Segment<Item> {
        case grid(Grid<Item>)
        case row(Item)
    }

    static let columnSpacing: CGFloat = 14
    static let rowSpacing: CGFloat = 10
    static let horizontalPadding: CGFloat = 14
    static let topPadding: CGFloat = 7
    static let bottomPadding: CGFloat = 9
    /// A grid with a value in it is cut in thirds: each value takes one, the limits share the rest.
    static let thirds = 3

    /// Columns for a grid of limits alone. Up to three share a row; four sit two by two rather
    /// than leaving one alone on a second row; more wrap in threes.
    static func columns(forLimits count: Int) -> Int {
        count == 4 ? 2 : min(max(count, 1), thirds)
    }

    /// The column count every card of a provider uses for its limits, so a limit is the same width
    /// and in the same place on each account. Accounts can differ (one carries a limit another
    /// lacks): two by two only when every account has four, otherwise three across with any extra
    /// wrapping below.
    static func limitColumnsByFamily(_ cards: [(family: String, limits: Int)]) -> [String: Int] {
        Dictionary(grouping: cards.filter { $0.limits > 0 }, by: \.family).mapValues { accounts in
            accounts.allSatisfy { $0.limits == 4 } ? 2 : min(accounts.map(\.limits).max() ?? 1, thirds)
        }
    }

    /// - Parameter limitColumns: the provider's shared column count for a grid of limits alone;
    ///   `nil` uses the grid's own (`columns(forLimits:)`).
    static func segments<Item>(
        _ items: [Item],
        data: (Item) -> WidgetData,
        limitColumns: Int? = nil
    ) -> [Segment<Item>] {
        // A limit with nothing to report holds no place while the card has something to show.
        let hasData = items.contains { data($0).hasData }
        let visible = items.filter { !(hasData && data($0).isLimitTile && !data($0).hasData) }

        var segments: [Segment<Item>] = []
        var run: [Item] = []
        func limitGrid(_ limits: [Item]) -> Segment<Item> {
            let columns = limitColumns ?? columns(forLimits: limits.count)
            return .grid(Grid(tiles: limits.map { Tile(item: $0, weight: 1) }, columns: columns, hasValues: false))
        }
        func flush() {
            defer { run = [] }
            let limits = run.count { data($0).isLimitTile }
            guard limits > 0 else { return segments.append(contentsOf: run.map(Segment.row)) }
            let values = run.count - limits
            if values > 0, run.count <= thirds {
                // A value needs no more than a third; a bar reads better with the width.
                let limitWeight = (thirds - values) / limits
                let tiles = run.map { Tile(item: $0, weight: data($0).isLimitTile ? limitWeight : 1) }
                return segments.append(.grid(Grid(tiles: tiles, columns: thirds, hasValues: true)))
            }
            // Too many to share one row with values: the limits form the grid, the values keep
            // their own lines, all in saved order.
            var grid: [Item] = []
            for item in run {
                if data(item).isLimitTile {
                    grid.append(item)
                } else {
                    if !grid.isEmpty { segments.append(limitGrid(grid)); grid = [] }
                    segments.append(.row(item))
                }
            }
            if !grid.isEmpty { segments.append(limitGrid(grid)) }
        }
        for item in visible {
            if data(item).isLimitTile || data(item).valueTile != nil {
                run.append(item)
            } else {
                flush()
                segments.append(.row(item))
            }
        }
        flush()
        return segments
    }

    /// The size of a card's grid of limits alone — what `limitColumnsByFamily` compares across a
    /// provider's accounts. Zero when the card has none.
    static func limitGridSize<Item>(_ segments: [Segment<Item>]) -> Int {
        segments.map { segment in
            if case .grid(let grid) = segment, !grid.hasValues { grid.tiles.count } else { 0 }
        }.max() ?? 0
    }
}
