import Foundation
import MurmurCore

/// Sentences on the required onboarding steps whose truth depends on how the app behaves, kept
/// here so a test can read them.
enum OnboardingCopy {
    static func practiceCompleted(_ dictation: Dictation, since startedAt: Date) -> Bool {
        dictation.createdAt >= startedAt && !dictation.text.isEmpty
            && (dictation.status == .inserted || dictation.status == .notInserted)
    }
    /// One line (2026-10-28, "less text"). True of both ways to dictate: holding the key, and one tap
    /// for hands-free until the next tap (`HotkeyEvent.latched`), since both are "when you dictate".
    static let microphoneMessage = "Hushy listens only when you dictate, and the audio stays on this Mac."

    /// One way forward per state. Waiting: the step moves on by itself the moment access is
    /// granted, and says so. Already granted (Back, or a replay): nothing will change, so the
    /// sentence about moving on is dropped and Continue is the only way forward.
    static func accessibilityMessage(triggerGlyph: String, isGranted: Bool) -> String {
        let why = "So Hushy can notice when you double-tap \(triggerGlyph), and paste for you."
        return isGranted ? why : "\(why) Turn on Hushy in the list, and this moves on by itself."
    }

    static func tryItLead(triggerGlyph: String) -> String {
        "Double-tap \(triggerGlyph), say something, press Enter."
    }

    /// A messy sentence to say, so the Heard and Typed card has something to show. The same one Home suggests
    /// (`HomeFeedCopy.tryItSentence`); a separate string so `tryItLead` stays exactly as it was.
    static let tryItSuggestion = "Try: \u{201C}\(HomeFeedCopy.tryItSentence)\u{201D}"

    /// Around the key cap on the "Almost set" step: "When it's ready, in any app: double-tap [fn] to talk, then press Enter."
    static let tryItWaitingLead = "When it's ready, in any app: double-tap"
    static let tryItWaitingTail = "to talk, then press Enter."

    static func tryItAlternative(triggerGlyph: String) -> String {
        "Or hold \(triggerGlyph) while you talk."
    }

    /// The stepper's "Download model" detail: the speech model now, then the writing model this Mac gets
    /// (nil when it gets none, e.g. under 16 GB), so the line matches what the Mac really downloads.
    static func modelSizeLine(speechBytes: Int64, writingBytes: Int64?) -> String {
        let speech = ModelDownloadProgress.formatBytes(speechBytes)
        guard let writingBytes, writingBytes > 0 else { return "About \(speech), once" }
        return "\(speech) speech, then about \(ModelDownloadProgress.formatBytes(writingBytes)) writing model, once"
    }

    static func practicePlaceholder(triggerGlyph: String) -> String {
        "Your words appear here"
    }
}

/// The closing step's words while dictation cannot work yet. Setup can finish before the speech
/// model has (a slow, offline or metered connection), and "You're set." would be untrue then, so
/// the step says setup is done, what dictation is waiting for, and how the person will know it
/// is ready. Pure, so a test can read every state; the ready screen is `OnboardingView.done`.
enum OnboardingDoneCopy {
    static func showsMurmurMigration(movedSupportDirectory: Bool) -> Bool { movedSupportDirectory }
    /// What stands between the person and their first dictation.
    enum Wait: Equatable {
        /// Bytes are arriving. `progress` is "196 of ~632 MB · about 4 min left" when known.
        case downloading(progress: String?)
        /// Downloaded; the model is loading, which takes seconds.
        case preparing
        case offline
        case meteredNetwork
        case failed
    }

    struct Pending: Equatable {
        let title: String
        let message: String
        /// The download's bytes and time left, when there is a download to describe.
        let progressLine: String?
        /// How the person will know dictation is ready, and what to do then.
        let readyLine: String
        let buttonTitle: String
    }

    /// Under "You're set.": dictation first, in the person's own key (hold, or one tap for
    /// hands-free), then where everything else lives. No plans or allowances here.
    static func readyMessage(triggerGlyph: String) -> String {
        "Double-tap \(triggerGlyph) to talk, Enter to paste. Hold \(ActionHotkeyMonitor.chordText) for an action."
    }

    /// Nil once dictation works: the step shows "You're set." instead.
    static func wait(isReady: Bool, isLoading: Bool, eta: DownloadETA, download: ModelDownloadProgress?) -> Wait? {
        guard !isReady else { return nil }
        if isLoading { return .preparing }
        switch eta {
        case .ready: return .preparing
        case .waiting(.offline): return .offline
        case .waiting(.meteredNetwork): return .meteredNetwork
        case .waiting(.failed): return .failed
        case .estimating, .seconds: return .downloading(progress: download.map(progressText))
        }
    }

