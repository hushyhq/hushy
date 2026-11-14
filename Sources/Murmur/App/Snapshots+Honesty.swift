import MurmurCore
import SwiftUI

/// Task 91 scenes: the Apple Notes toggle in each access state (onboarding "done" step and the
/// Notes sidebar row) and the Tune result. Nothing here runs AppleScript, records audio or writes
/// anywhere: the access result and the Tune scores are pinned, and the toggles ignore taps in
/// snapshot mode.
extension Snapshots {
    /// Every state the Apple Notes toggle can show; `nil` is the untouched toggle.
    private static let notesStates: [(name: String, result: AppleNotesAccessResult?)] = [
        ("off", nil), ("granted", .granted), ("blocked", .notPermitted),
        ("unavailable", .notesUnavailable), ("timedout", .timedOut), ("other", .other(-128)),
    ]

    static func renderHonesty(model: AppModel, scheme: ColorScheme, size: CGSize, directory: URL) async {
        model.permissions.pinForSnapshot(microphone: .granted, accessibility: .granted)
        model.modelStatus.pinForSnapshot(.ready)
        for state in notesStates {
            await capture(
                OnboardingView(initialFlow: OnboardingFlow(sequence: OnboardingStep.required, at: .done))
                    .environment(model).environment(\.snapshotAppleNotesResult, state.result),
                name: "onboarding-notes-\(state.name)", scheme: scheme, size: size, directory: directory)
        }
        model.section = .notes
        model.selectedNoteID = nil
        for state in notesStates where state.result != nil {
            await capture(
                MainView().environment(model).environment(\.snapshotAppleNotesResult, state.result),
                name: "notes-sidebar-\(state.name)", scheme: scheme, size: size, directory: directory)
        }
        await renderBlockedSettingsPanes(model: model, scheme: scheme, directory: directory)
        await renderTuneResult(model: model, scheme: scheme, directory: directory)
    }

    /// Settings → Meetings and → Voice actions with macOS having refused Notes access: the
    /// toggle stays off and the notice offers System Settings and Try again.
    private static func renderBlockedSettingsPanes(model: AppModel, scheme: ColorScheme, directory: URL) async {
        for pane in [SettingsPane.notesAndMeetings, .voiceActions] {
            let page = SettingsSnapshotPage(
                pane: pane, needsAttentionBadge: false,
                retentionBinding: { keyPath in Binding(get: { model.settings[keyPath: keyPath] }, set: { _ in }) })
            await capture(
                page.environment(model).environment(\.snapshotAppleNotesResult, .notPermitted),
                name: "settings-\(pane.rawValue)-notes-blocked", scheme: scheme,
                size: CGSize(width: 780, height: 720), directory: directory)
        }
    }

    /// One sentence misheard, a whisper close to the room's noise floor.
    private static func renderTuneResult(model: AppModel, scheme: ColorScheme, directory: URL) async {
        let tune = TuneModel(
            settings: model.settings, store: model.store,
            voiceSignatureStore: model.encryption.voiceSignatureStore)
        let sentences = TuneSentenceBuilder.build(terms: tune.terms)
        var heard = Dictionary(uniqueKeysWithValues: sentences.map { ($0.id, $0.expected) })
        heard[.jargon] = "Let's review the road map and the deck with Jordan tomorrow morning."
        let calibration = VoiceCalibration(noiseFloorRMS: 0.012, speechLevelRMS: 0.08, whisperLevelRMS: 0.014)
        tune.pinResultForSnapshot(transcripts: heard, calibration: calibration)
        await capture(
            TuneContent(tune: tune, embedInOnboarding: false, onDone: {}).padding(Theme.Space.xl).environment(model),
            name: "tune-result", scheme: scheme, size: CGSize(width: 640, height: 620), directory: directory, fixedSize: true)
    }
}
