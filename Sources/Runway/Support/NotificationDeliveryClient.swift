import UserNotifications

/// The system boundary for notification delivery. Tests supply a recording client without
/// authorization prompts or real notifications; AppNotifications still owns delivery policy.
@MainActor
protocol NotificationDeliveryClient {
    func authorizationStatus() async -> UNAuthorizationStatus
    func requestAuthorization() async throws -> Bool
    func add(_ request: UNNotificationRequest) async throws
    func removePending(identifiers: [String])
    func removeDelivered(identifiers: [String])
}

@MainActor
struct SystemNotificationDeliveryClient: NotificationDeliveryClient {
    let centerProvider: @Sendable () -> UNUserNotificationCenter

    func authorizationStatus() async -> UNAuthorizationStatus {
        await centerProvider().notificationSettings().authorizationStatus
    }

    func requestAuthorization() async throws -> Bool {
        try await centerProvider().requestAuthorization(options: [.alert, .sound])
    }

    func add(_ request: UNNotificationRequest) async throws {
        try await centerProvider().add(request)
    }

    func removePending(identifiers: [String]) {
        centerProvider().removePendingNotificationRequests(withIdentifiers: identifiers)
    }

    func removeDelivered(identifiers: [String]) {
        centerProvider().removeDeliveredNotifications(withIdentifiers: identifiers)
    }
}
