import XCTest
@testable import Runway

/// Covers `MenuBarContentBuilder`: it resolves pinned provider groups into Text groups (order, labels,
/// and values preserved) and Bars entries (bounded metrics only, first four in order), and reports empty
/// when nothing is pinned.
@MainActor
final class MenuBarContentTests: XCTestCase {
    func testExhaustedAccountKeepsDimIconWithoutValuesAndRestores() {
        let session = percent("a.session", "Session", 20)
        let weekly = percent("a.weekly", "Weekly", 100).exportingLimit("weekly", unit: "percent")
        let other = percent("b.weekly", "Weekly", 10).exportingLimit("weekly", unit: "percent")
        let groups = [group("a", session), group("b", other)]
        let exhausted = MenuBarContentBuilder.build(groups: groups, data: { $0.sample },
                                                    quotaDescriptors: { $0 == "a" ? [weekly] : [other] })
        XCTAssertFalse(exhausted.isEmpty)
        XCTAssertTrue(exhausted.groups[0].isExhausted)
        XCTAssertTrue(exhausted.groups[0].metrics.isEmpty)
        XCTAssertFalse(exhausted.groups[1].isExhausted)
        XCTAssertEqual(exhausted.bars.map(\.id), [other.id])
        XCTAssertTrue(exhausted.accessibilityText.contains("Usage Exhausted"))
        let resetWeekly = percent("a.weekly", "Weekly", 0).exportingLimit("weekly", unit: "percent")
        let restored = MenuBarContentBuilder.build(groups: groups, data: { $0.sample },
                                                   quotaDescriptors: { $0 == "a" ? [resetWeekly] : [other] })
        XCTAssertFalse(restored.groups[0].isExhausted)
        XCTAssertEqual(restored.groups[0].metrics.map(\.id), [session.id])
        XCTAssertFalse(exhausted.isRenderEquivalent(to: restored, style: .text))
        XCTAssertFalse(exhausted.isRenderEquivalent(to: restored, style: .bars))
        let iconOnly = MenuBarContentBuilder.build(groups: [group("a", weekly)], data: { $0.sample })
        XCTAssertNotNil(MenuBarStripRenderer.image(for: iconOnly, style: .text))
        XCTAssertNotNil(MenuBarStripRenderer.image(for: iconOnly, style: .bars))
    }

    func testIndependentPoolDoesNotDimUsablePinnedPool() {
        let session = percent("a.session", "Session", 10).exportingLimit("geminiSession", unit: "percent")
        let weekly = percent("a.weekly", "Weekly", 100).exportingLimit("geminiWeekly", unit: "percent")
        let other = percent("a.other", "Claude Session", 10).exportingLimit("nonGeminiSession", unit: "percent")
        let mixed = MenuBarContentBuilder.build(groups: [group("a", session, other)], data: { $0.sample },
                                               quotaDescriptors: { _ in [weekly] })
        XCTAssertFalse(mixed.groups[0].isExhausted)
        let exhausted = MenuBarContentBuilder.build(groups: [group("a", session)], data: { $0.sample },
                                                   quotaDescriptors: { _ in [weekly] })
        XCTAssertTrue(exhausted.groups[0].isExhausted)
        let missingWeekly = noDataPercent("a.weekly", "Weekly").exportingLimit("weekly", unit: "percent")
        let unknown = MenuBarContentBuilder.build(groups: [group("a", session)], data: { $0.sample },
                                                 quotaDescriptors: { _ in [missingWeekly] })
        XCTAssertFalse(unknown.groups[0].isExhausted)
    }

    func testLoginFailureKeepsPinnedIconWithNoDataOrCachedValues() {
        for metric in [noDataPercent("a.weekly", "Weekly"), percent("a.weekly", "Weekly", 25)] {
            let content = MenuBarContentBuilder.build(groups: [group("a", metric)], data: { $0.sample },
                                                      loginRequired: { _ in true })
            XCTAssertFalse(content.isEmpty)
            XCTAssertTrue(content.groups[0].isDimmed)
            XCTAssertTrue(content.groups[0].metrics.isEmpty)
            XCTAssertTrue(content.bars.isEmpty)
            XCTAssertTrue(content.accessibilityText.contains("Login Required"))
            XCTAssertNotNil(MenuBarStripRenderer.image(for: content, style: .text))
            XCTAssertNotNil(MenuBarStripRenderer.image(for: content, style: .bars))
        }
        XCTAssertTrue(MenuBarContentBuilder.build(groups: [], data: { $0.sample },
                                                  loginRequired: { _ in true }).isEmpty)
    }

    func testExhaustedUnpinnedWeeklyPreservesIconWhenOnlyPinHasNoData() {
        let session = noDataPercent("a.session", "Session")
        let weekly = percent("a.weekly", "Weekly", 100).exportingLimit("weekly", unit: "percent")
        let content = MenuBarContentBuilder.build(groups: [group("a", session)], data: { $0.sample },
                                                  quotaDescriptors: { _ in [weekly] })
        XCTAssertFalse(content.isEmpty)
        XCTAssertTrue(content.groups[0].isExhausted)
        XCTAssertTrue(content.groups[0].metrics.isEmpty)
    }

