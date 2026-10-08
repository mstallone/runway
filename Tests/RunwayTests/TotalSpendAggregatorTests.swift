import XCTest
@testable import Runway

/// Covers the Total Spend card's aggregation and metric projection: which providers contribute,
/// how slices rank per metric, Cost/MTok math, and when the combined number counts as estimated.
final class TotalSpendAggregatorTests: XCTestCase {
    private let claude = Provider(id: "claude", displayName: "Claude", icon: .providerMark("claude"))
    private let codex = Provider(id: "codex", displayName: "Codex", icon: .providerMark("codex"))
    private let cursor = Provider(id: "cursor", displayName: "Cursor", icon: .providerMark("cursor"))

    private func snapshot(_ provider: Provider, lines: [MetricLine]) -> ProviderSnapshot {
        ProviderSnapshot(
            providerID: provider.id,
            displayName: provider.displayName,
            lines: lines,
            refreshedAt: Date(timeIntervalSince1970: 1_800_000_000)
        )
    }

    private func spendLine(
        _ label: String,
        dollars: Double? = nil,
        tokens: Double? = 1_000_000,
        estimated: Bool = false
    ) -> MetricLine {
        var values: [MetricValue] = []
        if let dollars {
            values.append(MetricValue(number: dollars, kind: .dollars, estimated: estimated))
        }
        if let tokens {
            values.append(MetricValue(number: tokens, kind: .count, label: "tokens"))
        }
        return .values(label: label, values: values)
    }

    func testSumsDollarsAndTokensAcrossProviders() {
        let snapshots = [
            "claude": snapshot(claude, lines: [spendLine("Today", dollars: 2.50, tokens: 100_000, estimated: true)]),
            "cursor": snapshot(cursor, lines: [spendLine("Today", dollars: 7.25, tokens: 500_000)])
        ]

        let total = TotalSpendAggregator.total(for: .today, providers: [claude, codex, cursor], snapshots: snapshots)

        XCTAssertEqual(Set(total.slices.map(\.provider.id)), Set(["cursor", "claude"]))
        XCTAssertEqual(total.projection(for: .tokens).centerValue, 600_000, accuracy: 0.0001)

        let spend = total.projection(for: .cost)
        XCTAssertEqual(spend.slices.map(\.provider.id), ["cursor", "claude"])
        XCTAssertEqual(spend.centerValue, 9.75, accuracy: 0.0001)
    }

    func testSlicesCarryTheCallerResolvedTitleThroughProjection() {
        // The caller (the live card, with registry access) resolves each slice's title once; the
        // legend and the share export both read that resolved string, so a mid-session rename can
        // never show on one and not the other.
        let snapshots = [
            "claude": snapshot(claude, lines: [spendLine("Today", dollars: 2.50)]),
            "cursor": snapshot(cursor, lines: [spendLine("Today", dollars: 7.25)])
        ]

        let total = TotalSpendAggregator.total(
            for: .today,
            providers: [claude, cursor],
            snapshots: snapshots,
            title: { $0.id == "claude" ? "Claude Team" : $0.displayName }
        )

        XCTAssertEqual(total.projection(for: .cost).slices.map(\.title), ["Cursor", "Claude Team"])
    }

    func testProviderWithoutPeriodLineIsExcludedNotZero() {
        let snapshots = [
            "claude": snapshot(claude, lines: [spendLine("Today", dollars: 1.00)]),
            // Codex has spend for yesterday only — it must not appear in today's slices.
            "codex": snapshot(codex, lines: [spendLine("Yesterday", dollars: 3.00)])
        ]

        let total = TotalSpendAggregator.total(for: .today, providers: [claude, codex], snapshots: snapshots)

        XCTAssertEqual(total.slices.map(\.provider.id), ["claude"])
    }

    func testTokensOnlyLineContributesTokensButNotSpendOrCostPerMtok() {
        let tokensOnly = spendLine("Today", dollars: nil, tokens: 500_000)
        let snapshots = ["claude": snapshot(claude, lines: [tokensOnly])]

        let total = TotalSpendAggregator.total(for: .today, providers: [claude], snapshots: snapshots)

        XCTAssertEqual(total.slices.count, 1)
        XCTAssertEqual(total.slices.first?.tokenCount, 500_000)
        XCTAssertEqual(total.slices.first?.amountUSD, 0)

        XCTAssertTrue(total.projection(for: .cost).isEmpty)
        XCTAssertTrue(total.projection(for: .costPerMtok).isEmpty)

        let tokens = total.projection(for: .tokens)
        XCTAssertEqual(tokens.slices.map(\.provider.id), ["claude"])
        XCTAssertEqual(tokens.centerValue, 500_000, accuracy: 0.0001)
    }

