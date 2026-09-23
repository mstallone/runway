import AppKit
import Foundation
import UserNotifications

/// The single entry point for posting macOS user notifications. Quota alerts go through `post`;
/// authorization is requested when the user first enables a trigger (all default off), while `post`
/// also checks authorization before delivery.
///
/// Concurrent authorization checks share one task. Later deliveries read live settings, so a
/// permission change never consumes an undelivered milestone. The class is the delegate so
/// banners still show while the app is frontmost (a menu-bar accessory usually is).
@MainActor
final class AppNotifications: NSObject, UNUserNotificationCenterDelegate {
    static let shared = AppNotifications()

    private let centerProvider: @Sendable () -> UNUserNotificationCenter
    private let client: any NotificationDeliveryClient
    private let hasInjectedClient: Bool

    /// Only the in-flight check is shared; its result is never cached across deliveries.
    private var authorizationTask: Task<Bool, Never>?

    init(
        centerProvider: @escaping @Sendable () -> UNUserNotificationCenter = { UNUserNotificationCenter.current() },
        client: (any NotificationDeliveryClient)? = nil
    ) {
        self.centerProvider = centerProvider
        self.client = client ?? SystemNotificationDeliveryClient(centerProvider: centerProvider)
        self.hasInjectedClient = client != nil
        super.init()
    }

    /// True while running inside the XCTest harness, so a unit test never actually schedules a system
    /// notification or trips the authorization prompt. (No XCTest symbol is linked into the app target,
    /// so this is a runtime class lookup.)
    static var isRunningUnderTests: Bool {
        NSClassFromString("XCTestCase") != nil
    }

    /// Make this object the delegate at launch so banners can display while the app is frontmost. A
    /// no-op under tests; authorization remains on demand.
    func registerAsDelegate() {
        guard !Self.isRunningUnderTests else { return }
        centerProvider().delegate = self
    }

    /// Request notification authorization. Called when the first trigger is enabled and from the
    /// Settings "Allow Notifications" button when permission is still not determined.
    @discardableResult
    func requestAuthorization() -> Task<Bool, Never> {
        guard !Self.isRunningUnderTests || hasInjectedClient else { return Task { false } }
        return ensureAuthorization()
    }

