import MurmurCore
import SwiftUI

/// Settings → About with its "Polish" status row in each state (M5): Apple (default),
/// the local model downloading (simple fixes meanwhile), paused, failed, unable to run, ready and answering, and rules
/// only. Pinned on the controller — nothing downloads or loads in snapshot mode.
extension Snapshots {
    static func renderCleanupModel(model: AppModel, scheme: ColorScheme, directory: URL) async {
        let controller = model.cleanupModel
        let entry = controller.recommendedEntry
        let now = Date()
        func call(_ backend: String, _ ms: Double) -> ModelCallLog.Entry {
            .init(backend: backend, milliseconds: ms, outcome: .answered, at: now)
        }
        let states: [(String, CleanupBackendChoice, LocalModelInstall, EffectiveCleanupBackend, [ModelCallLog.Entry])] = [
            ("apple", .apple, .notInstalled, .apple, [call("apple", 1_840), call("apple", 2_120), call("apple", 1_710)]),
            ("downloading", .local,
             .downloading(received: entry.downloadBytes * 38 / 100, total: entry.downloadBytes, secondsRemaining: 140),
             .rules, []),
            ("ready", .local, .ready, .local(entry.id), [call("local", 212), call("local", 198), call("apple", 1_880), call("local", 176)]),
            ("paused", .local, .paused(received: entry.downloadBytes * 38 / 100, total: entry.downloadBytes, reason: .offline), .rules, []),
            ("failed", .local, .failed("The download stopped."), .rules, []),
            ("unavailable", .local, .ready, .apple, []),
            ("rules", .rules, .notInstalled, .rules, []),
        ]
        for (name, choice, install, effective, calls) in states {
            controller.pinForSnapshot(choice: choice, install: install, effective: effective, calls: calls)
            let page = SettingsSnapshotPage(
                pane: .about, needsAttentionBadge: false,
                retentionBinding: { keyPath in Binding(get: { model.settings[keyPath: keyPath] }, set: { _ in }) })
            await capture(
                page.environment(model), name: "settings-cleanup-model-\(name)", scheme: scheme,
                size: CGSize(width: 780, height: 860), directory: directory)
        }
        controller.pinForSnapshot(choice: .apple, install: .notInstalled, effective: .apple, calls: [])
    }
}
