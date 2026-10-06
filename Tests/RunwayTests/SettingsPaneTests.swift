import XCTest
@testable import Runway

/// The Settings window's pane identity: raw values are persisted (last-selected pane, per-pane
/// height keys) and double as the toolbar item identifiers, so they must stay stable.
final class SettingsPaneTests: XCTestCase {
    func testRawValuesAreStable() {
        XCTAssertEqual(
            SettingsPane.allCases.map(\.rawValue),
            ["general", "appearance", "notifications", "advanced"]
        )
    }

}
