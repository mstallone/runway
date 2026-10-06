import XCTest
@testable import Runway

/// Covers the strip renderer's single-entry memo (#18): equal (content, style) inputs return the
/// previously rendered `NSImage` instance — so the hundreds of label re-evaluations between real
/// data changes never re-run `ImageRenderer` — while a changed value or style renders fresh.
@MainActor
final class MenuBarStripMemoTests: XCTestCase {
    func testEqualContentReturnsSameImageInstance() throws {
        let first = try XCTUnwrap(MenuBarStripRenderer.presentation(for: makeContent(value: "42%"), style: .text)?.image)
        let second = try XCTUnwrap(MenuBarStripRenderer.presentation(for: makeContent(value: "42%"), style: .text)?.image)
        XCTAssertIdentical(first, second)
    }

    func testChangedValueRendersFreshImage() throws {
        let first = try XCTUnwrap(MenuBarStripRenderer.presentation(for: makeContent(value: "42%"), style: .text)?.image)
        let changed = try XCTUnwrap(MenuBarStripRenderer.presentation(for: makeContent(value: "43%"), style: .text)?.image)
        XCTAssertNotIdentical(first, changed)
    }

    func testChangedStyleRendersFreshImage() throws {
        let content = makeContent(value: "42%")
        let text = try XCTUnwrap(MenuBarStripRenderer.presentation(for: content, style: .text)?.image)
        let bars = try XCTUnwrap(MenuBarStripRenderer.presentation(for: content, style: .bars)?.image)
        XCTAssertNotIdentical(text, bars)
    }

    func testTextStyleIgnoresFractionOnlyChanges() throws {
        // A refresh that moved the underlying fraction behind an unchanged rounded value ("42%")
        // must hit the memo under Text — the fraction is never drawn there.
        let first = try XCTUnwrap(
            MenuBarStripRenderer.presentation(for: makeContent(value: "42%", fraction: 0.4211), style: .text)?.image
        )
        let nudged = try XCTUnwrap(
            MenuBarStripRenderer.presentation(for: makeContent(value: "42%", fraction: 0.4218), style: .text)?.image
        )
        XCTAssertIdentical(first, nudged)
    }

    func testBarsStyleRerendersOnFractionChange() throws {
        // Bars draw the fraction, so the same nudge must render fresh there.
        let first = try XCTUnwrap(
            MenuBarStripRenderer.presentation(for: makeContent(value: "42%", fraction: 0.4211), style: .bars)?.image
        )
        let nudged = try XCTUnwrap(
            MenuBarStripRenderer.presentation(for: makeContent(value: "42%", fraction: 0.4218), style: .bars)?.image
        )
        XCTAssertNotIdentical(first, nudged)
    }

    func testChangedDisplayNameRendersFreshImage() throws {
        // The cached image bakes in the accessibility text (names, labels, values), so a rename
        // must miss the memo even when nothing drawn in Bars changed.
        let first = try XCTUnwrap(
            MenuBarStripRenderer.presentation(for: makeContent(value: "42%"), style: .bars)?.image
        )
        let renamed = try XCTUnwrap(
            MenuBarStripRenderer.presentation(for: makeContent(value: "42%", displayName: "Work"), style: .bars)?.image
        )
        XCTAssertNotIdentical(first, renamed)
    }

    private func makeContent(
        value: String, fraction: Double = 0.42, displayName: String = "Claude"
    ) -> MenuBarContent {
        let metric = MenuBarContent.Metric(
            id: "claude.session", label: "Session", value: value,
            fraction: fraction, isBounded: true, hasData: true
        )
        return MenuBarContent(
            groups: [MenuBarContent.Group(
                providerID: "claude",
                displayName: displayName,
                icon: .providerMark("claude"),
                metrics: [metric]
            )],
            bars: [metric]
        )
    }
}
