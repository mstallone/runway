import XCTest
@testable import Runway

@MainActor
final class MuseLayoutTests: XCTestCase {
    func testFreshDefaultsSeedApprovedMuseLayout() {
        let suiteName = "RunwayTests.MuseLayout.FreshDefaults.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let store = LayoutStore(
            registry: .from([MuseProvider()]),
            defaults: defaults,
            storageKey: "layout"
        )

        XCTAssertEqual(store.placed.map(\.descriptorID), [
            "muse.session",
            "muse.weekly",
            "muse.trend",
            "muse.today",
            "muse.yesterday",
            "muse.last30"
        ])
        XCTAssertEqual(Set(store.pinnedMetricIDs), ["muse.session", "muse.weekly"])

        let group = store.customizeGroups.first { $0.provider.id == "muse" }
        XCTAssertEqual(group?.alwaysShownMetrics.map(\.id), ["muse.session", "muse.weekly"])
        XCTAssertEqual(group?.expandedMetrics.map(\.id), [
            "muse.trend",
            "muse.today",
            "muse.yesterday",
            "muse.last30"
        ])
    }

    func testExistingLayoutKeepsMetersAlwaysShownWhenSpendTilesSeed() {
        let suiteName = "RunwayTests.MuseLayout.ExistingSpendSeed.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }

        defaults.set(
            try! JSONEncoder().encode([
                PlacedWidget(descriptorID: "muse.session"),
                PlacedWidget(descriptorID: "muse.weekly")
            ]),
            forKey: "layout"
        )
        defaults.set(
            try! JSONEncoder().encode(["muse.session", "muse.weekly"]),
            forKey: "layout.seededDefaults"
        )
        defaults.set([] as [String], forKey: "layout.expandedMetrics")
        defaults.set(["muse.session", "muse.weekly"], forKey: "layout.menuBarPins")

        let store = LayoutStore(
            registry: .from([MuseProvider()]),
            defaults: defaults,
            storageKey: "layout"
        )

        XCTAssertFalse(store.expandedMetricIDs.contains("muse.session"))
        XCTAssertFalse(store.expandedMetricIDs.contains("muse.weekly"))
        XCTAssertTrue(store.expandedMetricIDs.contains("muse.trend"))
        XCTAssertTrue(store.expandedMetricIDs.contains("muse.today"))
        XCTAssertEqual(Set(store.pinnedMetricIDs), ["muse.session", "muse.weekly"])
    }
}
