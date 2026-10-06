import XCTest
@testable import Runway

/// The default provider order: Claude, Codex, Cursor, then every other provider alphabetically by
/// display name. The catalog's array order seeds the default order in `LayoutStore`.
@MainActor
final class ProviderCatalogOrderTests: XCTestCase {
    func testCatalogOrderIsHeadlineProvidersThenAlphabetical() {
        let defaults = UserDefaults(suiteName: "ProviderCatalogOrderTests.\(UUID().uuidString)")!
        let ids = ProviderCatalog.make(defaults: defaults).map(\.provider.id)

        XCTAssertEqual(ids, [
            "claude", "codex", "cursor",
            "antigravity", "copilot", "devin", "grok", "kimi", "muse",
            "opencode", "openrouter", "sakana", "zai"
        ])
    }

    func testEveryDefaultLayoutIDNamesAShippingMetric() {
        // `LayoutStore` silently drops default IDs the registry doesn't know, so a typo here would
        // otherwise just make a metric quietly miss its default.
        let defaults = UserDefaults(suiteName: "ProviderCatalogOrderTests.\(UUID().uuidString)")!
        let shipping = Set(ProviderCatalog.make(defaults: defaults).flatMap { $0.widgetDescriptors.map(\.id) })

        XCTAssertEqual(DefaultLayout.metricIDs.filter { !shipping.contains($0) }, [])
        XCTAssertEqual(DefaultLayout.pinnedMetricIDs.filter { !shipping.contains($0) }, [])
        XCTAssertEqual(DefaultLayout.expandedMetricIDs.filter { !shipping.contains($0) }, [])
    }
}
