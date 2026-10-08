import AppKit
import SwiftUI

/// The dashboard's cross-provider Total Spend section: a header naming it, over a card in one of
/// three styles chosen in Settings (`TotalSpendLayout`). **Table** shows providers down and the
/// three periods across. **Bar** and **Pie** lead with three period tiles (Today / Yesterday /
/// 30 Days) that each carry that period's combined total and double as the period switch, over a
/// share bar or ring with a ranked legend for the selected one. The tiles sit bare on the popover;
/// the selected tile and its breakdown share one surface (`JoinedTabShape`), so the section never
/// reads as one more provider card. Clicking the selected tile again collapses the card to the
/// tiles alone, with no surface at all. Every style groups accounts under their provider, and a
/// provider with several accounts opens to list them. The metric (Cost / Cost/MTok / Tokens)
/// changes rarely, so it is a quiet pull-down at the header's trailing end. Data comes from
/// `TotalSpendAggregator` over the same snapshots the provider cards render. Shown whenever any
/// enabled provider tracks spend (`LayoutStore.hasSpendCapableProvider`) and the toggle at the top
/// of Settings is on; a period (or metric) with nothing to show uses a quiet empty state instead of
/// hiding the card.
struct TotalSpendCard: View {
    @Environment(LayoutStore.self) private var layout
    @Environment(WidgetDataStore.self) private var dataStore
    @Environment(AppContainer.self) private var container
    @Environment(\.colorScheme) private var colorScheme

    /// The selected period, metric (Cost / Cost/MTok / Tokens), and collapsed flag survive popover
    /// closes and relaunches, like the meter-style toggles. They are `@State` seeded from and
    /// written back to `UserDefaults` rather than `@AppStorage`: an `@AppStorage` write reaches the
    /// view through a defaults observer outside the caller's `withAnimation`, so the card would
    /// snap to its new height while the panel around it animated.
    @State private var period = UserDefaults.standard.enumValue(
        forKey: Self.periodKey, default: TotalSpendPeriod.today
    )
    @State private var metric = UserDefaults.standard.enumValue(
        forKey: Self.metricKey, default: TotalSpendMetric.tokens
    )
    /// Whether the tiled styles are folded down to the period tiles alone.
    @State private var isCollapsed = UserDefaults.standard.bool(forKey: Self.collapsedKey)

    private static let headerToContentSpacing: CGFloat = 11
    /// Added to the dashboard's regular section spacing below the card.
    private static let extraBottomSpacing: CGFloat = 7

    private static let periodKey = "runway.totalSpend.period"
    private static let metricKey = "runway.totalSpend.metric"
    private static let collapsedKey = "runway.totalSpend.collapsed"
    /// Table, Bar, or Pie — chosen in Settings → General.
    @AppStorage(TotalSpendLayout.key) private var layoutStyle = TotalSpendLayout.fallback
    /// Providers whose accounts are listed. Session state: closing the popover collapses them.
    @State private var expandedFamilies: Set<String> = []
    @Environment(\.popoverIsVisible) private var popoverIsVisible
    @Environment(\.popoverSurfaceTreatment) private var surfaceTreatment
    /// One legend line's measured height (see `rowHeightProbe`); the seed is the usual 11pt line.
    @State private var rowHeight: CGFloat = 14
    /// The period tiles' measured height: where the joined tab meets its panel.
    @State private var tilesHeight: CGFloat = 46
    private let density = DensitySetting.compact

    /// The spend-tile providers the card may aggregate — capability-based (see
    /// `LayoutStore.spendCapableProviders`), so a provider stays counted even when its own rows are
    /// hidden in Customize, and providers with merely similar-looking dollar rows never leak in.
    private var providers: [Provider] {
        layout.spendCapableProviders
    }

    /// Everything the three period aggregations share, built once per use: the providers to sum,
    /// their snapshots, and each provider's resolved card title.
    private struct AggregationInputs {
        var providers: [Provider]
        var snapshots: [String: ProviderSnapshot]
        var titles: [String: String]
    }

    private var aggregationInputs: AggregationInputs {
        // Accounts that live only on other Macs (synced, no card here) count toward the total and
        // join their provider's line as one more account ("claude@ab12cd34") — the number should
        // be the whole truth even when a login isn't set up on this machine.
        var aggregatedProviders = providers
        var aggregatedSnapshots = dataStore.snapshots
        for entry in dataStore.remoteOnlySpend {
            aggregatedProviders.append(entry.provider)
            aggregatedSnapshots[entry.provider.id] = entry.snapshot
        }
        // Titles resolve here — the one place with registry access — so the legend AND the share
        // export (rendered outside the environment) carry live renames.
        let titles = Dictionary(
            aggregatedProviders.map { ($0.id, container.displayName(for: $0)) },
            uniquingKeysWith: { first, _ in first }
        )
        return AggregationInputs(providers: aggregatedProviders, snapshots: aggregatedSnapshots, titles: titles)
    }