    func testDormantAndCappedPinsDoNotPreventIndependentPoolExhaustion() {
        let session = percent("a.session", "Session", 10).exportingLimit("geminiSession", unit: "percent")
        let weekly = percent("a.weekly", "Weekly", 100).exportingLimit("geminiWeekly", unit: "percent")
        let dormant = noDataPercent("a.claude", "Claude Session").exportingLimit("nonGeminiSession", unit: "percent")
        let dormantContent = MenuBarContentBuilder.build(groups: [group("a", session, dormant)], data: { $0.sample },
                                                         quotaDescriptors: { _ in [weekly] })
        XCTAssertTrue(dormantContent.groups[0].isExhausted)
        let cappedContent = MenuBarContentBuilder.build(
            groups: [group("a", session, weekly, percent("a.claude", "Claude Session", 10))], data: { $0.sample })
        XCTAssertTrue(cappedContent.groups[0].isExhausted)
    }

    func testEmptyWhenNoGroups() {
        let content = MenuBarContentBuilder.build(groups: [], data: { $0.sample })
        XCTAssertTrue(content.isEmpty)
        XCTAssertTrue(content.bars.isEmpty)
    }

    func testTextGroupsPreserveOrderLabelsAndValues() {
        let m1 = percent("a.m1", "Session", 97)
        let m2 = percent("a.m2", "Weekly", 12)
        let b1 = percent("b.m1", "Total", 50)
        let content = MenuBarContentBuilder.build(groups: [group("a", m1, m2), group("b", b1)], data: { $0.sample })

        XCTAssertEqual(content.groups.map(\.providerID), ["a", "b"])
        XCTAssertEqual(content.groups[0].metrics.map(\.id), ["a.m1", "a.m2"])
        XCTAssertEqual(content.groups[0].metrics[0].label, "Session")
        XCTAssertEqual(content.groups[0].metrics[0].value, m1.sample.valueText)
        XCTAssertEqual(content.groups[1].metrics.map(\.id), ["b.m1"])
    }

    func testBarsIncludeBoundedMetricsAndDropUnbounded() {
        // A bounded dollar metric has a fill, so it belongs in Bars. An unbounded value (raw spend,
        // no limit) has no fill and is dropped.
        let content = MenuBarContentBuilder.build(
            groups: [
                group("a",
                    percent("a.pct", "Pct", 40),
                    boundedDollars("a.credits", "Credits", used: 12000, limit: 18000)),
                group("b", unbounded("b.spend", "Spend"))
            ],
            data: { $0.sample }
        )

        XCTAssertEqual(content.groups.flatMap(\.metrics).map(\.id), ["a.pct", "a.credits", "b.spend"]) // Text: all
        XCTAssertEqual(content.bars.map(\.id), ["a.pct", "a.credits"])                                 // Bars: bounded only
    }

    func testBarsCappedToFourInOrder() {
        let content = MenuBarContentBuilder.build(
            groups: [
                group("a", percent("a.m1", "M1", 10), percent("a.m2", "M2", 20)),
                group("b", percent("b.m1", "M1", 30), percent("b.m2", "M2", 40)),
                group("c", percent("c.m1", "M1", 50), percent("c.m2", "M2", 60))
            ],
            data: { $0.sample }
        )

        XCTAssertEqual(content.bars.count, 4)
        XCTAssertEqual(content.bars.map(\.id), ["a.m1", "a.m2", "b.m1", "b.m2"])
    }

    func testNoDataMetricsDropFromStrip() {
        // The strip is dynamic: a pinned metric without data vanishes instead of rendering "—", and
        // the surviving pin renders alone (full size). A provider whose pins all lack data
        // contributes no icon at all.
        let content = MenuBarContentBuilder.build(
            groups: [
                group("a", percent("a.live", "Session", 41), noDataPercent("a.dark", "Weekly")),
                group("b", noDataPercent("b.nd", "ND"))
            ],
            data: { $0.sample }
        )

        XCTAssertEqual(content.groups.map(\.providerID), ["a"])
        XCTAssertEqual(content.groups[0].metrics.map(\.id), ["a.live"])
        XCTAssertEqual(content.bars.map(\.id), ["a.live"])
    }

    func testTextGroupReappliesTwoMetricCapAfterDormantPinsBecomeLive() {
        let content = MenuBarContentBuilder.build(
            groups: [group(
                "a",
                percent("a.m1", "M1", 10),
                percent("a.m2", "M2", 20),
                percent("a.m3", "M3", 30)
            )],
            data: { $0.sample }
        )

        XCTAssertEqual(content.groups[0].metrics.map(\.id), ["a.m1", "a.m2"])
    }

    func testNoDataPinDoesNotConsumeReappliedTextCap() {
        let content = MenuBarContentBuilder.build(
            groups: [group(
                "a",
                noDataPercent("a.dormant", "Dormant"),
                percent("a.m2", "M2", 20),
                percent("a.m3", "M3", 30)
            )],
            data: { $0.sample }
        )

        XCTAssertEqual(content.groups[0].metrics.map(\.id), ["a.m2", "a.m3"])
    }

