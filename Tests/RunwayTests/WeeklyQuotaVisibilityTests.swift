import XCTest
@testable import Runway

@MainActor
final class WeeklyQuotaVisibilityTests: XCTestCase {
    func testExhaustedPresentationPreservesQuotaAndRestoresMeter() {
        let provider = ClaudeProvider().provider
        let weekly = WidgetDescriptor.percent(id: "claude.weekly", provider: provider, title: "Weekly")
            .exportingLimit("weekly", unit: "percent")
        var data = WidgetData(title: "Weekly", icon: weekly.sample.icon, kind: .percent,
                              used: 100, limit: 100)
        let exhausted = WeeklyQuotaVisibility.presentation(data, descriptor: weekly)
        XCTAssertEqual(exhausted.exhaustedWeeklyTitle, "Usage Exhausted")
        XCTAssertEqual(exhausted.exhaustedWeeklyResetText, "Reset Time Unavailable")
        XCTAssertEqual(exhausted.used, 100)
        XCTAssertEqual(exhausted.limit, 100)
        data.resetsAt = Date(timeIntervalSince1970: 1_800_000_000)
        let dated = WeeklyQuotaVisibility.presentation(data, descriptor: weekly)
        let reset = data.resetsAt!
        let exactDate = reset.formatted(.dateTime.month(.abbreviated).day())
            + " at " + TimeFormatSetting.current.shortTime(reset)
        for (seconds, expected) in [(190_800.0, "Resets in 2d 5h"), (10_800.0, "Resets in 3h"),
                                    (1_200.0, "Resets in 20m"), (60.0, "Resets soon"),
                                    (-60.0, "Resets soon")] {
            XCTAssertEqual(dated.exhaustedWeeklyResetText(now: reset.addingTimeInterval(-seconds)),
                           "\(expected) · \(exactDate)")
        }
        let restored = WidgetData(title: "Weekly", icon: weekly.sample.icon, kind: .percent,
                                  used: 99.9, limit: 100)
        XCTAssertNil(WeeklyQuotaVisibility.presentation(restored, descriptor: weekly).exhaustedWeeklyTitle)
        data.hasData = false
        XCTAssertNil(WeeklyQuotaVisibility.presentation(data, descriptor: weekly).exhaustedWeeklyTitle)
    }

    func testModelPoolSummaryKeepsItsIdentity() {
        let provider = AntigravityProvider().provider
        let weekly = WidgetDescriptor.percent(id: "test.weekly", provider: provider, title: "Weekly")
            .exportingLimit("geminiWeekly", unit: "percent")
        let data = WidgetData(title: "Weekly", icon: weekly.sample.icon, kind: .percent,
                              used: 100, limit: 100)
        XCTAssertEqual(WeeklyQuotaVisibility.presentation(data, descriptor: weekly).exhaustedWeeklyTitle,
                       "Gemini Usage Exhausted")
    }

    func testExhaustionHidesBarsAndRefreshRestoresSavedOrder() {
        let provider = ClaudeProvider().provider
        let metrics = ["session", "weekly", "fable", "extraUsage"].map {
            WidgetDescriptor.percent(id: "\(provider.id).\($0)", provider: provider, title: $0)
                .exportingLimit($0, unit: "percent")
        }
        let widgets = metrics.map { PlacedWidget(descriptorID: $0.id) }
        let group = ProviderGroup(provider: provider, alwaysShownWidgets: Array(widgets.prefix(3)),
                                  expandedWidgets: [widgets[3]])
        var weeklyUsage = 100.0
        let resolve: (WidgetDescriptor) -> WidgetData = { metric in
            WidgetData(title: metric.title, icon: metric.sample.icon, kind: .percent,
                       used: metric.id.hasSuffix(".weekly") ? weeklyUsage : 20, limit: 100)
        }
        func filtered() -> ProviderGroup {
            WeeklyQuotaVisibility.filter(group, descriptor: { widget in
                metrics.first { $0.id == widget.descriptorID }
            }, data: resolve)
        }
        XCTAssertEqual(filtered().alwaysShownWidgets.map(\.descriptorID), [metrics[1].id])
        XCTAssertEqual(filtered().expandedWidgets.map(\.descriptorID), [metrics[3].id])
        weeklyUsage = 99.9
        XCTAssertEqual(filtered().alwaysShownWidgets.map(\.descriptorID), widgets.prefix(3).map(\.descriptorID))
        weeklyUsage = 105
        XCTAssertEqual(filtered().alwaysShownWidgets.count, 1)
    }

    func testMissingWeeklyDataAndWeeklyOnDemandDoNotHideRows() {
        let provider = ClaudeProvider().provider
        let session = WidgetDescriptor.percent(id: "claude.session", provider: provider, title: "Session")
        let weekly = WidgetDescriptor.percent(id: "claude.weekly", provider: provider, title: "Weekly")
            .exportingLimit("weekly", unit: "percent")
        let widgets = [session, weekly].map { PlacedWidget(descriptorID: $0.id) }
        for onDemand in [false, true] {
            let group = ProviderGroup(provider: provider,
                                      alwaysShownWidgets: onDemand ? [widgets[0]] : widgets,
                                      expandedWidgets: onDemand ? [widgets[1]] : [])
            let filtered = WeeklyQuotaVisibility.filter(group, descriptor: {
                $0.descriptorID == session.id ? session : weekly
            }, data: { metric in
                var value = WidgetData(title: metric.title, icon: metric.sample.icon, kind: .percent,
                                       used: 100, limit: 100)
                value.hasData = onDemand
                return value
            })
            XCTAssertEqual(filtered.alwaysShownWidgets.map(\.descriptorID), group.alwaysShownWidgets.map(\.descriptorID))
            XCTAssertEqual(filtered.expandedWidgets.map(\.descriptorID), group.expandedWidgets.map(\.descriptorID))
        }
    }

    func testIndependentPoolsAndUnboundedRowsStayVisible() {
        let provider = AntigravityProvider().provider
        let keys = ["geminiSession", "geminiWeekly", "nonGeminiSession", "nonGeminiWeekly", "balance"]
        let metrics = keys.map {
            WidgetDescriptor.percent(id: "test.\($0)", provider: provider, title: $0)
                .exportingLimit($0, unit: "percent")
        }
        let group = ProviderGroup(provider: provider,
                                  alwaysShownWidgets: metrics.map { PlacedWidget(descriptorID: $0.id) },
                                  expandedWidgets: [])
        let result = WeeklyQuotaVisibility.filter(group, descriptor: { widget in
            metrics.first { $0.id == widget.descriptorID }
        }, data: { metric in
            WidgetData(title: metric.title, icon: metric.sample.icon, kind: .percent,
                       used: metric.title == "geminiWeekly" ? 100 : 10,
                       limit: metric.title == "balance" ? nil : 100)
        })
        XCTAssertEqual(result.alwaysShownWidgets.map(\.descriptorID), metrics.dropFirst().map(\.id))
    }
}
