import Foundation
import MurmurCore

/// What Home's dictation card says for one readiness state: a headline that answers "can I
/// dictate right now", one or two sentences of why and what happens next, and the title of the
/// button that fixes it. Built from the same `DictationReadinessStatus` the sidebar row shows
/// (first blocker first), so the two can never disagree about what is wrong. Pure, so a test
/// reads every state (`DictationHeroCopyTests`).
struct DictationHeroCopy: Equatable {
    /// The short word beside the status dot: "Ready", "Getting ready", "Needs you".
    let stateWord: String
    let headline: String
    let detail: String
    /// The transfer's own line while bytes arrive: "316 of ~632 MB · about 4 min left".
    let progressLine: String?
    /// 0…1 while a transfer has a known fraction; the card draws it as a bar.
    let progress: Double?
    /// What the engine reported when the speech model failed, shown small under the detail.
    let note: String?
    /// Nil when there is nothing to press (ready, downloading, loading).
    let fixTitle: String?
    let isReady: Bool
    /// While the speech model loads from disk: its stages and how far along it is, for the
    /// card's track (`SpeechLoadProgress`). Nil in every other state.
    var load: SpeechLoadProgress.Display?

    /// One instruction, with the dictation key as its own part where the card draws it as a key
    /// cap between the words. The second line names no key: the first one just did.
    struct KeyLine: Equatable {
        let before: String
        let key: String?
        let after: String

