import AppKit
import SwiftUI
import XCTest
@testable import Runway

@MainActor
final class WeightedRowTests: XCTestCase {
    func testIdealSizeGivesEveryColumnTheWidestTilesWidth() {
        // An ideal-size query proposes no width. The row used to read that as zero and hand its
        // tiles negative widths; it should size every column to the widest tile instead.
        let row = WeightedRow(columns: 3, spacing: 8) {
            Color.clear.frame(width: 40, height: 10)
            Color.clear.frame(width: 60, height: 20)
        }
        let size = NSHostingView(rootView: row.fixedSize()).fittingSize
        XCTAssertEqual(size.width, 60 * 3 + 8 * 2, accuracy: 0.5)
        XCTAssertEqual(size.height, 20, accuracy: 0.5)
    }
}
