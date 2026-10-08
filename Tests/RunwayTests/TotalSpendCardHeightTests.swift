import XCTest
@testable import Runway

/// Covers the height arithmetic the Total Spend card uses to retarget the panel inside its own
/// animation: the difference between two states must equal what the views add or remove.
final class TotalSpendCardHeightTests: XCTestCase {
    private let claude = Provider(id: "claude", displayName: "Claude", icon: .providerMark("claude"))
    private let claudeWork = Provider(id: "claude@ab12cd34", displayName: "work@example.com", icon: .providerMark("claude"))
    private let cursor = Provider(id: "cursor", displayName: "Cursor", icon: .providerMark("cursor"))

    private var projections: [TotalSpendProjection] {
        func line(_ label: String, _ dollars: Double) -> MetricLine {
            .values(label: label, values: [MetricValue(number: dollars, kind: .dollars)])
        }
        func snapshot(_ provider: Provider, _ lines: [MetricLine]) -> ProviderSnapshot {
            ProviderSnapshot(
                providerID: provider.id,
                displayName: provider.displayName,
                lines: lines,
                refreshedAt: Date(timeIntervalSince1970: 1_800_000_000)
            )
        }
        let snapshots = [
            "claude": snapshot(claude, [line("Today", 5), line("Last 30 Days", 50)]),
            "claude@ab12cd34": snapshot(claudeWork, [line("Today", 3), line("Last 30 Days", 30)]),
            "cursor": snapshot(cursor, [line("Last 30 Days", 10)])
        ]
        return TotalSpendPeriod.allCases.map {
            TotalSpendAggregator.total(for: $0, providers: [claude, claudeWork, cursor], snapshots: snapshots)
                .projection(for: .cost)
        }
    }

    private func height(
        _ layout: TotalSpendLayout,
        period: TotalSpendPeriod = .last30,
        collapsed: Bool = false,
        expanded: Set<String> = []
    ) -> CGFloat {
        TotalSpendCardHeight.variable(
            layout: layout, projections: projections, period: period,
            collapsed: collapsed, expanded: expanded, rowHeight: 14
        )
    }

    func testOpeningAProviderAddsOneLegendRowPerAccount() {
        // Two Claude accounts: two 14pt rows, each with the row spacing (6 in the legend, 5 in the table).
        XCTAssertEqual(height(.bar, expanded: ["claude"]) - height(.bar), 40, accuracy: 0.001)
        XCTAssertEqual(height(.table, expanded: ["claude"]) - height(.table), 38, accuracy: 0.001)
    }

    func testOpeningAProviderWithOneAccountChangesNothing() {
        XCTAssertEqual(height(.bar, expanded: ["cursor"]), height(.bar), accuracy: 0.001)
    }

    func testCollapsingRemovesTheWholeBreakdown() {
        XCTAssertEqual(height(.bar, collapsed: true), 0)
        // 30 Days, two providers: 11 inset + 8 bar + 9 spacing + two 14pt rows + 6 gap + 10 inset.
        XCTAssertEqual(height(.bar), 72, accuracy: 0.001)
    }

    func testPieHoldsTheRingHeightUntilTheLegendOutgrowsIt() {
        XCTAssertEqual(height(.pie), 113, accuracy: 0.001)
        XCTAssertEqual(height(.pie, expanded: ["claude"]), 113, accuracy: 0.001)
    }

    func testSwitchingPeriodFollowsThatPeriodsRows() {
        // Today has only Claude; 30 Days adds Cursor.
        XCTAssertEqual(height(.bar) - height(.bar, period: .today), 20, accuracy: 0.001)
        // Yesterday has nothing: 11 inset + the empty state's 14pt line + 10 padding either side + 10 inset.
        XCTAssertEqual(height(.bar, period: .yesterday), 55, accuracy: 0.001)
    }
}
