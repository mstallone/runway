import Foundation

// The resolved row models `WidgetGroupedListView` builds each render and draws from.

/// A row's placed widget paired with its resolved descriptor + data, so each `dataStore.data(for:)`
/// is computed once per render and reused by both the condensing rule and the row. Keyed off the
/// `PlacedWidget` so `ForEach` identity stays exactly what it was before this was precomputed.
struct ResolvedRow: Identifiable {
    let widget: PlacedWidget
    let descriptor: WidgetDescriptor
    let data: WidgetData
    var id: PlacedWidget.ID { widget.id }
}

enum DashboardMetricCardRow: Identifiable {
    case metric(ResolvedRow)
    /// A grid of tiles: the card's limits, with any short value that sits among them.
    case tiles(MeterTileLayout.Grid<ResolvedRow>)
    case divider
    /// The provider's quick-link buttons (Status / Console / Dashboard ...), pinned at the
    /// bottom of the collapsible expanded section. They collapse with the caret — part of the
    /// expander, not always-visible chrome.
    case links([ProviderLink])

    var id: String {
        switch self {
        case .metric(let row):
            "metric:\(row.descriptor.id)"
        case .tiles(let grid):
            "tiles:\(grid.tiles.first?.item.descriptor.id ?? "")"
        case .divider:
            "expanded-divider"
        case .links:
            "provider-links"
        }
    }
}

/// One card's rows, resolved once per render: each row's descriptor + data is reused for the
/// neighbor-aware condensing rule, the header's fade, and the row itself —
/// `dataStore.data(for:)` used to be recomputed several times per row.
struct ResolvedCard: Identifiable {
    let group: ProviderGroup
    let message: String?
    let isExpanded: Bool
    /// Whether the card has anything behind its caret (On Demand metrics or quick links).
    let hasExpandedContent: Bool
    /// The Always Visible rows, which the account's availability and the provider's shared tile
    /// columns are read from.
    let alwaysRows: [ResolvedRow]
    /// On Demand rows, behind the caret.
    let expandedRows: [ResolvedRow]
    /// The column count the provider's accounts share for their limits (see
    /// `MeterTileLayout.limitColumnsByFamily`); set once all of the dashboard's cards are resolved.
    var limitColumns: Int?
    let condensedIDs: Set<String>

    var id: String { group.provider.id }

    /// How many limits the card's grid holds — what the provider's shared column count is taken from.
    var limitGridSize: Int {
        MeterTileLayout.limitGridSize(MeterTileLayout.segments(alwaysRows, data: \.data))
    }

    /// What the card draws, top to bottom. One stable list, so a row dragged across the caret
    /// boundary stays alive. The provider's quick links sit at the bottom of the expanded
    /// section and collapse with it; the divider exists only while the card is open.
    var rows: [DashboardMetricCardRow] {
        let links = group.provider.visibleLinks
        return cardRows(alwaysRows, limitColumns: limitColumns)
            + (hasExpandedContent && isExpanded ? [.divider] : [])
            // The shared column count is taken from the Always Visible limits, so it only applies
            // to them; On Demand limits lay out on their own count.
            + (isExpanded ? cardRows(expandedRows, limitColumns: nil) : [])
            + (isExpanded && !links.isEmpty ? [.links(links)] : [])
    }

    /// Called per side of the caret, so tiles above and below it never share a grid.
    private func cardRows(_ rows: [ResolvedRow], limitColumns: Int?) -> [DashboardMetricCardRow] {
        MeterTileLayout.segments(rows, data: \.data, limitColumns: limitColumns).map { segment in
            switch segment {
            case .grid(let grid): .tiles(grid)
            case .row(let row): .metric(row)
            }
        }
    }
}

/// One section of the dashboard: a card, or with **Group Accounts by Provider** on, every card of
/// one provider.
struct DashboardSection: Identifiable {
    let id: String
    let cards: [ResolvedCard]

    /// What a card dragged from another section drops onto: a lone card by its own id, a grouped
    /// provider as a whole.
    var dropTargetID: String { cards.count == 1 ? cards[0].id : id }

    static func familyID(of cardID: String) -> String {
        "family:\(ProviderAccountID.family(of: cardID))"
    }
}