    /// Open System Settings → Notifications so the user can re-enable alerts for Runway after a
    /// macOS-level denial (the app can't re-prompt once the system has cached a decision). No-op under
    /// tests.
    func openSystemNotificationsSettings() {
        guard !Self.isRunningUnderTests else { return }
        if let url = URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension") {
            NSWorkspace.shared.open(url)
        }
    }

    /// Post one immediate notification. `idPrefix` names the source (e.g. a metric key) for the log line;
    /// the actual identifier is made unique unless `replacingIdentifier` supplies a reset credit's
    /// stable identifier, which lets macOS replace its previous delivered alert. `title`
    /// is the alert headline, `subtitle` carries provider + metric, and `body` is the verdict. Returns
    /// whether it was actually delivered — false under tests, when not authorized, or when scheduling
    /// errors, so the caller can retry. Content and eligibility are evaluated after authorization,
    /// which may suspend while the user answers a permission prompt.
    func post(
        idPrefix: String, title: String, subtitle: String, body: @autoclosure @MainActor () -> String,
        soundEnabled: Bool = true, replacingIdentifier: String? = nil,
        shouldPost: @MainActor () -> Bool = { true }
    ) async -> Bool {
        guard !Self.isRunningUnderTests || hasInjectedClient else { return false }
        guard !Task.isCancelled, shouldPost() else { return false }
        guard await ensureAuthorization().value else {
            AppLog.debug(.notifications, "skip \(idPrefix): not authorized")
            return false
        }
        guard !Task.isCancelled, shouldPost() else { return false }
        let content = UNMutableNotificationContent()
        content.title = title
        content.subtitle = subtitle
        content.body = body()
        // Group all Runway alerts into one stacked thread so simultaneous alerts (e.g. a metric
        // that fires two milestones at once) collapse into a single banner with a "N more" summary
        // instead of separate banners.
        content.threadIdentifier = "runway"
        if soundEnabled { content.sound = .default }
        let id = replacingIdentifier ?? "runway-\(idPrefix)-\(UUID().uuidString)"
        let request = UNNotificationRequest(identifier: id, content: content, trigger: nil)
        do {
            // macOS replaces both delivered and pending notifications with this identifier.
            // Removing the old alert first would lose it if adding the replacement failed.
            try await client.add(request)
            AppLog.info(.notifications, "posted \(idPrefix)")
            return true
        } catch {
            AppLog.error(.notifications, "post \(idPrefix) failed: \(error.localizedDescription)")
            return false
        }
    }

    func remove(identifiers: [String]) {
        guard (!Self.isRunningUnderTests || hasInjectedClient), !identifiers.isEmpty else { return }
        client.removePending(identifiers: identifiers)
        client.removeDelivered(identifiers: identifiers)
    }

    #if DEBUG
    /// Explicit development preview through the same delivery path as real reset reminders.
    /// Its identifier is separate from real credits and it never changes reminder preferences/history.
    func previewResetExpiryNotification() async {
        guard !Self.isRunningUnderTests else { return }
        let expiry = Date().addingTimeInterval(15 * 60)
            .formatted(date: .abbreviated, time: .shortened)
        let sent = await post(
            idPrefix: "reset-expiry-preview", title: "Reset Expiring Soon",
            subtitle: "Codex · Rate Limit Resets",
            body: "Sample: An unused reset expires in 15 minutes (\(expiry)). Use before expiry.",
            replacingIdentifier: "runway-reset-expiry-preview"
        )
        let settings = await centerProvider().notificationSettings()
        AppLog.info(.notifications, "reset preview: sent=\(sent), authorization=\(settings.authorizationStatus.rawValue), alertStyle=\(settings.alertStyle.rawValue)")
        if !sent { openSystemNotificationsSettings() }
    }
    #endif

    // MARK: - Authorization

    /// The shared in-flight authorization task. Reads current settings, short-circuits a
    /// resolved (authorized/denied) state, and otherwise requests alert + sound permission.
    private func ensureAuthorization() -> Task<Bool, Never> {
        if let authorizationTask { return authorizationTask }
        let task = Task<Bool, Never> {
            defer { authorizationTask = nil }
            switch await client.authorizationStatus() {
            case .authorized, .provisional, .ephemeral:
                return true
            case .denied:
                AppLog.info(.notifications, "authorization denied")
                return false
            case .notDetermined:
                do {
                    let granted = try await client.requestAuthorization()
                    AppLog.info(.notifications, "authorization \(granted ? "granted" : "refused")")
                    return granted
                } catch {
                    AppLog.error(.notifications, "authorization request failed: \(error.localizedDescription)")
                    return false
                }
            @unknown default:
                return false
            }
        }
        authorizationTask = task
        return task
    }

    /// Current authorization status, for the Settings screen's denied-permission notice. Returns
    /// `.notDetermined` under tests.
    func authorizationStatus() async -> UNAuthorizationStatus {
        guard !Self.isRunningUnderTests || hasInjectedClient else { return .notDetermined }
        return await client.authorizationStatus()
    }

    // MARK: - UNUserNotificationCenterDelegate

    /// Show the banner (and play sound) even when the app is frontmost — a menu-bar accessory is
    /// effectively always frontmost, so without this the user would never see the alert.
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .list, .sound])
    }

    /// Tapping an alert opens the menu-bar popover so the user lands on the dashboard.
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        guard response.actionIdentifier == UNNotificationDefaultActionIdentifier,
              response.notification.request.content.threadIdentifier == "runway"
        else {
            completionHandler()
            return
        }
        Task { @MainActor in
            AppLog.info(.notifications, "notification tapped; opening popover")
            MenuBarPopover.show()
        }
        completionHandler()
    }
}
