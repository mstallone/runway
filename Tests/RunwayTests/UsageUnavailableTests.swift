import SwiftUI
import XCTest
@testable import Runway

@MainActor
final class UsageUnavailableTests: XCTestCase {
    private let provider = Provider(id: "test", displayName: "Test", icon: .providerMark("claude"))

    private var session: WidgetDescriptor {
        .percent(id: "test.session", provider: provider, title: "Session")
    }

    private var weekly: WidgetDescriptor {
        .percent(id: "test.weekly", provider: provider, title: "Weekly")
    }

    private var spend: WidgetDescriptor {
        WidgetDescriptor(id: "test.today", providerID: provider.id, metricLabel: "Today",
                         sample: WidgetData(title: "Today", icon: provider.icon, kind: .dollars, used: 0))
    }

    private func store(first: ProviderSnapshot, second: ProviderSnapshot? = nil) -> WidgetDataStore {
        let defaults = UserDefaults(suiteName: "UsageUnavailableTests.\(UUID().uuidString)")!
        let descriptors = [session, weekly, spend]
        let runtime = TogglingProviderRuntime(provider: provider, descriptors: descriptors,
                                             first: first, second: second ?? first)
        return WidgetDataStore(
            registry: WidgetRegistry(providers: [provider], descriptors: descriptors),
            providers: [runtime],
            cache: ProviderSnapshotCache(userDefaults: defaults, storageKey: "snapshots"),
            defaults: defaults
        )
    }

    func testWarningOnlyLoginFailureCollapsesEmptyBarsAndRecovers() async {
        let warning = ClaudeAuthError.notLoggedIn.localizedDescription
        let first = ProviderSnapshot(providerID: provider.id, displayName: provider.displayName,
                                     lines: [.noUsageData], warning: warning, loginRequired: true)
        let second = ProviderSnapshot(providerID: provider.id, displayName: provider.displayName,
                                      lines: [.progress(label: "Session", used: 0, limit: 100, format: .percent)])
        let store = store(first: first, second: second)
        await store.refreshAll(force: true)
        XCTAssertNil(store.errorMessage(for: provider.id), "this arrives as a partial success, not a hard error")
        XCTAssertEqual(store.usageUnavailableMessage(for: provider.id, placedDescriptors: [session]), warning)
        XCTAssertFalse(store.data(for: session).hasData)

        await store.refreshAll(force: true)
        XCTAssertNil(store.usageUnavailableMessage(for: provider.id, placedDescriptors: [session]))
        XCTAssertTrue(store.data(for: session).hasData, "zero usage is real data and restores the bar")
    }

    func testLocalSpendDoesNotMaskUnavailableQuotaBars() async {
        let warning = "Login Needs Renewal. Open Claude Code, then refresh."
        let snapshot = ProviderSnapshot(
            providerID: provider.id, displayName: provider.displayName,
            lines: [.values(label: "Today", values: [MetricValue(number: 4, kind: .dollars)])],
            warning: warning
        )
        let store = store(first: snapshot)
        await store.refreshAll(force: true)
        XCTAssertEqual(store.usageUnavailableMessage(for: provider.id, placedDescriptors: [session, spend]), warning)
        XCTAssertTrue(store.data(for: spend).hasData)
        XCTAssertEqual(store.data(for: spend).values.first?.number, 4)
        XCTAssertNil(store.usageUnavailableMessage(for: provider.id, placedDescriptors: [spend]),
                     "a hidden quota bar must not add a message to a working spend-only card")
    }

    func testConnectAndWaitNoticesKeepTheirActions() async {
        for isConnect in [true, false] {
            let warning = isConnect ? "Login found. Connect to load it." : "Updates blocked. Wait before retrying."
            let snapshot = ProviderSnapshot(
                providerID: provider.id, displayName: provider.displayName,
                lines: [.noUsageData], warning: warning,
                warningAction: isConnect ? .refresh : .wait,
                warningIsConnectPrompt: isConnect
            )
            let store = store(first: snapshot)
            await store.refreshAll(force: true)
            XCTAssertEqual(store.usageUnavailableMessage(for: provider.id, placedDescriptors: [session]), warning)
            XCTAssertEqual(store.noticeIsConnectPrompt(for: provider.id), isConnect)
            XCTAssertEqual(store.headerNoticeAction(for: provider.id), isConnect ? .refresh : .wait)
        }
    }

