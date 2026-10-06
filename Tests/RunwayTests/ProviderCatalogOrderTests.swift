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
}