    private func total(for period: TotalSpendPeriod, inputs: AggregationInputs) -> TotalSpend {
        TotalSpendAggregator.total(
            for: period,
            providers: inputs.providers,
            snapshots: inputs.snapshots,
            title: { inputs.titles[$0.id] ?? $0.displayName }
        )
    }

    private func projections(inputs: AggregationInputs) -> [TotalSpendProjection] {
        TotalSpendPeriod.allCases.map { total(for: $0, inputs: inputs).projection(for: metric) }
    }

    var body: some View {
        // Computed once per body evaluation: building the inputs copies the snapshots dictionary
        // and resolves every title, so doing it per period or per subview multiplies that work.
        let projections = projections(inputs: aggregationInputs)
        // The outlined surface needs more air than a filled provider card: without it the line
        // crowds the header above and the next provider's header below.
        VStack(alignment: .leading, spacing: Self.headerToContentSpacing) {
            header(projections: projections)
            content(projections: projections)
        }
        .padding(.bottom, Self.extraBottomSpacing)
    }

    // MARK: - Header

    /// Section header matching the provider headers' scale: the section name leading, the metric
    /// menu trailing where a provider header shows its plan.
    private func header(projections: [TotalSpendProjection]) -> some View {
        HStack(spacing: 5) {
            Text("Total Spend")
                .font(.system(size: density.headerPointSize, weight: .semibold))
                .foregroundStyle(.primary)
                .lineLimit(1)
            Image(systemName: "info.circle")
                .imageScale(.small)
                .foregroundStyle(.secondary)
                .hoverTooltip(infoTooltip(projections: projections))
            Spacer(minLength: 8)
            metricMenu
        }
        .padding(.leading, 4)
        .padding(.trailing, 4)
        .padding(.vertical, 2)
    }

    /// The metric switch, in the supporting style of a provider header's plan name. A real
    /// `NSMenu` via `NativeMenuButton`, not a SwiftUI `Menu`: the SwiftUI popup could open at a
    /// stale width and middle-truncate "Cost/MTok".
    private var metricMenu: some View {
        NativeMenuButton(
            accessibilityLabel: "Total Spend Metric",
            accessibilityValue: metric.title
        ) {
            let metricItems: [NSMenuItem] = TotalSpendMetric.allCases.map { option in
                let item = ClosureMenuItem(title: option.title) {
                    // The row count can change with the metric; the panel follows the measured
                    // change on the same spring.
                    withAnimation(Motion.spring) { metric = option }
                    UserDefaults.standard.set(option.rawValue, forKey: Self.metricKey)
                }
                item.state = option == metric ? .on : .off
                return item
            }
            return metricItems + [.separator(), viewMenuItem]
        } label: {
            HStack(spacing: 3) {
                Text(metric.title)
                    .font(.system(size: density.supportingPointSize, weight: .medium))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Image(systemName: "chevron.down")
                    .font(.system(size: 8, weight: .semibold))
                    .foregroundStyle(.tertiary)
            }
        }
    }

    /// The **View** submenu under the metrics: the same Pie / Bar / Table choice as Settings'
    /// **Total Spend Style**, reachable from the card itself. Both write the one stored setting.
    private var viewMenuItem: NSMenuItem {
        let submenu = NSMenu()
        for option in TotalSpendLayout.allCases {
            let item = ClosureMenuItem(title: option.label) {
                layoutStyle = option
            }
            item.state = option == layoutStyle ? .on : .off
            submenu.addItem(item)
        }
        let item = NSMenuItem(title: "View", action: nil, keyEquivalent: "")
        item.submenu = submenu
        return item
    }

    /// Names the providers actually feeding the total — the enabled spend-capable set — instead of a
    /// hardcoded list, so disabling a provider (or a new spend provider shipping) can't make the
    /// tooltip lie about what the total reflects.
    private func infoTooltip(projections: [TotalSpendProjection]) -> String {
        let names = providers.map { container.displayName(for: $0) }
        return TotalSpendInfo.tooltip(
            providerNames: names,
            metric: metric,
            isEstimated: projections.contains(where: \.isEstimated)
        )
    }

    /// Copies the whole grid in Table layout, otherwise the selected period's breakdown in the
    /// current style — also when the card is folded down to its tiles.
    private func shareScreenshot() {
        let inputs = aggregationInputs
        ShareCardRenderer.shareTotalSpend(
            total: total(for: period, inputs: inputs),
            metric: metric,
            style: layoutStyle == .pie ? .ring : .bar,
            table: layoutStyle == .table
                ? TotalSpendTable.make(projections: projections(inputs: inputs), metric: metric)
                : nil,
            appearance: colorScheme,
            layout: layout
        )
    }

