import XCTest
@testable import Runway

final class MetricTileTests: XCTestCase {
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/Los_Angeles")!
        return calendar
    }

    /// Thursday, October 8, 2026, 10:00 AM Pacific.
    private var now: Date {
        calendar.date(from: DateComponents(year: 2026, month: 10, day: 8, hour: 10))!
    }

    private func meter(_ title: String = "Weekly", used: Double = 40) -> WidgetData {
        WidgetData(title: title, icon: .providerMark("codex"), kind: .percent, used: used, limit: 100)
    }

    // MARK: - Compact reset label

    func testRelativeCompactLabelIsTheBareCountdown() {
        let label = Formatters.compactWhenLabel(
            at: now.addingTimeInterval(2 * 86_400 + 6 * 3_600), mode: .relative, now: now, calendar: calendar
        )
        XCTAssertEqual(label, "2d 6h")
    }

    func testAbsoluteCompactLabelShortensWithDistance() {
        let today = now.addingTimeInterval(3 * 3_600)
        let saturday = now.addingTimeInterval(2 * 86_400)
        let nextMonth = now.addingTimeInterval(20 * 86_400)
        let time = TimeFormatSetting.current.shortTime(today)
        XCTAssertEqual(Formatters.compactWhenLabel(at: today, mode: .absolute, now: now, calendar: calendar), time)
        let weekdayLabel = Formatters.compactWhenLabel(at: saturday, mode: .absolute, now: now, calendar: calendar)
        XCTAssertEqual(weekdayLabel, "Sat \(TimeFormatSetting.current.shortTime(saturday))")
        XCTAssertEqual(
            Formatters.compactWhenLabel(at: nextMonth, mode: .absolute, now: now, calendar: calendar),
            Formatters.monthDayLabel(nextMonth)
        )
        XCTAssertEqual(
            Formatters.compactWhenLabel(at: now.addingTimeInterval(-60), mode: .absolute, now: now, calendar: calendar),
            Formatters.imminent
        )
    }

    // MARK: - Tile contents

    private func value(_ title: String = "Extra Usage") -> WidgetData {
        var data = WidgetData(title: title, icon: .providerMark("codex"), kind: .dollars, used: 2_300, limit: nil)
        data.values = [MetricValue(number: 2_300, kind: .dollars), MetricValue(number: 56_300, kind: .count, label: "credits")]
        return data
    }

    func testReadingSplitsNumberFromItsModeWord() {
        var data = meter(used: 38)
        data.displayMode = .remaining
        XCTAssertEqual(data.limitReading.value, "62%")
        XCTAssertEqual(data.limitReading.word, "left")
        data.displayMode = .used
        XCTAssertEqual(data.limitReading.word, "used")
        data.hasData = false
        XCTAssertEqual(data.limitReading.value, WidgetData.noDataHeadline)
        XCTAssertNil(data.limitReading.word)
    }

    func testTimeLineIsTheResetInShortForm() {
        var data = meter()
        XCTAssertNil(data.tileTime(for: .level(.normal), now: now, calendar: calendar), "No reset, nothing to print")
        data.resetsAt = now.addingTimeInterval(2 * 3_600 + 15 * 60)
        XCTAssertEqual(
            data.tileTime(for: .healthy(projectedFraction: 0.5), now: now, calendar: calendar),
            WidgetData.TileTime(text: "2h 15m", isRunOut: false)
        )
        data.hasData = false
        XCTAssertEqual(data.tileTime(for: .noData, now: now, calendar: calendar)?.text, WidgetData.noDataSubtitle)
    }

    func testRunOutWithNoTimeOfItsOwnKeepsTheResetAndNoFlame() {
        var data = meter()
        data.resetsAt = now.addingTimeInterval(86_400)
        // Projected to land right at the limit: there is no run-out time, so a flame beside the
        // reset would say the limit dies at the moment it refills.
        XCTAssertEqual(
            data.tileTime(for: .runningOut(eta: nil, projectedFraction: 1), now: now, calendar: calendar),
            WidgetData.TileTime(text: "1d 0h", isRunOut: false)
        )
    }

    func testTileDetailSaysOnlyWhatTheTileDoesNot() {
        typealias Row = WidgetData.TileDetail.Row
        XCTAssertNil(meter(used: 60).tileDetail(for: .level(.normal), now: now, calendar: calendar), "No reset, no pace: nothing to add")
        var noData = meter()
        noData.hasData = false
        XCTAssertNil(noData.tileDetail(for: .noData, now: now, calendar: calendar))

        var data = meter(used: 60)
        let reset = now.addingTimeInterval(2 * 86_400)
        data.resetsAt = reset
        let exact = Formatters.whenLabel(at: reset, mode: .absolute, now: now, calendar: calendar)!
        // The tile counts down, so the detail gives the exact time.
        XCTAssertEqual(
            data.tileDetail(for: .healthy(projectedFraction: 0.65), now: now, calendar: calendar)?.rows,
            [Row(label: "At Reset", value: "~35% left"), Row(label: "Resets", value: exact)]
        )
        XCTAssertEqual(
            data.tileDetail(for: .spent, now: now, calendar: calendar)?.rows,
            [Row(label: "Resets", value: exact)]
        )
        // And the other way round.
        data.resetDisplayMode = .absolute
        XCTAssertEqual(
            data.tileDetail(for: .runningOut(eta: nil, projectedFraction: 1.12), now: now, calendar: calendar)?.rows,
            [Row(label: "At Reset", value: "~12% over limit"), Row(label: "Resets", value: "in 2d 0h")]
        )
    }

    func testPlainValueIsATileAndRowsWithTheirOwnSurfaceAreNot() {
        let tile = value().valueTile
        XCTAssertEqual(tile?.value, MetricFormatter.string(for: MetricValue(number: 2_300, kind: .dollars), style: .row))
        XCTAssertEqual(tile?.detail, MetricFormatter.string(for: MetricValue(number: 56_300, kind: .count, label: "credits"), style: .row))

        var badge = value()
        badge.valueTextOverride = "Managed by Your Organization"
        XCTAssertNil(badge.valueTile, "A sentence needs its own line")
        var credits = value()
        credits.showsResetExpiries = true
        XCTAssertNil(credits.valueTile, "Its value opens the resets popover")
        var empty = value()
        empty.hasData = false
        XCTAssertNil(empty.valueTile)
        XCTAssertNil(meter().valueTile, "A limit is a limit tile")
    }

    func testExhaustedWeekIsNotATile() {
        var exhausted = meter(used: 100)
        exhausted.exhaustedWeeklyTitle = "Usage Exhausted"
        XCTAssertFalse(exhausted.isLimitTile)
        XCTAssertTrue(meter().isLimitTile)
    }

    // MARK: - Grid layout

    /// The grid shape as text: `2+1/3` is a limit spanning two of three columns and a value one.
    private func shape(_ rows: [WidgetData], limitColumns: Int? = nil) -> [String] {
        MeterTileLayout.segments(rows, data: { $0 }, limitColumns: limitColumns).map { segment in
            switch segment {
            case .grid(let grid): grid.tiles.map { String($0.weight) }.joined(separator: "+") + "/\(grid.columns)"
            case .row(let row): "row:\(row.title)"
            }
        }
    }

    func testLimitsFillTheirGrid() {
        XCTAssertEqual(shape([meter()]), ["1/1"])
        XCTAssertEqual(shape([meter(), meter(), meter()]), ["1+1+1/3"])
        XCTAssertEqual(shape([meter(), meter(), meter(), meter()]), ["1+1+1+1/2"], "Four sit two by two")
        XCTAssertEqual(shape([meter(), meter(), meter(), meter()], limitColumns: 3), ["1+1+1+1/3"])
        XCTAssertEqual(
            MeterTileLayout.Grid(tiles: (0..<5).map { MeterTileLayout.Tile(item: $0, weight: 1) }, columns: 3, hasValues: false)
                .rows.map(\.count),
            [3, 2]
        )
    }

    func testAValueTakesAThirdAndTheLimitsShareTheRest() {
        XCTAssertEqual(shape([meter(), value()]), ["2+1/3"])
        XCTAssertEqual(shape([meter(), value(), value("Balance")]), ["1+1+1/3"])
        XCTAssertEqual(shape([meter(), meter("Session"), value()]), ["1+1+1/3"])
    }

    func testValuesKeepTheirOwnLineWhenTheRowIsFullOrHasNoLimit() {
        XCTAssertEqual(shape([value()]), ["row:Extra Usage"], "A value alone is a row, not a grid")
        XCTAssertEqual(
            shape([meter(), meter("Session"), meter("Fable"), value()]),
            ["1+1+1/3", "row:Extra Usage"]
        )
    }

    func testOtherRowsSplitTheGridInSavedOrder() {
        var chart = WidgetData(title: "Usage Trend", icon: .providerMark("codex"), kind: .count, used: 0, limit: nil)
        chart.isChart = true
        XCTAssertEqual(shape([meter(), chart, meter("Session")]), ["1/1", "row:Usage Trend", "1/1"])
    }

    func testLimitWithNoDataHoldsNoPlaceBesideOnesThatHaveIt() {
        var empty = meter("Extra Usage")
        empty.hasData = false
        XCTAssertEqual(shape([meter(), meter("Session"), empty]), ["1+1/2"])
        XCTAssertEqual(shape([empty]), ["1/1"], "With nothing else to show, it stays so the card is not blank")
    }

    func testAccountsOfOneProviderShareTheirLimitColumns() {
        let columns = MeterTileLayout.limitColumnsByFamily([
            (family: "claude", limits: 3), (family: "claude", limits: 4), (family: "claude", limits: 0),
            (family: "codex", limits: 1), (family: "cursor", limits: 4), (family: "kimi", limits: 0),
        ])
        XCTAssertEqual(columns, ["claude": 3, "codex": 1, "cursor": 2])
        let cards = [[meter(), meter(), meter()], [meter(), value()]].map {
            MeterTileLayout.limitGridSize(MeterTileLayout.segments($0, data: { $0 }))
        }
        XCTAssertEqual(cards, [3, 0], "A grid with a value in it has its own widths")
    }

    func testExhaustedWeekNotePairsCountdownAndExactTime() {
        var exhausted = meter(used: 100)
        exhausted.exhaustedWeeklyTitle = "Usage Exhausted"
        XCTAssertEqual(exhausted.exhaustedWeeklyResetNote(now: now, calendar: calendar), "Reset Time Unavailable")
        let reset = now.addingTimeInterval(2 * 86_400)
        exhausted.resetsAt = reset
        XCTAssertEqual(
            exhausted.exhaustedWeeklyResetNote(now: now, calendar: calendar),
            "Resets in 2d 0h · Sat \(TimeFormatSetting.current.shortTime(reset))"
        )
        XCTAssertEqual(
            exhausted.exhaustedWeeklyResetNote(now: now, calendar: calendar, countdownOnly: true), "Resets in 2d 0h"
        )
        exhausted.resetsAt = now.addingTimeInterval(60)
        XCTAssertEqual(exhausted.exhaustedWeeklyResetNote(now: now, calendar: calendar), "Resets soon")
    }

    // MARK: - Account availability

    private let provider = Provider(id: "codex", displayName: "Codex", icon: .providerMark("codex"))

    private func row(_ data: WidgetData, limit key: String) -> ResolvedRow {
        let descriptor = WidgetDescriptor.percent(id: "codex.\(key)", provider: provider, title: data.title)
            .exportingLimit(key, unit: "percent")
        return ResolvedRow(
            widget: PlacedWidget(descriptorID: descriptor.id),
            descriptor: descriptor,
            data: WeeklyQuotaVisibility.presentation(data, descriptor: descriptor)
        )
    }

    private func card(always: [ResolvedRow], expanded: [ResolvedRow] = [], message: String? = nil) -> ResolvedCard {
        ResolvedCard(
            group: ProviderGroup(provider: provider, alwaysShownWidgets: [], expandedWidgets: []),
            message: message, isExpanded: false, hasExpandedContent: !expanded.isEmpty,
            alwaysRows: always, expandedRows: expanded, condensedIDs: []
        )
    }

    @MainActor
    func testAccountIsUsableUntilALimitIsSpent() {
        let weekly = row(meter(used: 40), limit: "weekly")
        XCTAssertTrue(AccountAvailability.isUsable(card(always: [weekly, row(meter("Session", used: 10), limit: "session")]), now: now))
        XCTAssertFalse(AccountAvailability.isUsable(card(always: [weekly, row(meter("Session", used: 100), limit: "session")]), now: now))
        XCTAssertFalse(
            AccountAvailability.isUsable(card(always: [weekly], expanded: [row(meter("Session", used: 100), limit: "session")]), now: now),
            "A spent limit tucked On Demand still counts"
        )
        XCTAssertFalse(
            AccountAvailability.isUsable(card(always: [], message: "Not logged in."), now: now),
            "An account whose usage did not load is not ready"
        )
    }

    @MainActor
    func testOnlyTheSharedWeekExhaustsTheAccount() {
        let week = row(meter(used: 100), limit: "weekly")
        XCTAssertEqual(week.data.exhaustedWeeklyTitle, "Usage Exhausted")
        XCTAssertTrue(AccountAvailability.isExhausted([week]))
        XCTAssertFalse(AccountAvailability.isUsable(card(always: [week]), now: now))

        // An independent pool shows its own exhausted message but leaves the account usable.
        let spark = row(meter("Spark Weekly", used: 100), limit: "sparkWeekly")
        XCTAssertEqual(spark.data.exhaustedWeeklyTitle, "Spark Usage Exhausted")
        XCTAssertFalse(AccountAvailability.isExhausted([spark, row(meter(used: 20), limit: "weekly")]))
        XCTAssertFalse(AccountAvailability.isExhausted([row(meter("Session", used: 100), limit: "session")]))
    }
}