        var sentence: String { [before, key, after].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " ") }
    }

    /// How to start, in the person's own key: hold to talk, one tap for hands-free.
    static func howToStart(triggerGlyph: String) -> [KeyLine] {
        [
            KeyLine(before: "Double-tap", key: triggerGlyph, after: "to talk, Enter to paste."),
            KeyLine(before: "Or hold", key: triggerGlyph, after: "while you talk."),
        ]
    }

    static func make(
        status: DictationReadinessStatus, triggerGlyph: String, modelState: SpeechModelStatus.State,
        download: ModelDownloadProgress?, load: SpeechLoadProgress.Display? = nil,
        afterOnboarding: Bool = false
    ) -> DictationHeroCopy {
        switch status.reason {
        case .ready:
            return ready(triggerGlyph: triggerGlyph)
        case .modelDownloading, .modelPausedOffline, .modelPausedMetered, .modelLoading, .vocabularyDownloading,
             .modelFailed, .modelNotLoaded:
            var copy = speechModel(status.reason, modelState: modelState, download: download, load: load)
            if status.reason == .modelLoading { copy.load = load }
            return copy
        case .microphoneNotAsked, .microphoneDenied, .accessibility:
            return permission(status.reason, triggerGlyph: triggerGlyph, afterOnboarding: afterOnboarding)
        case .keyRemapped, .macDictationClash:
            return keyConflict(status.reason, triggerGlyph: triggerGlyph)
        }
    }

    private static func ready(triggerGlyph: String) -> DictationHeroCopy {
        state(
            stateWord: "Ready", headline: "Dictation is ready.",
            detail: howToStart(triggerGlyph: triggerGlyph).map(\.sentence).joined(separator: " "), isReady: true)
    }

    private static func speechModel(
        _ reason: DictationReadinessStatus.Reason, modelState: SpeechModelStatus.State, download: ModelDownloadProgress?,
        load: SpeechLoadProgress.Display? = nil
    ) -> DictationHeroCopy {
        switch reason {
        case .modelDownloading:
            var fraction = download?.fraction
            if fraction == nil, case .downloading(let value) = modelState { fraction = value }
            return state(
                stateWord: "Getting ready", headline: "Dictation is still downloading.",
                detail: "Hushy is downloading its speech model, and dictation will not work until that finishes. The download carries on if you close this window.",
                progressLine: download.map(OnboardingDoneCopy.progressText), progress: fraction)
        case .modelPausedOffline:
            return state(
                stateWord: "Paused", headline: "Dictation is waiting for a connection.",
                detail: "This Mac is offline, so the speech model download is paused. It carries on by itself when you are back online.",
                fixTitle: "Try again")
        case .modelPausedMetered:
            return state(
                stateWord: "Paused", headline: "Dictation is waiting for Wi-Fi.",
                detail: "The speech model download is paused to save your data allowance. It carries on by itself on Wi-Fi, or you can download it now.",
                fixTitle: "Download now")
        case .modelLoading:
            // No "almost": the load takes as long as it takes, and the card flips to Ready when it
            // has. The same words as the pill's row for a key pressed too early (`loadingLine`).
            // With the load's stages known the sentence names the one under way, and the note
            // says when this launch is one of the slow ones.
            return state(
                stateWord: "Getting ready", headline: "Dictation is getting ready.",
                detail: load?.sentence ?? "Hushy is loading the speech model. Dictation will work as soon as it has loaded.",
                note: load?.note)
        case .vocabularyDownloading:
            var fraction: Double?
            if case .downloadingVocabulary(let value) = modelState { fraction = value }
            return state(
                stateWord: "Getting ready", headline: "Dictation is still setting up.",
                detail: "Hushy is downloading the part that helps it with names and unusual words.",
                progressLine: fraction.map { "\(Int($0 * 100))% so far" }, progress: fraction)
        case .modelFailed:
            var message: String?
            if case .failed(let value) = modelState, !value.isEmpty { message = value }
            return state(
                stateWord: "Not working", headline: "Dictation could not start.",
                detail: "The speech model did not load, so dictation will not work yet.",
                note: message, fixTitle: "Try again")
        default:
            return state(
                stateWord: "Not ready", headline: "Dictation has not started yet.",
                detail: "The speech model is not loaded, so dictation will not work yet.", fixTitle: "Try again")
        }
    }

    private static func permission(_ reason: DictationReadinessStatus.Reason, triggerGlyph: String,
                                   afterOnboarding: Bool) -> DictationHeroCopy {
        if afterOnboarding {
            switch reason {
            case .microphoneNotAsked, .microphoneDenied:
                return state(stateWord: "Needs you", headline: "Turn the microphone back on.",
                             detail: "Hushy needs it to hear you.", fixTitle: "Allow Microphone")
            default:
                return state(stateWord: "Needs you", headline: "Turn Accessibility back on.",
                             detail: "The \(triggerGlyph) key needs it, and macOS asks again after an update. If Hushy is already on in the list, remove it with −, then add it again.",
                             fixTitle: "Allow Accessibility")
            }
        }
        switch reason {
        case .microphoneNotAsked:
            return state(
                stateWord: "Needs you", headline: "Dictation needs the microphone.",
                detail: "Hushy cannot hear you until you allow the microphone. It listens only when you ask it to.",
                fixTitle: "Allow microphone")
        case .microphoneDenied:
            return state(
                stateWord: "Needs you", headline: "Dictation needs the microphone.",
                detail: "Microphone access is off for Hushy. Turn it on in System Settings, under Privacy & Security, then Microphone.",
                fixTitle: "Open System Settings")
        default:
            return state(
                stateWord: "Needs you", headline: "Dictation needs Accessibility access.",
                detail: "Accessibility access lets Hushy notice when you hold \(triggerGlyph) and paste the text into the app you are using. Turn on Hushy in System Settings, under Privacy & Security, then Accessibility.",
                fixTitle: "Allow Accessibility")
        }
    }

    private static func keyConflict(_ reason: DictationReadinessStatus.Reason, triggerGlyph: String) -> DictationHeroCopy {
        if reason == .keyRemapped {
            return state(
                stateWord: "Check this", headline: "\(triggerGlyph) is set to do something else.",
                detail: "In Keyboard settings, \(triggerGlyph) is set to another action, so it will not start dictation. Set it to Do Nothing there, or pick another dictation key in Hushy's Settings.",
                fixTitle: "Open Keyboard settings")
        }
        return state(
            stateWord: "Check this", headline: "\(triggerGlyph) also starts macOS Dictation.",
            detail: "macOS Dictation uses the shortcut “Press \(triggerGlyph) twice”, and Hushy uses the same key for hands-free. Change the macOS shortcut in Keyboard settings, under Dictation.",
            fixTitle: "Open Keyboard settings")
    }

    private static func state(
        stateWord: String, headline: String, detail: String, progressLine: String? = nil, progress: Double? = nil,
        note: String? = nil, fixTitle: String? = nil, isReady: Bool = false
    ) -> DictationHeroCopy {
        DictationHeroCopy(
            stateWord: stateWord, headline: headline, detail: detail, progressLine: progressLine, progress: progress,
            note: note, fixTitle: fixTitle, isReady: isReady)
    }
}