    // MARK: - Content

    @ViewBuilder
    private func content(projections: [TotalSpendProjection]) -> some View {
        Group {
            switch layoutStyle {
            case .table:
                let table = TotalSpendTable.make(projections: projections, metric: metric)
                Group {
                    if table.isEmpty {
                        emptyState
                    } else {
                        TotalSpendTableView(table: table, expanded: expandedBinding(projections))
                    }
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 9)
                .frame(maxWidth: .infinity)
                .background {
                    Theme.cardShape.fill(legibilityBacking)
                    Theme.cardShape.strokeBorder(.separator, lineWidth: 1)
                }
            case .bar, .pie:
                tiledContent(projections: projections)
            }
        }
        .background { rowHeightProbe }
        .contentShape(Rectangle())
        .contextMenu {
            Button("Share Screenshot") {
                shareScreenshot()
            }
        }
        // Closing the popover collapses every open provider card; opened providers here follow.
        .onChange(of: popoverIsVisible) { _, isVisible in
            if !isVisible { expandedFamilies = [] }
        }
    }

    @ViewBuilder
    private func tiledContent(projections: [TotalSpendProjection]) -> some View {
        let selected = projections[TotalSpendPeriod.allCases.firstIndex(of: period) ?? 0]
        VStack(spacing: 0) {
            TotalSpendPeriodTiles(projections: projections, selection: isCollapsed ? nil : period) { candidate in
                // Clicking the selected tile again folds the card down to the headline; any tile
                // opens it back up on that period.
                let collapses = !isCollapsed && candidate == period
                animate(projections, period: candidate, collapsed: collapses) {
                    if !collapses { period = candidate }
                    isCollapsed = collapses
                }
                UserDefaults.standard.set(period.rawValue, forKey: Self.periodKey)
                UserDefaults.standard.set(isCollapsed, forKey: Self.collapsedKey)
            }
            .onGeometryChange(for: CGFloat.self) { proxy in
                proxy.size.height
            } action: { height in
                tilesHeight = height
            }
            Group {
                if selected.isEmpty {
                    emptyState
                } else {
                    TotalSpendBreakdown(
                        projection: selected,
                        style: layoutStyle == .pie ? .ring : .bar,
                        expanded: expandedBinding(projections)
                    )
                }
            }
            .padding(.horizontal, 10)
            .padding(.top, TotalSpendCardHeight.tilesToBreakdownSpacing)
            .padding(.bottom, TotalSpendCardHeight.breakdownBottomPadding)
            .accordionReveal(!isCollapsed)
        }
        .frame(maxWidth: .infinity)
        // One surface for the selected tile and its breakdown. It fades with the breakdown: folded
        // down to the headline, the three totals sit bare on the popover.
        .background {
            // The joined shape as an outline with no fill, so the section can't be mistaken for a
            // provider card. Inset half a point so the 1pt line sits inside the card's bounds and
            // lines up with the provider cards' edges.
            let surface = JoinedTabShape(
                tabPosition: Double(TotalSpendPeriod.allCases.firstIndex(of: period) ?? 0),
                tabCount: TotalSpendPeriod.allCases.count,
                tabSpacing: TotalSpendPeriodTiles.spacing,
                tabHeight: tilesHeight - 0.5
            )
            ZStack {
                surface.fill(legibilityBacking)
                surface.stroke(.separator, lineWidth: 1)
            }
            .padding(0.5)
            .opacity(isCollapsed ? 0 : 1)
        }
    }

    /// Clear on the opaque popover, where the outline alone is the surface. Under the translucent
    /// treatment the tray is see-through, so the section takes the same frosted material the
    /// provider cards carry to keep its text legible over whatever shows behind the window.
    private var legibilityBacking: AnyShapeStyle {
        switch surfaceTreatment {
        case .opaque: AnyShapeStyle(.clear)
        case .translucent: AnyShapeStyle(.regularMaterial)
        }
    }

    // MARK: - Height Changes

    /// Every change to the card's height goes through here, the way a provider card's caret works:
    /// one `withAnimation` so the card, the provider cards below it, and the panel edge all move on
    /// the same spring, with the panel retargeted in that transaction by the height the change adds
    /// or removes. Animating only the card's interior instead lets everything below jump to its new
    /// place while the rows are still fading, so they overlap.
    private func animate(
        _ projections: [TotalSpendProjection],
        period newPeriod: TotalSpendPeriod? = nil,
        collapsed newCollapsed: Bool? = nil,
        expanded newExpanded: Set<String>? = nil,
        _ change: () -> Void
    ) {
        func height(period: TotalSpendPeriod, collapsed: Bool, expanded: Set<String>) -> CGFloat {
            TotalSpendCardHeight.variable(
                layout: layoutStyle,
                projections: projections,
                period: period,
                collapsed: collapsed,
                expanded: expanded,
                rowHeight: rowHeight
            )
        }
        let before = height(period: period, collapsed: isCollapsed, expanded: expandedFamilies)
        let after = height(
            period: newPeriod ?? period,
            collapsed: newCollapsed ?? isCollapsed,
            expanded: newExpanded ?? expandedFamilies
        )
        withAnimation(Motion.spring) {
            if abs(after - before) > 0.5 {
                MenuBarPopover.coAnimateHeightDelta?(after - before)
            }
            change()
        }
    }

