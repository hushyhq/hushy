import MurmurCore
import SwiftUI

/// The one place a person sets how Hushy writes (Voice & style → Style) in its main states. Pinned on the
/// controller and rendered against the snapshot defaults suite: nothing downloads or loads, and
/// nobody's real settings are read.
extension Snapshots {
    private struct WritingHomeState {
        let name: String
        var tones: ToneSettings = .standard
        var choice: CleanupBackendChoice = .apple
        var install: LocalModelInstall = .notInstalled
        var canPolish = true
    }

    static func renderWritingHome(model: AppModel, scheme: ColorScheme, size: CGSize, directory: URL) async {
        let controller = model.cleanupModel
        let total = controller.recommendedEntry.downloadBytes
        let ownTones = ToneSettings.standard
            .settingTone(.casual, for: .personalMessages)
            .settingApp(.tone(.casual), bundleIDs: ["com.tinyspeck.slackmacgap"])
        let states = [
            WritingHomeState(name: "default"),
            WritingHomeState(name: "app-tone", tones: ownTones),
            WritingHomeState(name: "as-spoken", tones: { var tones = ToneSettings.standard; tones.choice = .asSpoken; return tones }()),
            WritingHomeState(
                name: "downloading", choice: .local,
                install: .downloading(received: total * 38 / 100, total: total, secondsRemaining: 140)),
            WritingHomeState(name: "unavailable", canPolish: false),
        ]
        let earlierSection = model.section
        model.section = WritingHome.section
        for state in states {
            model.settings.toneSettings = state.tones
            controller.pinForSnapshot(
                choice: state.choice, install: state.install, effective: state.choice == .local ? .rules : .apple,
                calls: [], modelAvailable: state.canPolish)
            await capture(
                MainView().environment(model)
                    .environment(\.snapshotVoiceStyleTab, WritingHome.tab)
                    .environment(\.installedApps, toneSnapshotApps),
                name: "writing-home-\(state.name)", scheme: scheme,
                size: CGSize(width: size.width, height: 2400), directory: directory)
        }
        // A per-app tone being edited: Slack has a tone of its own.
        model.settings.toneSettings = ownTones
        controller.pinForSnapshot(choice: .apple, install: .notInstalled, effective: .apple, calls: [])
        await capture(
            StyleTabContent().environment(model).environment(\.installedApps, toneSnapshotApps),
            name: "writing-home-app-tone-editing", scheme: scheme,
            size: CGSize(width: 700, height: 1900), directory: directory)
        model.settings.toneSettings = .standard
        model.section = earlierSection
    }
}
