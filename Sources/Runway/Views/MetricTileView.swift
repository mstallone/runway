import SwiftUI

/// One tile in a card's grid. Every tile is the same four lines — name, reading, bar, time — so
/// the accounts of a provider share one shape and the eye compares only the values. State changes
/// what a line says and its color, never whether the line exists:
/// - the reading turns red when the limit is spent;
/// - the bar's color is the pace verdict, with the even-pace tick as its one comparison mark;
/// - the time is the reset, or a flame and the run-out time on a limit on course to run out.
/// A plain value (see `WidgetData.valueTile`) is the same tile with nothing drawn where the bar
/// goes. Sentences ("~33% left at reset", "Limit in 3h 45m") live in the hover, not the tile —
/// one hover card over the whole tile (`TileDetailView`), and only when it adds something the tile
/// does not already show.
/// The tile has no controls of its own: in the live card the whole tile is one click target that
/// opens the card (see `WidgetGroupedListView.tile`).
struct MetricTileView: View {
    let data: WidgetData
    private let density = DensitySetting.compact
    /// The popover's shared 30s clock (see `WidgetRowView`); `nil` in one-shot renders.
    @Environment(DashboardClock.self) private var clock: DashboardClock?

    /// The tile's three sizes: the reading, the name, and the time under the bar.
    static let readingSize: CGFloat = 13
    static let nameSize: CGFloat = 11
    static let timeSize: CGFloat = 10
    static let barPadding: CGFloat = 3

    var body: some View {
        // Dated tiles re-render on the clock's tick so countdowns and pace stay live.
        let _ = data.resetsAt != nil ? clock?.halfMinute : nil
        let state = data.meterState()
        VStack(alignment: .leading, spacing: 1) {
            Text(data.title)
                .font(.system(size: Self.nameSize))
                .foregroundStyle(.primary)
            if let value = data.valueTile {
                reading(value.value, word: nil, isSpent: false)
                Color.clear
                    .frame(height: density.meterHeight)
                    .padding(.vertical, Self.barPadding)
                time(Text(value.detail ?? " "))
            } else {
                let parts = data.limitReading
                reading(parts.value, word: parts.word, isSpent: state == .spent)
                MeterBar(data: data, state: state, height: density.meterHeight)
                    .padding(.vertical, Self.barPadding)
                timeLine(state)
            }
        }
        .lineLimit(1)
        .frame(maxWidth: .infinity, alignment: .leading)
        // One stop for VoiceOver, reading the tile as a sentence.
        .accessibilityElement(children: .combine)
        // One hover for the whole tile, saying only what its lines do not. It rides the app's
        // tooltip panel, so it appears in place with no animation and never takes a click.
        .contentShape(Rectangle())
        .hoverDetail(title: data.title, data.tileDetail(for: state))
    }