    /// The breakdown and table toggle providers through this, so opening one animates like every
    /// other height change.
    private func expandedBinding(_ projections: [TotalSpendProjection]) -> Binding<Set<String>> {
        Binding(
            get: { expandedFamilies },
            set: { newValue in
                animate(projections, expanded: newValue) { expandedFamilies = newValue }
            }
        )
    }

    /// Measures one legend line at the supporting size, so the height math tracks the real font
    /// metrics instead of a guessed constant.
    private var rowHeightProbe: some View {
        Text("0")
            .font(.system(size: density.supportingPointSize))
            .hidden()
            .onGeometryChange(for: CGFloat.self) { proxy in
                proxy.size.height
            } action: { height in
                if height > 0 { rowHeight = height }
            }
            .accessibilityHidden(true)
    }

    /// A metric/period combination with nothing to show mirrors the spend tiles' "No data" rule —
    /// never a fabricated zero breakdown.
    private var emptyState: some View {
        Text(metric.emptyMessage)
            .font(.system(size: density.supportingPointSize))
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity)
            .padding(.vertical, TotalSpendCardHeight.emptyStatePadding)
    }
}

/// Stable per-provider brand tints for the Total Spend share bar and legend — the one place the app maps
/// a provider to a color, so the chart, legend, and share card always agree. Colors are keyed by
/// provider ID only (never by rank or position), so a provider keeps its color across period
/// switches, re-sorts, and launches. Hexes come from the legacy edition's per-plugin `brandColor`
/// values; brands whose color is plain black (Cursor, Grok) get adaptive near-black/near-white
/// dynamic colors so they read on both appearances without both landing on the same gray.
enum TotalSpendPalette {
    private static let byProviderID: [String: Color] = [
        "claude": hex(0xDE7356),                             // Claude terracotta
        "codex": hex(0x10A37F),                              // OpenAI green (#10A37F)
        "cursor": dynamic(light: 0x13120A, dark: 0xF5F5F7),  // brand black (#13120A), flipped near-white in dark mode
        "grok": dynamic(light: 0x8E8E93, dark: 0x98989D),    // brand black, offset to gray next to Cursor
        "opencode": dynamic(light: 0x6E6E73, dark: 0xAEAEB2),  // OpenCode — grayscale brand, medium gray
        "openrouter": hex(0x6467F2),                         // OpenRouter indigo
        "antigravity": hex(0x4285F4),                        // Google blue
        "copilot": hex(0xA855F7),                            // Copilot purple
        "amp": hex(0xF34E3F),
        "factory": dynamic(light: 0x48484A, dark: 0xC7C7CC),
        "kimi": hex(0x0A66FF),
        "minimax": hex(0xF5433C),
        "zai": dynamic(light: 0x2D2D2D, dark: 0xD1D1D6)
    ]

    /// Deterministic backstop hues for a provider that ships without a palette entry — keyed off the
    /// provider ID (not rank), so the color holds steady across periods and launches.
    private static let fallback: [Color] = [
        hex(0x34C759), hex(0x5856D6), hex(0xFF2D55), hex(0xA2845E)
    ]

    static func color(for providerID: String) -> Color {
        if let brand = byProviderID[providerID] { return brand }
        let stableHash = providerID.unicodeScalars.reduce(0) { ($0 &* 31 &+ Int($1.value)) & 0xFFFF }
        return fallback[stableHash % fallback.count]
    }

    private static func hex(_ value: UInt32) -> Color {
        Color(
            red: Double((value >> 16) & 0xFF) / 255,
            green: Double((value >> 8) & 0xFF) / 255,
            blue: Double(value & 0xFF) / 255
        )
    }

    /// A light/dark-adaptive color, for brands whose mark is pure black — invisible on a dark card
    /// unless flipped.
    private static func dynamic(light: UInt32, dark: UInt32) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let value = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light
            return NSColor(
                red: CGFloat((value >> 16) & 0xFF) / 255,
                green: CGFloat((value >> 8) & 0xFF) / 255,
                blue: CGFloat(value & 0xFF) / 255,
                alpha: 1
            )
        })
    }
}
