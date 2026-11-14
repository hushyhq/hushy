import Foundation
import MurmurCore
import UserNotifications

/// The generic "Task ready" / "Task failed" notification and the tap that opens the task list.
///
/// `UNUserNotificationCenter.current()` traps without an app bundle (`swift run`, tests, snapshot
/// runs; see `UserNotificationReadyNotifier`), so every use of it here sits behind `isAvailable`.
@MainActor
enum TaskHandoffNotifier {
    static var isAvailable: Bool { UserNotificationReadyNotifier.isAvailable }

    /// An earlier session saved a task list, so one of its notifications may still be on screen.
    static var hasTaskStore: Bool {
        FileManager.default.fileExists(atPath: HandoffQueue.defaultRoot.appendingPathComponent("index.json").path)
    }

    /// What answers a tap on a task notification: the app delegate, which sets this at launch.
    static weak var responder: (any UNUserNotificationCenterDelegate)?

    /// Whether to listen for taps at all. With the flag off and no saved tasks there is no
    /// notification to tap, and Hushy leaves the notification centre alone.
    static func answersTaps(isBundled: Bool, isEnabled: Bool, hasTaskStore: Bool) -> Bool {
        isBundled && (isEnabled || hasTaskStore)
    }

    /// Called at launch, and again when a task is queued in case the flag was turned on since.
    static func listenForTaps() {
        guard let responder,
              answersTaps(isBundled: isAvailable, isEnabled: FeatureFlags.taskHandoff, hasTaskStore: hasTaskStore)
        else { return }
        UNUserNotificationCenter.current().delegate = responder
    }

    static func prepare() {
        guard isAvailable else { return }
        listenForTaps()
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    static func finished(_ item: HandoffTask) {
        guard isAvailable, item.state == .done || item.state == .failed else { return }
        let content = UNMutableNotificationContent()
        content.title = item.state == .done ? "Task ready" : "Task failed"
        content.body = "Open Hushy to see your tasks."
        content.userInfo = ["handoffTaskID": item.id.uuidString]
        UNUserNotificationCenter.current().add(
            UNNotificationRequest(identifier: "app.hushy.task.\(item.id.uuidString)", content: content, trigger: nil)) { _ in }
    }
}
