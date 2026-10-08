import Foundation

/// One provider family's contribution under a chosen metric: every account of that provider rolled
/// into one amount, with the accounts kept as ranked members for the expanded view. A provider with
/// one account is a group of one and keeps that account's own title.
struct TotalSpendGroup: Identifiable, Equatable {
    let family: String
    let title: String
    let displayAmount: Double
    let estimated: Bool
    let members: [TotalSpendProjectedSlice]

    var id: String { family }

    /// Only a group with several contributing accounts has anything to open.
    var isExpandable: Bool { members.count > 1 }

    /// Rolls metric-ranked account slices up by family. Cost and tokens sum; Cost/MTok is the
    /// family's blended rate (its dollars over its tokens), never a sum of rates.
    static func make(
        from ranked: [TotalSpendSlice],
        metric: TotalSpendMetric,
        multiAccountFamilies: Set<String>
    ) -> [TotalSpendGroup] {
        var order: [String] = []
        var byFamily: [String: [TotalSpendSlice]] = [:]
        for slice in ranked {
            if byFamily[slice.family] == nil { order.append(slice.family) }
            byFamily[slice.family, default: []].append(slice)
        }
        let groups = order.compactMap { family -> TotalSpendGroup? in
            guard let members = byFamily[family], let first = members.first else { return nil }
            let dollars = members.reduce(0) { $0 + $1.amountUSD }
            let tokens = members.reduce(0) { $0 + $1.tokenCount }
            let amount: Double
            switch metric {
            case .cost: amount = dollars
            case .tokens: amount = tokens
            case .costPerMtok: amount = tokens > 0 ? (dollars / tokens) * 1_000_000 : 0
            }
            let title = multiAccountFamilies.contains(family)
                ? ProviderAccountID.familyDisplayName(family) ?? first.title
                : first.title
            return TotalSpendGroup(
                family: family,
                title: title,
                displayAmount: amount,
                estimated: members.contains(where: \.estimated),
                members: members.map { member in
                    let memberAmount: Double
                    switch metric {
                    case .cost: memberAmount = member.amountUSD
                    case .tokens: memberAmount = member.tokenCount
                    case .costPerMtok: memberAmount = member.costPerMtok ?? 0
                    }
                    return TotalSpendProjectedSlice(
                        provider: member.provider,
                        title: member.title,
                        displayAmount: memberAmount,
                        estimated: member.estimated
                    )
                }
            )
        }
        return groups.sorted { lhs, rhs in
            if lhs.displayAmount != rhs.displayAmount { return lhs.displayAmount > rhs.displayAmount }
            return lhs.title.localizedStandardCompare(rhs.title) == .orderedAscending
        }
    }
}

/// One provider family's width in the share bar or ring, as a fraction of the whole.
struct TotalSpendSegment: Identifiable, Equatable {
    let family: String
    let fraction: Double

    var id: String { family }
}

extension TotalSpendProjection {
    /// Every segment is guaranteed at least this share, so a tiny provider next to a dominant one
    /// still shows a visible sliver instead of vanishing. Presentation-only — the legend and period
    /// totals keep the true amounts.
    static let minimumSegmentShare = 0.025

    /// The ranked groups as fractions of the share bar or ring, with the minimum-sliver floor
    /// applied and the result renormalized so the segments always fill it exactly.
    var segments: [TotalSpendSegment] {
        let totalDisplay = groups.reduce(0) { $0 + $1.displayAmount }
        guard totalDisplay > 0 else { return [] }
        let floored = groups.map { max($0.displayAmount / totalDisplay, Self.minimumSegmentShare) }
        let sum = floored.reduce(0, +)
        return zip(groups, floored).map { group, share in
            TotalSpendSegment(family: group.family, fraction: share / sum)
        }
    }

    /// An amount's true share of the period total ("60%", "<1%"). `nil` under Cost/MTok: rates are
    /// compared, not summed, so a share of them means nothing.
    func shareLabel(forAmount amount: Double) -> String? {
        guard metric != .costPerMtok, centerValue > 0 else { return nil }
        let percent = (amount / centerValue * 100).rounded()
        return percent < 1 ? "<1%" : "\(Int(percent))%"
    }
}

/// The Table layout's grid: provider families down, the three periods across, the combined total on
/// top. A family with several accounts carries them as member rows for the expanded view.
struct TotalSpendTable: Equatable {
    struct Row: Identifiable, Equatable {
        let id: String
        let title: String
        /// One amount per period, in `TotalSpendPeriod.allCases` order. `nil` when the row has
        /// nothing for that period — shown as a dash, never a fabricated zero.
        let amounts: [Double?]
        var members: [Row] = []

        var isExpandable: Bool { members.count > 1 }
    }

    let metric: TotalSpendMetric
    let totals: [Double?]
    let rows: [Row]

    var isEmpty: Bool { rows.isEmpty }

    /// Builds the grid from one projection per period. Rows rank by the longest period first (the
    /// last projection), falling back to the earlier ones, so the order holds still day to day.
    static func make(projections: [TotalSpendProjection], metric: TotalSpendMetric) -> TotalSpendTable {
        var titles: [String: String] = [:]
        var amounts: [String: [Double?]] = [:]
        var memberTitles: [String: [String: String]] = [:]
        var memberAmounts: [String: [String: [Double?]]] = [:]
        let empty = [Double?](repeating: nil, count: projections.count)

        for (index, projection) in projections.enumerated() {
            for group in projection.groups {
                titles[group.family] = group.title
                amounts[group.family, default: empty][index] = group.displayAmount
                for member in group.members {
                    memberTitles[group.family, default: [:]][member.id] = member.title
                    memberAmounts[group.family, default: [:]][member.id, default: empty][index] = member.displayAmount
                }
            }
        }

        let rows = amounts.map { family, values in
            let members = (memberAmounts[family] ?? [:]).map { id, memberValues in
                Row(id: id, title: memberTitles[family]?[id] ?? id, amounts: memberValues)
            }
            return Row(id: family, title: titles[family] ?? family, amounts: values, members: members.sorted(by: precedes))
        }
        return TotalSpendTable(
            metric: metric,
            totals: projections.map { $0.isEmpty ? nil : $0.centerValue },
            rows: rows.sorted(by: precedes)
        )
    }

    private static func precedes(_ lhs: Row, _ rhs: Row) -> Bool {
        for (left, right) in zip(lhs.amounts.reversed(), rhs.amounts.reversed()) where left != right {
            return (left ?? 0) > (right ?? 0)
        }
        return lhs.title.localizedStandardCompare(rhs.title) == .orderedAscending
    }
}
