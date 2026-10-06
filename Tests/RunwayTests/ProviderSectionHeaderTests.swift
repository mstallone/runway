import XCTest
@testable import Runway

@MainActor
final class ProviderSectionHeaderTests: XCTestCase {
    func testActionableWarningTooltipAppendsTheClickAffordance() {
        // Clicking the triangle refreshes the provider, and nothing else on screen says so — the
        // tooltip has to carry the affordance. Provider messages already end in a period, so the
        // hint joins as one more sentence.
        XCTAssertEqual(
            ProviderSectionHeader.warningTooltip(
                for: ClaudeAuthError.codePermissionDenied.localizedDescription,
                refreshable: true
            ),
            "Keychain access to the Claude Code login was declined. Refresh and choose Always Allow when macOS asks. Click to refresh."
        )
        // A message that arrives without end punctuation (an HTTP failure line) gets a period first,
        // so the hint never runs into it.
        XCTAssertEqual(
            ProviderSectionHeader.warningTooltip(for: "Refresh failed", refreshable: true),
            "Refresh failed. Click to refresh."
        )
        XCTAssertEqual(
            ProviderSectionHeader.warningTooltip(for: "Where did the data go?", refreshable: true),
            "Where did the data go? Click to refresh."
        )
    }

    func testNonActionableWarningTooltipStaysTheBareMessage() {
        // The reorder preview's triangle carries no action, so promising a click there would lie.
        XCTAssertEqual(
            ProviderSectionHeader.warningTooltip(for: "Token expired.", refreshable: false),
            "Token expired."
        )
        // An all-whitespace message resolves to empty (hoverTooltip's "no tooltip" case) rather than
        // a bare "Click to refresh." with nothing to explain it.
        XCTAssertEqual(ProviderSectionHeader.warningTooltip(for: "  ", refreshable: true), "")
    }

    func testCopyZoneFollowsThePlanToTheHeaderEdge() {
        // The zone starts at the plan's live leading edge, so it grows as the plan slides left for
        // the button, and runs to the header's trailing edge.
        let resting = ProviderSectionHeader.copyZone(headerWidth: 300, planMinX: 250, showsWarning: false)
        XCTAssertEqual(resting, 250...300)
        let revealed = ProviderSectionHeader.copyZone(headerWidth: 300, planMinX: 233, showsWarning: false)
        XCTAssertTrue(revealed.contains(240))
        XCTAssertFalse(resting.contains(240))
    }

    func testCopyZoneWithoutAPlanIsTheCopySlot() {
        let zone = ProviderSectionHeader.copyZone(headerWidth: 300, planMinX: nil, showsWarning: false)
        let slotMinX = 300 - ProviderSectionHeader.trailingPadding - CopyFeedbackButton.slotWidth
        XCTAssertEqual(zone, slotMinX...300)
    }

    func testCopyZoneStopsShortOfTheNoticeGlyph() {
        // The notice glyph keeps its own hover (tooltip) and click, and the copy slot sits just
        // inside it: the zone must cover that slot and end where the glyph begins.
        let contentMaxX = 300 - ProviderSectionHeader.trailingPadding
        let glyphMinX = contentMaxX - ProviderSectionHeader.warningSlotWidth
        let slotMaxX = contentMaxX - ProviderSectionHeader.copySlotTrailingOffset(showsWarning: true)
        let slotMinX = slotMaxX - CopyFeedbackButton.slotWidth

        let withoutPlan = ProviderSectionHeader.copyZone(headerWidth: 300, planMinX: nil, showsWarning: true)
        XCTAssertEqual(withoutPlan, slotMinX...glyphMinX)
        XCTAssertLessThan(slotMaxX, glyphMinX)

        let withPlan = ProviderSectionHeader.copyZone(headerWidth: 300, planMinX: 200, showsWarning: true)
        XCTAssertEqual(withPlan, 200...glyphMinX)
        XCTAssertFalse(withPlan.contains(contentMaxX - 1))
    }
}