    private func reading(_ value: String, word: String?, isSpent: Bool) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 3) {
            Text(value)
                .font(.system(size: Self.readingSize, weight: .semibold))
                .foregroundStyle(isSpent ? Theme.meterFill(.critical) : AnyShapeStyle(.primary))
                .contentTransition(.numericText())
            if let word {
                Text(word)
                    .font(.system(size: Self.timeSize))
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func time(_ text: Text) -> some View {
        text
            .font(.system(size: Self.timeSize))
            .foregroundStyle(.secondary)
    }

    /// The time under the bar: the reset, or a flame and the run-out time. The short form is for
    /// the eye; VoiceOver gets the full phrase ("Resets in 2h 15m", "Limit in 1d 2h").
    private func timeLine(_ state: WidgetData.MeterState) -> some View {
        let tileTime = data.tileTime(for: state)
        var spoken = data.boundedTrailingText()
        if tileTime?.isRunOut == true, case .runningOut(let eta?, _) = state { spoken = eta }
        return HStack(spacing: 3) {
            if tileTime?.isRunOut == true {
                Image(systemName: "flame.fill")
                    .font(.system(size: Self.timeSize - 1))
                    .foregroundStyle(Theme.meterFill(.critical))
            }
            // An empty line still holds its place: the four lines never change with state.
            time(Text(tileTime?.text ?? " "))
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(spoken ?? "")
    }
}

/// A tile's hover detail: its name, then the few facts the tile does not print, as label and value
/// pairs. Shown in the tooltip panel (see `hoverDetail`).
struct TileDetailView: View {
    let title: String
    let detail: WidgetData.TileDetail
    /// Wide enough for the longest value ("tomorrow at 12:00 PM") beside its label on one line.
    private static let width: CGFloat = 186

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .fontWeight(.semibold)
                .foregroundStyle(.primary)
            ForEach(detail.rows, id: \.label) { row in
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Text(row.label)
                        .foregroundStyle(.secondary)
                    Spacer(minLength: 0)
                    Text(row.value)
                        .foregroundStyle(.primary)
                        .monospacedDigit()
                        .fixedSize()
                }
            }
            if let note = detail.note {
                Text(note)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        // A tooltip, so it is set a step below the tiles it annotates.
        .font(.system(size: 10))
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .frame(width: Self.width, alignment: .leading)
    }
}

/// A card's grid of tiles (see `MeterTileLayout.Grid`). The caller builds each tile so the live
/// list can hang its context menu and reorder frame on it.
struct MetricTileGrid<Item, ID: Hashable, Tile: View>: View {
    let grid: MeterTileLayout.Grid<Item>
    /// Identifies a tile by what it shows, not where it sits: when a tile leaves the grid the
    /// ones after it move up a slot, and a view keyed by slot would keep its place (and its
    /// recorded reorder frame) while silently showing a different metric.
    let id: KeyPath<Item, ID>
    @ViewBuilder var tile: (Item) -> Tile

    var body: some View {
        VStack(alignment: .leading, spacing: MeterTileLayout.rowSpacing) {
            ForEach(Array(grid.rows.enumerated()), id: \.offset) { _, row in
                WeightedRow(columns: grid.columns, spacing: MeterTileLayout.columnSpacing) {
                    ForEach(row, id: (\MeterTileLayout.Tile<Item>.item).appending(path: id)) { entry in
                        tile(entry.item).layoutValue(key: WeightedRow.Weight.self, value: entry.weight)
                    }
                }
            }
        }
        .padding(.horizontal, MeterTileLayout.horizontalPadding)
        .padding(.top, MeterTileLayout.topPadding)
        .padding(.bottom, MeterTileLayout.bottomPadding)
    }
}

/// Lays its children left to right on a fixed number of equal columns, each spanning its weight.
/// A row with fewer weights than columns leaves the rest of the track empty, so a short last row
/// keeps the column width of the rows above it.
struct WeightedRow: Layout {
    struct Weight: LayoutValueKey {
        static let defaultValue = 1
    }

    let columns: Int
    let spacing: CGFloat

    private func width(of weight: Int, in total: CGFloat) -> CGFloat {
        let column = (total - spacing * CGFloat(columns - 1)) / CGFloat(columns)
        return column * CGFloat(weight) + spacing * CGFloat(weight - 1)
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let total = proposal.width ?? idealWidth(of: subviews)
        let height = subviews.map { subview in
            subview.sizeThatFits(ProposedViewSize(width: width(of: subview[Weight.self], in: total), height: nil)).height
        }.max() ?? 0
        return CGSize(width: total, height: height)
    }

    /// With no width proposed (an ideal-size query), the row is as wide as its widest column needs:
    /// every column takes the largest per-column ideal width among the tiles.
    private func idealWidth(of subviews: Subviews) -> CGFloat {
        let column = subviews.map { subview in
            let weight = CGFloat(subview[Weight.self])
            return (subview.sizeThatFits(.unspecified).width - spacing * (weight - 1)) / weight
        }.max() ?? 0
        return column * CGFloat(columns) + spacing * CGFloat(columns - 1)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX
        for subview in subviews {
            let width = width(of: subview[Weight.self], in: bounds.width)
            subview.place(at: CGPoint(x: x, y: bounds.minY), proposal: ProposedViewSize(width: width, height: nil))
            x += width + spacing
        }
    }
}

/// A card's rows outside the live list (the drag preview and the share export): the same tiles,
/// rows and divider, with no toggles, menus, or gestures.
struct StaticMetricRows: View {
    let rows: [WidgetData]
    /// Where the On Demand rows begin, when the card is open. The divider goes there, and it is a
    /// hard boundary for tiles and for text-row condensing, as on the live card.
    var expandBoundaryIndex: Int?
    /// The provider's shared column count for the Always Visible limits (see
    /// `MeterTileLayout.limitColumnsByFamily`).
    var limitColumns: Int?

    var body: some View {
        let split = expandBoundaryIndex ?? rows.count
        side(Array(rows[..<split]), limitColumns: limitColumns)
        if split < rows.count {
            Rectangle()
                .fill(.separator)
                .frame(height: 1)
                .padding(.horizontal, MeterTileLayout.horizontalPadding)
                .padding(.vertical, ExpansionHeightEstimator.separatorRowPadding)
            side(Array(rows[split...]), limitColumns: nil)
        }
    }

    private func side(_ rows: [WidgetData], limitColumns: Int?) -> some View {
        let condensed = WidgetData.condensedTextRowOffsets(in: rows)
        let segments = MeterTileLayout.segments(Array(rows.enumerated()), data: \.element, limitColumns: limitColumns)
        return ForEach(Array(segments.enumerated()), id: \.offset) { _, segment in
            switch segment {
            case .grid(let grid):
                MetricTileGrid(grid: grid, id: \.offset) { MetricTileView(data: $0.element) }
            case .row(let row):
                WidgetRowView(data: row.element, condensedTop: condensed.contains(row.offset))
            }
        }
    }
}

/// The capsule meter — the Tahoe-era level-indicator form (capsule, full-height leading-anchored
/// fill). Deliberately NOT the native linear `Gauge`/`ProgressView`, which Tahoe left as the thin
/// legacy bar. The fill is a flat **system color** carrying the pace verdict (blue = well within
/// limits, yellow = projected to land inside the last 10%, red = projected to run out;
/// `Theme.meterFill` / `MeterState.severity`); empty and colorless without data. A thin tick marks
/// the even-pace line — where usage would sit if it burned evenly across the reset window — on
/// yellow and red bars always, and on blue when "always show pacing" is on. The tick rides in an
/// overlay so it pokes out top and bottom without changing the bar's height.
struct MeterBar: View {
    let data: WidgetData
    let state: WidgetData.MeterState
    let height: CGFloat

    /// Party easter egg: fill meter bars with the party gradient instead of the severity color.
    @Environment(\.popoverPartyMode) private var partyMode

    private static let paceTickWidth: CGFloat = 2
    /// How much taller than the bar the tick is, so it pokes out slightly above and below.
    private static let paceTickOverhang: CGFloat = 4

    var body: some View {
        let tick = data.paceTick(for: state)
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                // Semantic quaternary fill (not an opacity-faded color) so the track stays vibrant
                // on glass and adapts to Increase Contrast / Reduce Transparency.
                Capsule().fill(.quaternary)
                Capsule()
                    .fill(partyMode ? PartyMode.meterFill : fill)
                    .frame(width: fillWidth(track: proxy.size.width))
            }
            .overlay(alignment: .leading) {
                if let tick {
                    RoundedRectangle(cornerRadius: 1)
                        .fill(Color.primary.opacity(0.55))
                        .frame(width: Self.paceTickWidth, height: height + Self.paceTickOverhang)
                        .offset(x: paceTickOffset(track: proxy.size.width, fraction: tick))
                }
            }
        }
        .frame(height: height)
        .animation(Motion.spring, value: data.fraction)
        .accessibilityHidden(true)
    }

    private var fill: AnyShapeStyle {
        state.severity.map(Theme.meterFill) ?? AnyShapeStyle(Color.secondary)
    }

    /// Leading offset that centers the tick on its fraction, clamped so the tick never pokes past
    /// either rounded end of the track.
    private func paceTickOffset(track: CGFloat, fraction: Double) -> CGFloat {
        let centered = track * fraction - Self.paceTickWidth / 2
        return min(max(centered, 0), max(track - Self.paceTickWidth, 0))
    }

    /// Fill width with a minimum-visible rule: any non-zero fraction renders at least a full circle
    /// (width = bar height) so 1–2% never squashes into an invisible sliver.
    private func fillWidth(track: CGFloat) -> CGFloat {
        guard data.hasData, data.fraction > 0 else { return 0 }
        return max(height, track * data.fraction)
    }
}
