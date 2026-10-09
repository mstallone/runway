import XCTest
@testable import Runway

final class AccountCardGroupingTests: XCTestCase {
    private let cards = ["claude", "codex", "claude@ab12cd34", "cursor", "codex@99887766", "claude@0f0f0f0f"]

    func testGroupingOffKeepsEveryCardItsOwnSection() {
        let sections = AccountCardGrouping.sections(cards, cardID: { $0 }, enabled: false)
        XCTAssertEqual(sections, cards.map { [$0] })
    }

    func testGroupingGathersAProvidersAccountsAtItsFirstCard() {
        let sections = AccountCardGrouping.sections(cards, cardID: { $0 }, enabled: true)
        XCTAssertEqual(sections, [
            ["claude", "claude@ab12cd34", "claude@0f0f0f0f"],
            ["codex", "codex@99887766"],
            ["cursor"],
        ])
    }

    func testAccountTitleDropsTheProviderPrefixOnly() {
        XCTAssertEqual(
            AccountCardGrouping.accountTitle(displayName: "Claude — matt@example.com", familyName: "Claude"),
            "matt@example.com"
        )
        // A renamed card keeps the name it was given, and a bare provider name is left alone.
        XCTAssertEqual(AccountCardGrouping.accountTitle(displayName: "Work", familyName: "Claude"), "Work")
        XCTAssertEqual(AccountCardGrouping.accountTitle(displayName: "Claude", familyName: "Claude"), "Claude")
        XCTAssertEqual(AccountCardGrouping.accountTitle(displayName: "Claude — ", familyName: "Claude"), "Claude — ")
    }

    @MainActor
    func testReorderAmongAccountsKeepsEveryOtherCardInItsSlot() {
        let order = ["claude", "codex", "claude@ab12cd34", "cursor", "claude@0f0f0f0f"]
        let accounts = ["claude", "claude@ab12cd34", "claude@0f0f0f0f"]
        // The first account moves below the last: the provider still starts in slot 0.
        XCTAssertEqual(
            LayoutStore.reordered(order, dragged: "claude", target: "claude@0f0f0f0f", among: accounts),
            ["claude@ab12cd34", "codex", "claude@0f0f0f0f", "cursor", "claude"]
        )
        XCTAssertEqual(
            LayoutStore.reordered(order, dragged: "claude@0f0f0f0f", target: "claude", among: accounts),
            ["claude@0f0f0f0f", "codex", "claude", "cursor", "claude@ab12cd34"]
        )
        XCTAssertNil(LayoutStore.reordered(order, dragged: "codex", target: "claude", among: accounts), "Not one of them")
        XCTAssertEqual(
            LayoutStore.reordered(order, dragged: "cursor", target: "claude", among: nil),
            LayoutStore.reordered(order, dragged: "cursor", target: "claude")
        )
    }

    @MainActor
    func testGroupedSectionIsKeyedByItsProviderNotItsFirstAccount() {
        XCTAssertEqual(DashboardSection.familyID(of: "claude"), DashboardSection.familyID(of: "claude@ab12cd34"))
        XCTAssertNotEqual(DashboardSection.familyID(of: "claude"), DashboardSection.familyID(of: "codex"))
    }
}
