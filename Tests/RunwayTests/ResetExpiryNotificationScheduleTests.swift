import XCTest
@testable import Runway

@MainActor
final class ResetExpiryNotificationScheduleTests: XCTestCase {
    private let expiry = Date(timeIntervalSince1970: 2_000_000_000)

    private func next(remaining: TimeInterval, cached: Bool = false, retry: Bool = false) -> Date? {
        ResetExpiryNotificationMonitor.nextWakeDate(
            metrics: [.init(key: "codex", providerName: "Codex", expiries: [expiry], canNotify: !cached)],
            enabled: true, after: expiry.addingTimeInterval(-remaining), retryDelivery: retry
        )
    }

    func testSleepsUntilTheNextMilestoneThenUntilExpiry() {
        XCTAssertEqual(next(remaining: 72 * 3600), expiry.addingTimeInterval(-48 * 3600))
        XCTAssertEqual(next(remaining: 48 * 3600), expiry.addingTimeInterval(-24 * 3600))
        XCTAssertEqual(next(remaining: 24 * 3600), expiry.addingTimeInterval(-2 * 3600))
        XCTAssertEqual(next(remaining: 2 * 3600), expiry.addingTimeInterval(-3600))
        XCTAssertEqual(next(remaining: 3600), expiry.addingTimeInterval(-900))
        XCTAssertEqual(next(remaining: 900), expiry)
        XCTAssertNil(next(remaining: 0))
    }

    func testNoTimerWhenDisabledOrNoCreditsExist() {
        XCTAssertNil(ResetExpiryNotificationMonitor.nextWakeDate(
            metrics: [.init(key: "grok", providerName: "Grok", expiries: [expiry])],
            enabled: false, after: expiry.addingTimeInterval(-3600), retryDelivery: true
        ))
        XCTAssertNil(ResetExpiryNotificationMonitor.nextWakeDate(metrics: [], enabled: true, after: Date()))
    }

    func testCachedCreditsOnlyScheduleExpiryUntilRevalidated() {
        XCTAssertEqual(next(remaining: 72 * 3600, cached: true), expiry)
    }

    func testEarliestDeadlineAcrossProvidersWins() {
        let now = expiry.addingTimeInterval(-3600)
        XCTAssertEqual(ResetExpiryNotificationMonitor.nextWakeDate(
            metrics: [
                .init(key: "codex", providerName: "Codex", expiries: [expiry]),
                .init(key: "grok", providerName: "Grok", expiries: [now.addingTimeInterval(60)])
            ], enabled: true, after: now
        ), now.addingTimeInterval(60))
    }

    func testFailedDeliveryRetriesWithoutDelayingAnEarlierMilestoneOrExpiry() {
        XCTAssertEqual(next(remaining: 3600, retry: true), expiry.addingTimeInterval(-3300))
        XCTAssertEqual(next(remaining: 901, retry: true), expiry.addingTimeInterval(-900))
        XCTAssertEqual(next(remaining: 60, retry: true), expiry)
    }

}
