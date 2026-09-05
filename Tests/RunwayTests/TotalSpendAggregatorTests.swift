import XCTest
@testable import Runway

/// Covers the Total Spend card's aggregation and metric projection: which providers contribute,
/// how slices rank per metric, Cost/MTok math, and when the combined number counts as estimated.
final class TotalSpendAggregatorTests: XCTestCase {
    private let claude = Provider(id: "claude", displayName: "Claude", icon: .providerMark("claude"))
    private let codex = Provider(id: "codex", displayName: "Codex", icon: .providerMark("codex"))
    private let cursor = Provider(id: "cursor", displayName: "Cursor", icon: .providerMark("cursor"))

    private func snapshot(
        _ provider: Provider,
        lines: [MetricLine] = [],
        history: ProviderUsageHistory? = nil
    ) -> ProviderSnapshot {
        ProviderSnapshot(
            providerID: provider.id,
            displayName: provider.displayName,
            lines: lines,
            refreshedAt: Date(timeIntervalSince1970: 1_800_000_000),
            usageHistory: history
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
        XCTAssertEqual(total.totalUSD, 9.75, accuracy: 0.0001)
        XCTAssertEqual(total.totalTokens, 600_000, accuracy: 0.0001)

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

        XCTAssertFalse(total.isEmpty)
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

        XCTAssertTrue(total.isEstimated)
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
        XCTAssertTrue(total.isEmpty)
        XCTAssertTrue(total.projection(for: .cost).isEmpty)
        XCTAssertTrue(total.projection(for: .tokens).isEmpty)
        XCTAssertTrue(total.projection(for: .costPerMtok).isEmpty)
    }

    func testPeriodSwitcherLabelsAreToday7And30Days() {
        XCTAssertEqual(TotalSpendPeriod.allCases.map(\.shortLabel), ["Today", "7 Days", "30 Days"])
        XCTAssertEqual(TotalSpendPeriod.last7.dayCount, 7)
        XCTAssertEqual(TotalSpendPeriod.last30.dayCount, UsageHistoryWindow.previousDays + 1)
        XCTAssertEqual(TotalSpendPeriod.today.dayCount, 1)
    }

    func testLast7SumsHistoryInsideTheWindowAndSkipsOlderDays() throws {
        let calendar = Calendar(identifier: .gregorian)
        let now = calendar.date(from: DateComponents(year: 2026, month: 9, day: 4, hour: 12))!
        let snapshots = [
            "claude": snapshot(
                claude,
                lines: [spendLine("Last 30 Days", dollars: 99, tokens: 9_000_000, estimated: true)],
                history: history([
                    ("2026-09-04", 10, 1),   // today
                    ("2026-09-01", 20, 2),   // inside 7 days
                    ("2026-08-28", 400, 40)  // 8 days back — outside 7, inside 30
                ])
            )
        ]

        let last7 = TotalSpendAggregator.total(
            for: .last7, providers: [claude], snapshots: snapshots, now: now, calendar: calendar
        )
        XCTAssertEqual(try XCTUnwrap(last7.slices.first).amountUSD, 3, accuracy: 0.0001)
        XCTAssertEqual(try XCTUnwrap(last7.slices.first).tokenCount, 30, accuracy: 0.0001)
        XCTAssertEqual(last7.days.count, 7)
        XCTAssertEqual(last7.days.first?.dayKey, "2026-08-29")
        XCTAssertEqual(last7.days.last?.dayKey, "2026-09-04")
        XCTAssertEqual(last7.days.map { $0.totalUSD }.reduce(0, +), 3, accuracy: 0.0001)

        let last30 = TotalSpendAggregator.total(
            for: .last30, providers: [claude], snapshots: snapshots, now: now, calendar: calendar
        )
        XCTAssertEqual(try XCTUnwrap(last30.slices.first).amountUSD, 43, accuracy: 0.0001)
        XCTAssertEqual(last30.days.count, UsageHistoryWindow.previousDays + 1)
    }

    func testStackedDaysKeepIdleCalendarBars() {
        let calendar = Calendar(identifier: .gregorian)
        let now = calendar.date(from: DateComponents(year: 2026, month: 9, day: 4, hour: 12))!
        let snapshots = [
            "claude": snapshot(
                claude,
                history: history([("2026-09-04", 10, 1)])
            ),
            "cursor": snapshot(
                cursor,
                history: history([("2026-09-03", 50, 5)])
            )
        ]

        let last7 = TotalSpendAggregator.total(
            for: .last7, providers: [claude, cursor], snapshots: snapshots, now: now, calendar: calendar
        )
        XCTAssertEqual(last7.days.count, 7)
        let byKey = Dictionary(uniqueKeysWithValues: last7.days.map { ($0.dayKey, $0) })
        XCTAssertEqual(byKey["2026-09-04"]?.slices.map(\.providerID), ["claude"])
        XCTAssertEqual(byKey["2026-09-03"]?.slices.map(\.providerID), ["cursor"])
        XCTAssertEqual(byKey["2026-09-02"]?.slices.count, 0, "idle days stay in the series so each bar is a day")
        XCTAssertEqual(last7.projection(for: .cost).slices.map(\.provider.id), ["cursor", "claude"])
    }

    func testLast7WithoutHistoryDoesNotInventATile() {
        let snapshots = [
            "claude": snapshot(claude, lines: [spendLine("Today", dollars: 2.50), spendLine("Last 30 Days", dollars: 10)])
        ]
        let total = TotalSpendAggregator.total(for: .last7, providers: [claude], snapshots: snapshots)
        XCTAssertTrue(total.isEmpty)
        XCTAssertEqual(total.days.count, 7)
        XCTAssertTrue(total.days.allSatisfy(\.slices.isEmpty))
    }

    func testTodayTileFallbackFillsTheSingleBar() throws {
        let calendar = Calendar(identifier: .gregorian)
        let now = calendar.date(from: DateComponents(year: 2026, month: 9, day: 4, hour: 12))!
        let snapshots = [
            "claude": snapshot(claude, lines: [spendLine("Today", dollars: 2.50, tokens: 100_000, estimated: true)])
        ]
        let total = TotalSpendAggregator.total(
            for: .today, providers: [claude], snapshots: snapshots, now: now, calendar: calendar
        )
        XCTAssertEqual(total.days.count, 1)
        XCTAssertEqual(try XCTUnwrap(total.days.first?.slices.first).amountUSD, 2.50, accuracy: 0.0001)
        XCTAssertEqual(total.days.first?.dayKey, "2026-09-04")
    }

    private func history(_ days: [(String, Int, Double)]) -> ProviderUsageHistory {
        ProviderUsageHistory(
            series: DailyUsageSeries(daily: days.map {
                DailyUsageEntry(date: $0.0, totalTokens: $0.1, costUSD: $0.2)
            })
        )
    }
}
