import Foundation
import UserNotifications
@testable import Runway

@MainActor
final class RecordingNotificationClient: NotificationDeliveryClient {
    var status: UNAuthorizationStatus = .authorized
    var authorizationRequests = 0
    var authorize: (@MainActor () async throws -> Bool)?
    var beforeAdd: (@MainActor (UNNotificationRequest) async throws -> Void)?
    var didAdd: (@MainActor () -> Void)?
    var didRemove: (@MainActor () -> Void)?
    var requests: [UNNotificationRequest] = []
    var delivered: [String: UNNotificationRequest] = [:]
    var removedPending: [String] = []
    var removedDelivered: [String] = []

    func authorizationStatus() async -> UNAuthorizationStatus { status }

    func requestAuthorization() async throws -> Bool {
        authorizationRequests += 1
        let granted = try await authorize?() ?? true
        status = granted ? .authorized : .denied
        return granted
    }

    func add(_ request: UNNotificationRequest) async throws {
        try await beforeAdd?(request)
        requests.append(request)
        // Apple's documented identifier semantics: a successful add replaces the delivered alert.
        delivered[request.identifier] = request
        didAdd?()
    }

    func removePending(identifiers: [String]) {
        removedPending += identifiers
    }

    func removeDelivered(identifiers: [String]) {
        removedDelivered += identifiers
        for id in identifiers { delivered.removeValue(forKey: id) }
        didRemove?()
    }
}
