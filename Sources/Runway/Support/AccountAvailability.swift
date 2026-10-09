import Foundation

/// Whether an account can be used right now, read from its card's rows — the same per-limit
/// verdict that colors the tiles, so the two can never disagree.
enum AccountAvailability {
    /// The account's shared weekly limit is spent and the card has folded to its exhausted
    /// message. The card's mark and name fade, the way the account's icon does in the menu bar.
    /// A spent independent pool (Spark, Gemini) shows its own exhausted message but leaves the
    /// account usable, exactly as `WeeklyQuotaVisibility.menuBarIsExhausted` treats it.
    static func isExhausted(_ rows: [ResolvedRow]) -> Bool {
        rows.contains { $0.data.exhaustedWeeklyTitle != nil && WeeklyQuotaVisibility.blocksAccount($0.descriptor) }
    }

    /// Nothing says the account is out: its usage loaded, its week is not spent, and no limit on
    /// the card (Always Visible or On Demand) is spent. Counted for a grouped provider's
    /// "2 of 5 ready".
    static func isUsable(_ card: ResolvedCard, now: Date = Date()) -> Bool {
        let rows = card.alwaysRows + card.expandedRows
        return card.message == nil
            && !isExhausted(rows)
            && !rows.contains { $0.data.isLimitTile && $0.data.meterState(now: now) == .spent }
    }
}
