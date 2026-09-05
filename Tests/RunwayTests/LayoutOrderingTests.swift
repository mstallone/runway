import XCTest
@testable import Runway

final class LayoutOrderingTests: XCTestCase {
    func testInsertingPlacesNewIDsAtDeclarationSlots() {
        let canonical = [
            "cursor.usage", "cursor.auto", "cursor.api", "cursor.grokBot", "cursor.onDemand",
            "cursor.trend", "cursor.today"
        ]
        let saved = [
            "cursor.usage", "cursor.auto", "cursor.api", "cursor.onDemand",
            "cursor.trend", "cursor.today"
        ]

        XCTAssertEqual(
            LayoutOrdering.inserting(["cursor.grokBot"], into: saved, canonical: canonical),
            [
                "cursor.usage", "cursor.auto", "cursor.api", "cursor.grokBot", "cursor.onDemand",
                "cursor.trend", "cursor.today"
            ]
        )
    }

    func testRelocatingMovesAnAppendedRowToItsDeclarationSlot() {
        let canonical = [
            "grok.weekly", "grok.payAsYouGo", "grok.rateLimitResets",
            "grok.trend", "grok.today", "grok.last30"
        ]
        let saved = [
            "grok.weekly", "grok.payAsYouGo", "grok.trend",
            "grok.today", "grok.last30", "grok.rateLimitResets"
        ]

        XCTAssertEqual(
            LayoutOrdering.relocating(["grok.rateLimitResets"], in: saved, canonical: canonical),
            [
                "grok.weekly", "grok.payAsYouGo", "grok.rateLimitResets",
                "grok.trend", "grok.today", "grok.last30"
            ]
        )
    }

    func testRelocatingLeavesAnAlreadySlottedRowInPlace() {
        let canonical = [
            "cursor.usage", "cursor.auto", "cursor.api", "cursor.grokBot", "cursor.onDemand"
        ]
        let saved = canonical

        XCTAssertEqual(
            LayoutOrdering.relocating(["cursor.grokBot"], in: saved, canonical: canonical),
            saved
        )
    }

    func testNormalizedMetricIDsInsertRatherThanAppend() {
        let valid = ["a", "new", "b", "c"]
        XCTAssertEqual(
            LayoutOrdering.normalizedMetricIDs(["a", "b", "c"], validIDs: valid),
            ["a", "new", "b", "c"]
        )
    }
}