    func testAllPinsWithoutDataFallBackToAppIcon() {
        let content = MenuBarContentBuilder.build(
            groups: [group("a", noDataPercent("a.nd", "ND"))],
            data: { $0.sample }
        )
        XCTAssertTrue(content.isEmpty)
    }

    func testAccessibilityTextSummarizesGroups() {
        let content = MenuBarContentBuilder.build(
            groups: [group("a", percent("a.m1", "Session", 41), percent("a.m2", "Weekly", 12))],
            data: { $0.sample }
        )
        XCTAssertEqual(content.accessibilityText, "A Session 41%, Weekly 12%")
    }

    func testAccessibilityTextUsesTheResolvedTitle() {
        // The VoiceOver summary is a human-facing name, so it goes through the caller's resolver
        // (the account registry) instead of the baked provider name.
        let content = MenuBarContentBuilder.build(
            groups: [group("a", percent("a.m1", "Session", 41))],
            data: { $0.sample },
            title: { _ in "Claude Team" }
        )
        XCTAssertEqual(content.accessibilityText, "Claude Team Session 41%")
    }

    func testTrayLabelsShortenLongTimeWindows() {
        let content = MenuBarContentBuilder.build(
            groups: [group("a", percent("a.today", "Today", 5), percent("a.month", "Last 30 Days", 80))],
            data: { $0.sample }
        )
        XCTAssertEqual(content.groups[0].metrics.map(\.label), ["T", "M"])
    }

    func testBoundedTrayValuesStayUnitAware() {
        // Percent meters still read as percentages, while bounded dollars/counts keep their natural
        // unit in the strip instead of collapsing to "used / limit" percentages.
        let usage = percent("a.usage", "Usage", 67)
        let credits = boundedDollars("a.credits", "Credits", used: 12000, limit: 18000)
        let requests = boundedCount("b.requests", "Requests", used: 412, limit: 500)
        let spend = unbounded("b.spend", "Spend")   // unbounded $42
        let content = MenuBarContentBuilder.build(
            groups: [group("a", usage, credits), group("b", requests, spend)],
            data: { $0.sample }
        )

        XCTAssertEqual(content.groups.flatMap(\.metrics).map(\.value), ["67%", "$12K", "412", "$42"])
    }

    func testUnboundedNumbersAreCompacted() {
        // Standard compact notation for big numbers; values shown in full drop their decimals.
        let content = MenuBarContentBuilder.build(
            groups: [group("a",
                unbounded("a.big", "Big", 12923),         // → $12.9K
                unbounded("a.small", "Small", 129.81))],  // → $130 (no decimals)
            data: { $0.sample }
        )

        let big = content.groups[0].metrics[0].value
        XCTAssertTrue(big.hasSuffix("K"), "expected compact thousands, got \(big)")
        XCTAssertFalse(big.contains("923"), "expected the raw number to be compacted away, got \(big)")
        XCTAssertEqual(content.groups[0].metrics[1].value, "$130")
    }

    // MARK: - Fixtures

    private func group(_ providerID: String, _ metrics: WidgetDescriptor...) -> ProviderMetrics {
        let provider = Provider(
            id: providerID,
            displayName: providerID.uppercased(),
            icon: .providerMark("cursor")
        )
        return ProviderMetrics(provider: provider, metrics: metrics)
    }

    private func percent(_ id: String, _ label: String, _ used: Double) -> WidgetDescriptor {
        descriptor(id, label, WidgetData(title: label, icon: .providerMark("cursor"), kind: .percent, used: used, limit: 100))
    }

    private func boundedDollars(_ id: String, _ label: String, used: Double, limit: Double) -> WidgetDescriptor {
        descriptor(id, label, WidgetData(title: label, icon: .providerMark("cursor"), kind: .dollars, used: used, limit: limit))
    }

    private func boundedCount(_ id: String, _ label: String, used: Double, limit: Double) -> WidgetDescriptor {
        descriptor(id, label, WidgetData(title: label, icon: .providerMark("cursor"), kind: .count, used: used, limit: limit))
    }

    private func unbounded(_ id: String, _ label: String, _ used: Double = 42) -> WidgetDescriptor {
        descriptor(id, label, WidgetData(title: label, icon: .providerMark("cursor"), kind: .dollars, used: used, limit: nil))
    }

    private func noDataPercent(_ id: String, _ label: String) -> WidgetDescriptor {
        var sample = WidgetData(title: label, icon: .providerMark("cursor"), kind: .percent, used: 0, limit: 100)
        sample.hasData = false
        return descriptor(id, label, sample)
    }

    private func descriptor(_ id: String, _ label: String, _ sample: WidgetData) -> WidgetDescriptor {
        WidgetDescriptor(
            id: id,
            providerID: String(id.prefix { $0 != "." }),
            metricLabel: label,
            sample: sample
        )
    }
}