    func testMissingDataWithoutFailureAndEmptySpendPeriodsDoNotBecomeErrors() async {
        let empty = ProviderSnapshot(providerID: provider.id, displayName: provider.displayName, lines: [.noUsageData])
        let store = store(first: empty)
        await store.refreshAll(force: true)
        XCTAssertNil(store.usageUnavailableMessage(for: provider.id, placedDescriptors: [session, spend]))

        let partial = ProviderSnapshot(
            providerID: provider.id, displayName: provider.displayName,
            lines: [.progress(label: "Session", used: 20, limit: 100, format: .percent)],
            warning: "Some history is unavailable. Try again later."
        )
        let partialStore = self.store(first: partial)
        await partialStore.refreshAll(force: true)
        XCTAssertNil(partialStore.usageUnavailableMessage(for: provider.id, placedDescriptors: [session, spend]))
    }

    func testNoticeKeepsSavedOnDemandRowsAfterUpstreamPromotion() async throws {
        // Cover both promotion paths: every enabled metric is On Demand, or applicability
        // removes the only Always Visible metric. Available spend must stay behind the caret.
        for filtersAlwaysVisible in [false, true] {
            let applicable = Set([weekly.id, spend.id])
            let first = ProviderSnapshot(
                providerID: provider.id, displayName: provider.displayName,
                lines: [.values(label: "Today", values: [MetricValue(number: 4, kind: .dollars)])],
                applicableMetricIDs: applicable,
                warning: "Usage unavailable. Try again later."
            )
            let second = ProviderSnapshot(
                providerID: provider.id, displayName: provider.displayName,
                lines: [
                    .progress(label: "Weekly", used: 20, limit: 100, format: .percent),
                    .values(label: "Today", values: [MetricValue(number: 4, kind: .dollars)]),
                ],
                applicableMetricIDs: applicable
            )
            let dataStore = store(first: first, second: second)
            let defaults = UserDefaults(suiteName: "UsageUnavailableLayout.\(UUID().uuidString)")!
            let layout = LayoutStore(
                registry: WidgetRegistry(providers: [provider], descriptors: [session, weekly, spend]),
                defaults: defaults,
                defaultMetricIDs: filtersAlwaysVisible ? [session.id, weekly.id, spend.id] : [weekly.id, spend.id],
                defaultPinnedMetricIDs: [],
                defaultExpandedMetricIDs: [weekly.id, spend.id]
            )
            let savedOrder = layout.metricOrder(for: provider.id)
            let savedExpanded = layout.expandedMetricIDs

            await dataStore.refreshAll(force: true)
            let group = try XCTUnwrap(layout.dashboardGroups(dataStore: dataStore).first)
            XCTAssertTrue(group.alwaysShownWidgets.isEmpty)
            XCTAssertEqual(group.expandedWidgets.map(\.descriptorID), [weekly.id, spend.id])
            XCTAssertNotNil(dataStore.usageUnavailableMessage(for: provider.id, placedDescriptors: [weekly, spend]))

            await dataStore.refreshAll(force: true)
            let recovered = try XCTUnwrap(layout.dashboardGroups(dataStore: dataStore).first)
            XCTAssertEqual(recovered.alwaysShownWidgets.map(\.descriptorID), [weekly.id, spend.id],
                           "without a notice, normal promotion still prevents a blank card")
            XCTAssertTrue(recovered.expandedWidgets.isEmpty)
            XCTAssertEqual(layout.metricOrder(for: provider.id), savedOrder)
            XCTAssertEqual(layout.expandedMetricIDs, savedExpanded)
        }
    }

    func testCompactCardIsShorterThanEmptyBarsAndPreservesAvailableRows() throws {
        let emptyRows = ["Session", "Weekly", "Fable"].map { title in
            var data = WidgetData(title: title, icon: provider.icon, kind: .percent, used: 0, limit: 100)
            data.hasData = false
            return data
        }
        let warning = ClaudeAuthError.notLoggedIn.localizedDescription
        for appearance in [ColorScheme.light, .dark] {
            let empty = ShareCardView(provider: provider, rows: emptyRows, appearance: appearance)
            let compact = ShareCardView(provider: provider, rows: [], appearance: appearance, errorMessage: warning)
            let withSpend = ShareCardView(provider: provider, rows: [spend.sample], appearance: appearance,
                                          errorMessage: warning)
            let emptyImage = try XCTUnwrap(ShareCardRenderer.image(for: empty))
            let compactImage = try XCTUnwrap(ShareCardRenderer.image(for: compact))
            let spendImage = try XCTUnwrap(ShareCardRenderer.image(for: withSpend))
            XCTAssertLessThan(compactImage.size.height, emptyImage.size.height)
            XCTAssertGreaterThan(spendImage.size.height, compactImage.size.height,
                                 "the warning must not replace available spend rows in exports")
        }
    }
}
