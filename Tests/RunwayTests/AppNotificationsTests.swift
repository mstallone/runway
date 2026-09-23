import XCTest
import UserNotifications
@testable import Runway

/// Exercise the delivery policy with a recording client, and keep the production client inert
/// under XCTest so tests can never raise system prompts or post real notifications.
@MainActor
final class AppNotificationsTests: XCTestCase {
    func testIsRunningUnderTestsIsTrueInTheHarness() {
        XCTAssertTrue(AppNotifications.isRunningUnderTests)
    }

    func testShowHandlerIsInvokedByShow() {
        var opened = false
        MenuBarPopover.showHandler = { opened = true }
        defer { MenuBarPopover.showHandler = nil }
        MenuBarPopover.show()
        XCTAssertTrue(opened)
    }

    func testPostIsANoOpUnderTestsAndNeverTouchesTheCenter() async {
        let probe = CenterProbe()
        let notifications = AppNotifications(centerProvider: {
            probe.touched = true
            return UNUserNotificationCenter.current()
        })
        _ = await notifications.post(idPrefix: "claude.session.healthyToClose", title: "Cutting It Close", subtitle: "Claude Session", body: "x")
        _ = await notifications.post(idPrefix: "reset-expiry", title: "Reset Expiring Soon", subtitle: "Codex", body: "x", replacingIdentifier: "reset-1")
        notifications.remove(identifiers: ["reset-1"])
        notifications.registerAsDelegate()
        let authorized = await notifications.requestAuthorization().value
        XCTAssertFalse(authorized)
        XCTAssertFalse(probe.touched, "Under tests, no notification path should reach the center provider")
    }

    private func post(_ notifications: AppNotifications, body: String = "48 hours") async -> Bool {
        await notifications.post(idPrefix: "reset", title: "Reset Expiring Soon", subtitle: "Codex",
                                 body: body, replacingIdentifier: "reset-1")
    }

    func testPermissionChangesAreRecheckedForEachDelivery() async {
        let client = RecordingNotificationClient()
        let notifications = AppNotifications(client: client)
        let first = await post(notifications)
        XCTAssertTrue(first)
        client.status = .denied
        let denied = await post(notifications, body: "24 hours")
        XCTAssertFalse(denied)
        XCTAssertEqual(client.requests.count, 1)
        client.status = .authorized
        let retried = await post(notifications, body: "24 hours")
        XCTAssertTrue(retried)
        XCTAssertEqual(client.requests.count, 2)
        XCTAssertEqual(client.authorizationRequests, 0)
    }

    func testFailedReplacementPreservesPreviousAlertAndCanRetry() async {
        let client = RecordingNotificationClient()
        let notifications = AppNotifications(client: client)
        _ = await post(notifications)
        client.beforeAdd = { _ in throw CocoaError(.fileWriteUnknown) }
        let failed = await post(notifications, body: "24 hours")
        XCTAssertFalse(failed)
        XCTAssertEqual(client.delivered["reset-1"]?.content.body, "48 hours")
        XCTAssertTrue(client.removedDelivered.isEmpty)
        client.beforeAdd = nil
        _ = await post(notifications, body: "24 hours")
        XCTAssertEqual(client.delivered.count, 1)
        XCTAssertEqual(client.delivered["reset-1"]?.content.body, "24 hours")
    }

    func testObsoleteReminderIsNotPostedAfterPermissionPrompt() async {
        let client = RecordingNotificationClient()
        client.status = .notDetermined
        let notifications = AppNotifications(client: client)
        let prompted = expectation(description: "Permission prompt")
        var permission: CheckedContinuation<Bool, Never>?
        var current = true
        client.authorize = {
            await withCheckedContinuation {
                permission = $0
                prompted.fulfill()
            }
        }
        let task = Task {
            await notifications.post(idPrefix: "reset", title: "Reset Expiring Soon", subtitle: "Codex",
                                     body: "15 minutes", shouldPost: { current })
        }
        await fulfillment(of: [prompted], timeout: 1)
        current = false
        permission?.resume(returning: true)
        let sent = await task.value
        XCTAssertFalse(sent)
        XCTAssertTrue(client.requests.isEmpty)
    }

    func testCancellationDuringPermissionPromptDoesNotDeliver() async {
        let client = RecordingNotificationClient()
        client.status = .notDetermined
        let notifications = AppNotifications(client: client)
        let prompted = expectation(description: "Permission prompt")
        var permission: CheckedContinuation<Bool, Never>?
        client.authorize = {
            await withCheckedContinuation {
                permission = $0
                prompted.fulfill()
            }
        }
        let task = Task { await self.post(notifications) }
        await fulfillment(of: [prompted], timeout: 1)
        task.cancel()
        permission?.resume(returning: true)
        let sent = await task.value
        XCTAssertFalse(sent)
        XCTAssertTrue(client.requests.isEmpty)
    }

    func testRemoveWithdrawsPendingAndDeliveredResetOnly() async {
        let client = RecordingNotificationClient()
        let notifications = AppNotifications(client: client)
        _ = await post(notifications)
        _ = await notifications.post(idPrefix: "pace", title: "Almost Out", subtitle: "Codex", body: "Low")
        notifications.remove(identifiers: ["reset-1"])
        XCTAssertEqual(client.removedPending, ["reset-1"])
        XCTAssertEqual(client.removedDelivered, ["reset-1"])
        XCTAssertEqual(client.delivered.count, 1)
        XCTAssertEqual(client.delivered.values.first?.content.title, "Almost Out")
    }

    func testCountdownIsFormattedAfterPermissionApproval() async {
        let client = RecordingNotificationClient()
        client.status = .notDetermined
        let notifications = AppNotifications(client: client)
        let expiry = Date(timeIntervalSince1970: 2_000_000_000)
        var now = expiry.addingTimeInterval(-20 * 3600)
        let reminder = ResetExpiryNotificationEvaluator.Reminder(
            metricKey: "codex", expiry: expiry, milestone: 24 * 3600, count: 1,
            identifier: "reset-1", title: "Reset Expiring Soon", subtitle: "Codex"
        )
        client.authorize = {
            now = expiry.addingTimeInterval(-3 * 3600)
            return true
        }
        _ = await notifications.post(idPrefix: "reset", title: reminder.title, subtitle: reminder.subtitle,
                                     body: reminder.body(now: now), replacingIdentifier: reminder.identifier)
        XCTAssertTrue(client.requests.first?.content.body.contains("in 3 hours") == true)
    }

    /// A tiny reference box so the `@Sendable` provider closure can record whether it ran.
    private final class CenterProbe: @unchecked Sendable {
        var touched = false
    }
}