    func testDollarsOnlyLineContributesSpendButNotCostPerMtok() {
        let dollarsOnly = spendLine("Today", dollars: 4.00, tokens: nil)
        let snapshots = ["claude": snapshot(claude, lines: [dollarsOnly])]

        let total = TotalSpendAggregator.total(for: .today, providers: [claude], snapshots: snapshots)

        XCTAssertEqual(total.projection(for: .cost).centerValue, 4.00, accuracy: 0.0001)
        XCTAssertTrue(total.projection(for: .tokens).isEmpty)
        XCTAssertTrue(total.projection(for: .costPerMtok).isEmpty)
    }

    func testTotalIsEstimatedWhenAnySliceIsEstimated() {
        let snapshots = [
            "claude": snapshot(claude, lines: [spendLine("Today", dollars: 2.00, estimated: true)]),
            "cursor": snapshot(cursor, lines: [spendLine("Today", dollars: 4.00)])
        ]

        let total = TotalSpendAggregator.total(for: .today, providers: [claude, cursor], snapshots: snapshots)

        XCTAssertTrue(total.projection(for: .cost).isEstimated)
        XCTAssertTrue(total.projection(for: .costPerMtok).isEstimated)
        XCTAssertFalse(total.projection(for: .tokens).isEstimated)
    }

    func testCostPerMtokRanksByRateAndBlendsTotals() {
        // Claude: $10 / 1M tokens = $10/MTok
        // Cursor: $30 / 1M tokens = $30/MTok — ranks first by rate
        let snapshots = [
            "claude": snapshot(claude, lines: [spendLine("Today", dollars: 10, tokens: 1_000_000)]),
            "cursor": snapshot(cursor, lines: [spendLine("Today", dollars: 30, tokens: 1_000_000)])
        ]

        let total = TotalSpendAggregator.total(for: .today, providers: [claude, cursor], snapshots: snapshots)
        let rates = total.projection(for: .costPerMtok)

        XCTAssertEqual(rates.slices.map(\.provider.id), ["cursor", "claude"])
        XCTAssertEqual(rates.slices[0].displayAmount, 30, accuracy: 0.0001)
        XCTAssertEqual(rates.slices[1].displayAmount, 10, accuracy: 0.0001)
        // Blended center: ($40 / 2M) * 1e6 = $20/MTok
        XCTAssertEqual(rates.centerValue, 20, accuracy: 0.0001)
    }

    func testCostPerMtokExcludesIncompleteProvidersFromBlend() {
        let snapshots = [
            "claude": snapshot(claude, lines: [spendLine("Today", dollars: 10, tokens: 1_000_000)]),
            "codex": snapshot(codex, lines: [spendLine("Today", dollars: nil, tokens: 9_000_000)]),
            "cursor": snapshot(cursor, lines: [spendLine("Today", dollars: 5, tokens: nil)])
        ]

        let total = TotalSpendAggregator.total(for: .today, providers: [claude, codex, cursor], snapshots: snapshots)
        let rates = total.projection(for: .costPerMtok)

        XCTAssertEqual(rates.slices.map(\.provider.id), ["claude"])
        XCTAssertEqual(rates.centerValue, 10, accuracy: 0.0001)
    }

    func testTokensProjectionRanksByTokenCount() {
        let snapshots = [
            "claude": snapshot(claude, lines: [spendLine("Today", dollars: 50, tokens: 100_000)]),
            "cursor": snapshot(cursor, lines: [spendLine("Today", dollars: 1, tokens: 900_000)])
        ]

        let total = TotalSpendAggregator.total(for: .today, providers: [claude, cursor], snapshots: snapshots)
        let tokens = total.projection(for: .tokens)

        XCTAssertEqual(tokens.slices.map(\.provider.id), ["cursor", "claude"])
        XCTAssertEqual(tokens.centerValue, 1_000_000, accuracy: 0.0001)
    }

