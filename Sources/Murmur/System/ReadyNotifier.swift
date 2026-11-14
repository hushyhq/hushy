import Foundation
import UserNotifications

/// The one notification onboarding promises ("We'll let you know when it's ready").
@MainActor
protocol ReadyNotifying: AnyObject {
    /// Asks for notification permission, at the moment the promise is made (never earlier).
    func prepare()
    func notifyReady()
}

/// Test/snapshot notifier: records nothing, sends nothing.
@MainActor
final class SilentNotifier: ReadyNotifying {
    private(set) var prepared = false
    private(set) var sentCount = 0
    func prepare() { prepared = true }
    func notifyReady() { sentCount += 1 }
}

/// Local user notification (no server, no push). Only works from a real `.app` bundle —
/// `UNUserNotificationCenter` traps without a bundle identifier, so `swift run` builds skip it
/// and rely on the menu-bar/status-row line instead.
@MainActor
final class UserNotificationReadyNotifier: ReadyNotifying {
    /// Shared with the other callers of the notification centre, which trap the same way.
    static var isAvailable: Bool {
        Bundle.main.bundleIdentifier != nil && Bundle.main.bundleURL.pathExtension == "app"
    }
    private var isAvailable: Bool { Self.isAvailable }

    func prepare() {
        guard isAvailable else { return }
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    func notifyReady() {
        guard isAvailable else { return }
        let content = UNMutableNotificationContent()
        content.title = "Hushy is ready"
        content.body = "The speech model finished downloading — you can dictate in any app now."
        let request = UNNotificationRequest(identifier: "app.hushy.speech-model-ready", content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request) { _ in }
    }
}