    static func pending(_ wait: Wait, triggerGlyph: String) -> Pending {
        let message: String
        var progressLine: String?
        var buttonTitle = "Open Hushy"
        switch wait {
        case .downloading(let progress):
            message = "Dictation is still downloading and will not work until that finishes. You can open Hushy now and the download carries on."
            progressLine = progress.map { "Speech model · \($0)" }
            buttonTitle = "Open Hushy while it downloads"
        case .preparing:
            message = "Dictation is almost ready. Hushy is loading its speech model, which takes a few seconds."
        case .offline:
            message = "This Mac is offline, so dictation's download is paused and dictation will not work yet. The download carries on by itself when you are back online."
        case .meteredNetwork:
            message = "Dictation's download is paused to save your data allowance, and dictation will not work until it finishes. It carries on by itself on Wi-Fi."
        case .failed:
            message = "Dictation's download stopped, and dictation will not work until it finishes. Hushy retries by itself, and you can retry from Home."
        }
        return Pending(
            title: "Setup is done.", message: message, progressLine: progressLine,
            readyLine: readyLine(triggerGlyph: triggerGlyph), buttonTitle: buttonTitle)
    }

    /// True of every waiting state: `DownloadCoordinator.notifyWhenReady` sends one notification
    /// (`ReadyNotifier`, if macOS allows it), and Home's readiness card shows the speech model
    /// until it is ready.
    static func readyLine(triggerGlyph: String) -> String {
        "Hushy sends one notification when dictation is ready, if you allow notifications. Home shows the speech model until then. After that, double-tap \(triggerGlyph) in any app, talk, and press Enter."
    }

    /// The closing step when Microphone or Accessibility was skipped or is still not granted.
    /// "You're set." would be untrue: dictation cannot hear, or cannot type, until that access
    /// is on. Microphone comes first. Nil once both are granted, even if a step was skipped
    /// and access arrived afterwards.
    struct Almost: Equatable {
        let message: String
        let buttonTitle: String
        let fix: Fix
    }

    enum Fix: Equatable {
        /// The system prompt, because access has not been asked for yet.
        case allowMicrophone
        /// System Settings → Privacy & Security → Microphone. Access was denied.
        case openMicrophoneSettings
        /// System Settings → Privacy & Security → Accessibility.
        case openAccessibilitySettings
    }

    static let almostTitle = "Almost."
    static let waitingForPermission = "Waiting for permission…"
    static let openMicrophoneSettings = "Open Microphone settings"
    static let openAccessibilitySettings = "Open Accessibility settings"

    static func almost(
        microphone: Permissions.Status, accessibility: Permissions.Status, skipped: [OnboardingStep]
    ) -> Almost? {
        // A Skip is a gap only while access is still missing. Granting it afterwards (the pane
        // stays open, or the person goes back) is "You're set."
        let microphoneLeft = skipped.contains(.microphone) || microphone != .granted
        let accessibilityLeft = skipped.contains(.accessibility) || accessibility != .granted
        if microphone != .granted, microphoneLeft {
            if microphone == .denied {
                return Almost(
                    message: "Microphone access is off, so Hushy cannot hear you yet. Allow Hushy in the list that opens.",
                    buttonTitle: openMicrophoneSettings, fix: .openMicrophoneSettings)
            }
            return Almost(
                message: "Hushy still needs the microphone, so dictation cannot start yet.",
                buttonTitle: "Allow microphone", fix: .allowMicrophone)
        }
        if accessibility != .granted, accessibilityLeft {
            return Almost(
                message: "Accessibility access is still off, so Hushy cannot notice your key or paste yet. Turn on Hushy in the list that opens.",
                buttonTitle: openAccessibilitySettings, fix: .openAccessibilitySettings)
        }
        return nil
    }

    /// "Waiting for permission…" only after the System Settings pane was opened. The microphone
    /// prompt (access not yet asked) is not that pane.
    static func showsWaiting(for fix: Fix, microphonePaneOpened: Bool, accessibilityPaneOpened: Bool) -> Bool {
        switch fix {
        case .allowMicrophone: false
        case .openMicrophoneSettings: microphonePaneOpened
        case .openAccessibilitySettings: accessibilityPaneOpened
        }
    }

    /// "196 of ~632 MB · about 4 min left": bytes, and the time only once there is an estimate.
    static func progressText(_ download: ModelDownloadProgress) -> String {
        let line = ModelDownloadProgress(fraction: download.fraction, expectedBytes: download.expectedBytes).compactLine(title: "")
        let bytes = line.hasPrefix(" · ") ? String(line.dropFirst(3)) : line
        guard let seconds = download.estimatedSecondsRemaining else { return bytes }
        return "\(bytes) · about \(ModelDownloadProgress.formatRemaining(seconds)) left"
    }
}

/// The action invitation belongs to the successful close, never to setup completion itself.
enum OnboardingVoiceActionOffer {
    static func isShown(firstDictationWorked: Bool, hasPermissionGap: Bool, isModelPending: Bool, skipped: Bool) -> Bool {
        firstDictationWorked && !hasPermissionGap && !isModelPending && !skipped
    }

    static func instruction(dictation: TriggerKey, action: ActionTriggerKey) -> String {
        let key = ActionTriggerKey.effective(action, dictation: dictation).keyCap
        return "Hold \(ActionHotkeyMonitor.chordText) and say it, or tap \(key) twice to talk hands-free. Tap \(key) again to cancel."
    }

    static let practiceNotice = "This is practice; nothing gets added."
}
