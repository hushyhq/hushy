import MurmurCore
import SwiftUI

/// Onboarding in each download pace, captured directly (bypassing `AppModel.showOnboarding`,
/// which snapshot mode forces past so the regular pages aren't dimmed by it). No engine runs in
/// snapshot mode: the model status and the coordinator's network flags are pinned per capture.
///
/// - `onboarding-fast-*`: the gate-11 flow, model ready by "Try it".
/// - `onboarding-slow-*`: optional steps inserted while ~1–2 min remain; Try it "almost ready".
/// - `onboarding-veryslow-*`: every optional step, Try it "still downloading (4 min left)".
/// - `onboarding-offline-*` and `onboarding-metered-*`: nothing padded in; honest status.
/// - `onboarding-*-done` other than `fast`: the closing step while dictation cannot work yet.
extension Snapshots {
    static func renderOnboarding(model: AppModel, scheme: ColorScheme, size: CGSize, directory: URL) async {
        let bytes = SpeechEngine.expectedDownloadBytes(for: model.settings.speechLanguageMode.modelVersion)
        func downloading(_ fraction: Double, eta: TimeInterval?) {
            let progress = ModelDownloadProgress(
                fraction: fraction, expectedBytes: bytes, completedFiles: 3, totalFiles: 20, estimatedSecondsRemaining: eta)
            model.modelStatus.pinForSnapshot(.downloading(fraction), download: progress)
            model.downloads.pinForSnapshot()
        }
        func shot(_ name: String, _ flow: OnboardingFlow) async {
            await capture(
                OnboardingView(initialFlow: flow).environment(model),
                name: "onboarding-\(name)", scheme: scheme, size: size, directory: directory)
        }
        model.permissions.pinForSnapshot(microphone: .granted, accessibility: .granted)
        let required = OnboardingStep.required

        // Fast: model lands during the permissions.
        downloading(0.62, eta: 12)
        for step in [OnboardingStep.welcome, .microphone, .accessibility] {
            await shot("fast-\(step.rawValue)", OnboardingFlow(sequence: required, at: step))
        }
        model.modelStatus.pinForSnapshot(.ready)
        model.downloads.pinForSnapshot()
        // The key lesson: waiting, the key down, double-tap learned, both learned, and blocked
        // (no Accessibility: dimmed, with the reason and the button).
        for (name, lesson, blocked) in [
            ("waiting", KeyGesturePractice(), false),
            ("pressed", KeyGesturePractice(isDown: true), false),
            ("doubletapped", KeyGesturePractice(learned: [.doubleTap]), false),
            ("both", KeyGesturePractice(learned: [.doubleTap, .hold]), false),
            ("blocked", KeyGesturePractice(), true),
        ] {
            await capture(
                OnboardingView(initialFlow: OnboardingFlow(sequence: required, at: .hotkeyPractice),
                               snapshotKeyLesson: lesson, snapshotKeyLessonBlocked: blocked)
                    .environment(model),
                name: "onboarding-fast-key-\(name)", scheme: scheme, size: size, directory: directory)
        }
        await shot("fast-tryIt", OnboardingFlow(sequence: required, at: .tryIt))
        await capture(
            OnboardingView(initialFlow: OnboardingFlow(sequence: required, at: .tryIt), snapshotTryItDone: true)
                .environment(model),
            name: "onboarding-fast-tryIt-doubleTap-enter-done", scheme: scheme, size: size, directory: directory)
        await shot("fast-done", OnboardingFlow(sequence: required, at: .done))
        for (name, open, phase) in [
            ("offer", false, VoiceActionRehearsal.Phase.waiting),
            ("practice-waiting", true, .waiting),
            ("practice-heard", true, .heard),
        ] {
            await capture(
                OnboardingView(
                    initialFlow: OnboardingFlow(sequence: required, at: .done),
                    snapshotFirstDictationWorked: true, snapshotPracticeOpen: open)
                    .environment(model).environment(\.snapshotActionRehearsal, phase),
                name: "onboarding-fast-done-\(name)", scheme: scheme, size: size, directory: directory)
        }
        for moved in [false, true] {
            await capture(
                OnboardingView(
                    initialFlow: OnboardingFlow(sequence: required, at: .done),
                    snapshotFirstDictationWorked: true, snapshotMigratedFromMurmur: moved)
                    .environment(model),
                name: moved ? "onboarding-fast-done-murmur-shown" : "onboarding-fast-done-murmur-hidden",
                scheme: scheme, size: size, directory: directory)
        }
        // The voice-action practice, no longer an onboarding step: the sheet Settings → Voice
        // actions opens, ready for the key, then heard ("Would add: …").
        for phase in [VoiceActionRehearsal.Phase.waiting, .heard] {
            await capture(
                VoiceActionRehearsalView.snapshotSheet(model: model, phase: phase),
                name: "settings-voiceActions-practice-\(phase.rawValue)", scheme: scheme,
                size: CGSize(width: VoiceActionRehearsalView.sheetWidth, height: 560), directory: directory)
        }

        // Slow: ~90 s left on leaving Accessibility → three optional steps.
        let slow: [OnboardingStep] = [.welcome, .microphone, .accessibility, .hotkeyPractice, .micCheck, .dictionary, .tryIt, .done]
        downloading(0.49, eta: 85)
        await shot("slow-accessibility", OnboardingFlow(sequence: slow, at: .accessibility))
        await shot("slow-hotkeyPractice", OnboardingFlow(sequence: slow, at: .hotkeyPractice))
        downloading(0.63, eta: 62)
        await shot("slow-micCheck", OnboardingFlow(sequence: slow, at: .micCheck))
        downloading(0.78, eta: 40)
        await shot("slow-dictionary", OnboardingFlow(sequence: slow, at: .dictionary))
        downloading(0.94, eta: 14)
        await shot("slow-tryIt", OnboardingFlow(sequence: slow, at: .tryIt))

        // Very slow: every optional step, then an honest Try it.
        let verySlow = [OnboardingStep.welcome, .microphone, .accessibility] + OnboardingStep.optionalByValue + [.tryIt, .done]
        downloading(0.21, eta: 390)
        await shot("veryslow-writingStyle", OnboardingFlow(sequence: verySlow, at: .writingStyle))
        await shot("veryslow-privacy", OnboardingFlow(sequence: verySlow, at: .privacy))
        downloading(0.31, eta: 236)
        await shot("veryslow-tryIt", OnboardingFlow(sequence: verySlow, at: .tryIt))
        // The closing step while dictation cannot work yet: "Setup is done.", not "You're set."
        await shot("veryslow-done", OnboardingFlow(sequence: verySlow, at: .done))
        model.modelStatus.pinForSnapshot(.loading)
        model.downloads.pinForSnapshot()
        await shot("loading-done", OnboardingFlow(sequence: required, at: .done))

        // Offline: nothing padded in; partial bytes kept; resumes by itself.
        let kept = ModelDownloadProgress(fraction: 0.18, expectedBytes: bytes)
        model.modelStatus.pinForSnapshot(.paused, download: kept)
        model.downloads.pinForSnapshot(waitingForNetwork: true, conditions: .offline)
        await shot("offline-welcome", OnboardingFlow(sequence: required, at: .welcome))
        await shot("offline-tryIt", OnboardingFlow(sequence: required, at: .tryIt))
        await shot("offline-done", OnboardingFlow(sequence: required, at: .done))

        // Metered: paused before the first byte, asking.
        model.modelStatus.pinForSnapshot(.paused)
        model.downloads.pinForSnapshot(needsMeteredConsent: true, conditions: NetworkConditions(isReachable: true, isExpensive: true))
        await shot("metered-welcome", OnboardingFlow(sequence: required, at: .welcome))
        await shot("metered-tryIt", OnboardingFlow(sequence: required, at: .tryIt))
        await shot("metered-done", OnboardingFlow(sequence: required, at: .done))

        // Failed: the download stopped; Hushy retries, and Home offers Retry.
        model.modelStatus.pinForSnapshot(
            .failed("The download stopped."), download: kept,
            failure: SpeechModelStatus.Failure(isOffline: false, message: "The download stopped."))
        model.downloads.pinForSnapshot()
        await shot("failed-done", OnboardingFlow(sequence: required, at: .done))

        model.modelStatus.pinForSnapshot(.ready)
        model.downloads.pinForSnapshot()
    }
}