    func testEmptyProjectionWhenNothingQualifies() {
        let total = TotalSpendAggregator.total(for: .today, providers: [claude], snapshots: [:])
        XCTAssertTrue(total.slices.isEmpty)
        XCTAssertTrue(total.projection(for: .cost).isEmpty)
        XCTAssertTrue(total.projection(for: .tokens).isEmpty)
        XCTAssertTrue(total.projection(for: .costPerMtok).isEmpty)
    }

    func testSegmentsFillTheChartAndKeepATinyProviderVisible() {
        let snapshots = [
            "claude": snapshot(claude, lines: [spendLine("Today", dollars: 999)]),
            "cursor": snapshot(cursor, lines: [spendLine("Today", dollars: 1)])
        ]

        let cost = TotalSpendAggregator.total(for: .today, providers: [claude, cursor], snapshots: snapshots)
            .projection(for: .cost)
        let segments = cost.segments

        XCTAssertEqual(segments.map(\.family), ["claude", "cursor"])
        XCTAssertEqual(segments.reduce(0) { $0 + $1.fraction }, 1, accuracy: 0.0001)
        // 0.1% of the spend still gets a sliver near the 2.5% floor instead of vanishing.
        XCTAssertGreaterThan(segments[1].fraction, 0.02)
        // The legend keeps the true share.
        XCTAssertEqual(cost.groups.map { cost.shareLabel(forAmount: $0.displayAmount) }, ["100%", "<1%"])
    }

    func testShareLabelsRoundToWholePercents() {
        let snapshots = [
            "claude": snapshot(claude, lines: [spendLine("Today", dollars: 60)]),
            "codex": snapshot(codex, lines: [spendLine("Today", dollars: 28)]),
            "cursor": snapshot(cursor, lines: [spendLine("Today", dollars: 12)])
        ]

        let cost = TotalSpendAggregator.total(for: .today, providers: [claude, codex, cursor], snapshots: snapshots)
            .projection(for: .cost)

        XCTAssertEqual(cost.groups.map { cost.shareLabel(forAmount: $0.displayAmount) }, ["60%", "28%", "12%"])
    }

    func testCostPerMtokHasNoShareLabels() {
        let snapshots = [
            "claude": snapshot(claude, lines: [spendLine("Today", dollars: 10)]),
            "cursor": snapshot(cursor, lines: [spendLine("Today", dollars: 5)])
        ]

        let rates = TotalSpendAggregator.total(for: .today, providers: [claude, cursor], snapshots: snapshots)
            .projection(for: .costPerMtok)

        XCTAssertEqual(rates.groups.count, 2)
        XCTAssertTrue(rates.groups.allSatisfy { rates.shareLabel(forAmount: $0.displayAmount) == nil })
        XCTAssertFalse(rates.segments.isEmpty)
    }

    func testEmptyProjectionHasNoSegments() {
        let total = TotalSpendAggregator.total(for: .today, providers: [claude], snapshots: [:])
        XCTAssertTrue(total.projection(for: .cost).segments.isEmpty)
        XCTAssertTrue(total.projection(for: .cost).groups.isEmpty)
    }

    // MARK: - Grouping by provider

    private let claudeWork = Provider(id: "claude@ab12cd34", displayName: "work@example.com", icon: .providerMark("claude"))
    private let claudePeer = Provider(id: "claude@peer-99887766", displayName: "claude@99887766", icon: .providerMark("claude"))

    func testAccountsOfOneProviderRollUpIntoOneGroup() {
        let snapshots = [
            "claude": snapshot(claude, lines: [spendLine("Today", dollars: 10, tokens: 1_000_000)]),
            "claude@ab12cd34": snapshot(claudeWork, lines: [spendLine("Today", dollars: 30, tokens: 1_000_000)]),
            "cursor": snapshot(cursor, lines: [spendLine("Today", dollars: 25, tokens: 5_000_000)])
        ]
        let total = TotalSpendAggregator.total(
            for: .today, providers: [claude, claudeWork, cursor], snapshots: snapshots
        )

        let cost = total.projection(for: .cost)
        XCTAssertEqual(cost.groups.map(\.family), ["claude", "cursor"])
        XCTAssertEqual(cost.groups[0].title, "Claude")
        XCTAssertEqual(cost.groups[0].displayAmount, 40, accuracy: 0.0001)
        XCTAssertTrue(cost.groups[0].isExpandable)
        // Members keep the account ranking and their own titles.
        XCTAssertEqual(cost.groups[0].members.map(\.title), ["work@example.com", "Claude"])
        XCTAssertFalse(cost.groups[1].isExpandable)
        // The flat per-account ranking is unchanged.
        XCTAssertEqual(cost.slices.map(\.provider.id), ["claude@ab12cd34", "cursor", "claude"])

        // A family's rate is its dollars over its tokens, not a sum of its accounts' rates.
        let rates = total.projection(for: .costPerMtok)
        XCTAssertEqual(rates.groups.first { $0.family == "claude" }?.displayAmount ?? 0, 20, accuracy: 0.0001)
    }

