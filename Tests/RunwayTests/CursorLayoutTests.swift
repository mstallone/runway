import XCTest
@testable import Runway

/// Locks Cursor's default metric placement: which metrics are enabled, the Always Visible / On Demand
/// split, and the menu-bar pins a fresh install seeds.
@MainActor
final class CursorLayoutTests: XCTestCase {
    func testFreshDefaultsSeedApprovedCursorLayout() {
        let suiteName = "RunwayTests.CursorLayout.FreshDefaults.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let store = LayoutStore(
            registry: .from([CursorProvider()]),
            defaults: defaults,
            storageKey: "layout"
        )

        // Requests and Credits ship disabled; Grok Bot is enabled, On Demand, and unpinned.
        XCTAssertEqual(store.placed.map(\.descriptorID), [
            "cursor.usage", "cursor.auto", "cursor.api", "cursor.grokBot", "cursor.onDemand",
            "cursor.trend", "cursor.today", "cursor.yesterday", "cursor.last30"
        ])
        XCTAssertEqual(store.pinnedMetricIDs, ["cursor.auto", "cursor.api"])

        let group = store.customizeGroups.first { $0.provider.id == "cursor" }
        XCTAssertEqual(group?.alwaysShownMetrics.map(\.id), [
            "cursor.usage", "cursor.auto", "cursor.api", "cursor.trend"
        ])
        XCTAssertEqual(group?.expandedMetrics.map(\.id), [
            "cursor.grokBot", "cursor.onDemand", "cursor.requests", "cursor.credits",
            "cursor.today", "cursor.yesterday", "cursor.last30"
        ])
    }

    func testGrokBotIsOutsideTheMigrationBaseline() {
        // Outside the frozen baseline, so existing users are offered it once.
        XCTAssertFalse(DefaultLayout.migrationBaselineMetricIDs.contains("cursor.grokBot"))
    }
}
