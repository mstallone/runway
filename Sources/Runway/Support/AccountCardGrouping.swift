import Foundation

/// The dashboard's optional grouping of account cards: with **Group Accounts by Provider** on,
/// every account of one provider (five Claude logins, say) shares a single card under one provider
/// header instead of repeating the provider's name on a card each. Off by default; the toggle sits
/// in Settings → Appearance → Dashboard.
enum AccountCardGrouping {
    static let key = "groupAccountsByProvider"

    /// Splits the dashboard's cards into sections in display order. Grouping gathers a provider's
    /// accounts at the position of its first card; a provider with one card stays a section of one.
    /// With grouping off every card is its own section.
    static func sections<Item>(_ items: [Item], cardID: (Item) -> String, enabled: Bool) -> [[Item]] {
        guard enabled else { return items.map { [$0] } }
        var order: [String] = []
        var byFamily: [String: [Item]] = [:]
        for item in items {
            let family = ProviderAccountID.family(of: cardID(item))
            if byFamily[family] == nil { order.append(family) }
            byFamily[family, default: []].append(item)
        }
        return order.compactMap { byFamily[$0] }
    }

    /// An account's title inside its provider's grouped card. The provider header already names the
    /// provider, so a derived "Claude — matt@example.com" drops to the account part; a renamed card
    /// keeps the name it was given.
    static func accountTitle(displayName: String, familyName: String) -> String {
        let prefix = "\(familyName) — "
        guard displayName.hasPrefix(prefix), displayName.count > prefix.count else { return displayName }
        return String(displayName.dropFirst(prefix.count))
    }
}
