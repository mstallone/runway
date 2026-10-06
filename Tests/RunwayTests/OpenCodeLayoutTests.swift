import XCTest
@testable import Runway

/// Locks OpenCode's default metric placement (owner-confirmed, consistent with every other provider):
/// the three Go caps and the Usage Trend above the fold, the spend tiles below the caret, nothing pinned.
@MainActor
final class OpenCodeLayoutTests: XCTestCase {
    func testFreshDefaultsSeedApprovedOpenCodeLayout() {
        let suiteName = "RunwayTests.OpenCodeLayout.FreshDefaults.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let store = LayoutStore(
            registry: .from([OpenCodeProvider()]),
            defaults: defaults,
            storageKey: "layout"
        )

        let aboveFold = ["opencode.session", "opencode.weekly", "opencode.monthly", "opencode.trend"]
        let belowCaret = ["opencode.today", "opencode.yesterday", "opencode.last30"]
        XCTAssertEqual(store.placed.map(\.descriptorID), aboveFold + belowCaret)
        // A freshly auto-enabled provider adds no menu-bar pins (matches Grok/Devin).
        XCTAssertTrue(store.pinnedMetricIDs.isEmpty)

        let group = store.customizeGroups.first { $0.provider.id == "opencode" }
        XCTAssertEqual(group?.alwaysShownMetrics.map(\.id), aboveFold)
        XCTAssertEqual(group?.expandedMetrics.map(\.id), belowCaret)
    }
}