    func testSingleAccountProviderKeepsItsOwnTitle() {
        let renamed = Provider(id: "claude", displayName: "Work Claude", icon: .providerMark("claude"))
        let snapshots = ["claude": snapshot(renamed, lines: [spendLine("Today", dollars: 10)])]

        let cost = TotalSpendAggregator.total(for: .today, providers: [renamed], snapshots: snapshots)
            .projection(for: .cost)

        XCTAssertEqual(cost.groups.map(\.title), ["Work Claude"])
        XCTAssertFalse(cost.groups[0].isExpandable)
    }

    func testMultiAccountFamilyKeepsItsFamilyTitleWhenOnlyOneAccountSpent() {
        // Two Claude accounts exist, but only one spent today: the row still reads "Claude", so it
        // doesn't flip to an account name between periods. Nothing to open with one member.
        let snapshots = ["claude@ab12cd34": snapshot(claudeWork, lines: [spendLine("Today", dollars: 30)])]

        let cost = TotalSpendAggregator.total(for: .today, providers: [claude, claudeWork], snapshots: snapshots)
            .projection(for: .cost)

        XCTAssertEqual(cost.groups.map(\.title), ["Claude"])
        XCTAssertFalse(cost.groups[0].isExpandable)
    }

    func testRemoteOnlyAccountJoinsItsFamily() {
        let snapshots = [
            "claude": snapshot(claude, lines: [spendLine("Today", dollars: 10)]),
            "claude@peer-99887766": snapshot(claudePeer, lines: [spendLine("Today", dollars: 5)])
        ]

        let cost = TotalSpendAggregator.total(for: .today, providers: [claude, claudePeer], snapshots: snapshots)
            .projection(for: .cost)

        XCTAssertEqual(cost.groups.map(\.family), ["claude"])
        XCTAssertEqual(cost.groups[0].displayAmount, 15, accuracy: 0.0001)
    }

    // MARK: - Table

    func testTableLinesUpProvidersAcrossPeriods() {
        let snapshots = [
            "claude": snapshot(claude, lines: [
                spendLine("Yesterday", dollars: 20), spendLine("Last 30 Days", dollars: 500)
            ]),
            "claude@ab12cd34": snapshot(claudeWork, lines: [
                spendLine("Today", dollars: 7), spendLine("Last 30 Days", dollars: 900)
            ]),
            "cursor": snapshot(cursor, lines: [spendLine("Today", dollars: 3), spendLine("Last 30 Days", dollars: 40)])
        ]
        let projections = TotalSpendPeriod.allCases.map {
            TotalSpendAggregator.total(for: $0, providers: [claude, claudeWork, cursor], snapshots: snapshots)
                .projection(for: .cost)
        }

        let table = TotalSpendTable.make(projections: projections, metric: .cost)

        XCTAssertEqual(table.totals, [10, 20, 1440])
        // Ranked by the longest period, so the order holds still day to day.
        XCTAssertEqual(table.rows.map(\.id), ["claude", "cursor"])
        XCTAssertEqual(table.rows[0].title, "Claude")
        XCTAssertEqual(table.rows[0].amounts, [7, 20, 1400])
        XCTAssertEqual(table.rows[1].amounts, [3, nil, 40])
        XCTAssertTrue(table.rows[0].isExpandable)
        XCTAssertEqual(table.rows[0].members.map(\.id), ["claude@ab12cd34", "claude"])
        XCTAssertEqual(table.rows[0].members[1].amounts, [nil, 20, 500])
        XCTAssertFalse(table.rows[1].isExpandable)
    }

    func testTableIsEmptyWithoutData() {
        let projections = TotalSpendPeriod.allCases.map {
            TotalSpendAggregator.total(for: $0, providers: [claude], snapshots: [:]).projection(for: .cost)
        }
        let table = TotalSpendTable.make(projections: projections, metric: .cost)
        XCTAssertTrue(table.isEmpty)
        XCTAssertEqual(table.totals, [nil, nil, nil])
    }
}
