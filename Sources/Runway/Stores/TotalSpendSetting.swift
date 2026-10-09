import Foundation

/// Whether the cross-provider Total Spend card shows at the top of the dashboard. On by default;
/// the toggle sits in Settings → Appearance → Dashboard. Hiding it only affects the card — the
/// per-provider spend rows it aggregates stay wherever the user put them.
enum TotalSpendSetting {
    static let key = "showTotalSpend"
}

/// How the Total Spend card draws its breakdown. Every style groups accounts under their provider;
/// the choice sits under **Show Total Spend** in Settings → Appearance → Dashboard and in the **View** submenu of
/// the card's own header menu.
enum TotalSpendLayout: String, Hashable, Sendable, CaseIterable, UserDefaultsBacked {
    /// Declaration order is the menu order: Pie → Bar → Table.
    /// Period tiles over a ring and legend.
    case pie
    /// Period tiles over a share bar and legend.
    case bar
    /// Providers down, periods across: every number at once, no chart.
    case table

    static let key = "totalSpendLayout"
    static var fallback: TotalSpendLayout { .pie }

    var label: String {
        switch self {
        case .table: "Table"
        case .bar: "Bar"
        case .pie: "Pie"
        }
    }
}
