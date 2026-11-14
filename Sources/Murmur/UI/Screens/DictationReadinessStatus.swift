import MurmurCore
import SwiftUI

/// The sidebar's one dictation status line ("Hold fn to dictate · ready", "Speech model 43%",
/// "Microphone access needed", …) — replaces the old footer's "● Ready" dot outright rather
/// than rewording it (product direction, 2026-09-27). `DictateStatusRow` is the only place this
/// renders.
///
/// Deliberately plain inputs (no `AppModel`/`Environment` dependency) so the mapping from
/// state to copy is unit-testable without constructing the whole app — see
/// `DictationReadinessStatusTests`.
struct DictationReadinessStatus: Equatable {
    /// `.working` split into `.downloading` (a transfer — ink, `Theme.textTertiary`) and
    /// `.loading` (the model moving into memory — purple, `Theme.working`): a download is not
    /// the model thinking (docs/product/UI-ROUND-2026-09-28.md §3, C2).
    enum Kind: Equatable { case ready, warning, error, downloading, loading }

    let kind: Kind
    /// Short line for the status row, e.g. "Hold fn to dictate · ready".
    let text: String
    /// Longer line for the tooltip, with the specifics `text` elides.
    let detail: String
    /// What tapping the row should do when not ready; nil once everything's fine (nothing to fix).
    let fix: Fix?

    enum Fix: Equatable { case requestMicrophone, requestAccessibility, openKeyboardSettings, retryModel, approveMeteredDownload }

    /// Which check produced this status, for a surface that words the state itself (Home's
    /// dictation card, `DictationHeroCopy`) instead of showing `text`.
    let reason: Reason

    enum Reason: Equatable {
        case ready
        case modelDownloading, modelPausedOffline, modelPausedMetered, modelLoading, vocabularyDownloading
        case modelFailed, modelNotLoaded
        case microphoneNotAsked, microphoneDenied, accessibility
        case keyRemapped, macDictationClash
    }

    /// - Parameters:
    ///   - modelState: `SpeechModelStatus.state`.
    ///   - microphone: `Permissions.microphone`.
    ///   - accessibility: `Permissions.accessibility`.
    ///   - triggerKey: the configured hotkey (`AppSettings.triggerKey`).
    ///   - fnCaptureActive: `HotkeyMonitor.isFnCaptureActive` — once true, Hushy consumes solo
    ///     fn presses itself, so the Globe-action/Dictation-clash warnings below are moot.
    ///   - globeKeyConflicts: `Permissions.globeKeyAction.conflicts`.
    ///   - macDictationClashes: `Permissions.macDictationClashes(with:)`.
    ///   - download: `SpeechModelStatus.download` — bytes and time left, shown instead of a bare
    ///     percentage when present.
    ///   - meteredPause: the download is paused on a metered network waiting for the user's OK
    ///     (`DownloadCoordinator.needsMeteredConsent`).
    static func compute(
        modelState: SpeechModelStatus.State,
        microphone: Permissions.Status,
        accessibility: Permissions.Status,
        triggerKey: TriggerKey,
        fnCaptureActive: Bool,
        globeKeyConflicts: Bool,
        macDictationClashes: Bool,
        download: ModelDownloadProgress? = nil,
        meteredPause: Bool = false
    ) -> DictationReadinessStatus {
        // Checked in fix-first order: whichever would block dictation soonest is reported.
        if microphone != .granted {
            return DictationReadinessStatus(
                kind: .error, text: "Microphone access needed",
                detail: microphone == .denied
                    ? "Hushy can't hear you — allow microphone access in System Settings."
                    : "Hushy needs microphone access to dictate.",
                fix: .requestMicrophone, reason: microphone == .denied ? .microphoneDenied : .microphoneNotAsked)
        }
        if accessibility != .granted {
            return DictationReadinessStatus(
                kind: .error, text: "Accessibility needed for the hotkey",
                detail: "Hushy needs Accessibility access to detect \(triggerKey.glyph) globally. If Hushy is already on in the list, remove it with −, then add it again.",
                fix: .requestAccessibility, reason: .accessibility)
        }
        if case .downloading(let fraction) = modelState {
            let detail = "Hushy is downloading its speech model — dictation will be ready once this finishes."
            guard let download else {
                return DictationReadinessStatus(
                    kind: .downloading, text: "Speech model \(Int(fraction * 100))%", detail: detail, fix: nil,
                    reason: .modelDownloading)
            }
            // Bytes only go up; a time left (when known) is the useful half of the line.
            let text = download.estimatedSecondsRemaining.map {
                "Speech model · about \(ModelDownloadProgress.formatRemaining($0)) left"
            } ?? "Speech model · \(ModelDownloadProgress.formatBytes(download.estimatedBytes))"
            return DictationReadinessStatus(
                kind: .downloading, text: text, detail: download.compactLine(title: "Speech model") + ". " + detail, fix: nil,
                reason: .modelDownloading)
        }
        if modelState == .paused {
            return meteredPause
                ? DictationReadinessStatus(
                    kind: .warning, text: "Speech model paused · metered network",
                    detail: "You're on a metered or Low Data Mode network. Click to download the speech model anyway, or it continues on Wi-Fi.",
                    fix: .approveMeteredDownload, reason: .modelPausedMetered)
                : DictationReadinessStatus(
                    kind: .downloading, text: "Speech model paused · offline",
                    detail: "The download continues where it stopped when you're back online.", fix: .retryModel,
                    reason: .modelPausedOffline)
        }
        if modelState == .loading {
            return DictationReadinessStatus(
                kind: .loading, text: "Speech model loading…",
                detail: "Hushy is loading its speech model — dictation will be ready in a moment.", fix: nil,
                reason: .modelLoading)
        }
        if case .downloadingVocabulary(let fraction) = modelState {
            return DictationReadinessStatus(
                kind: .downloading, text: "Vocabulary model \(Int(fraction * 100))%",
                detail: "Hushy is downloading a vocabulary model used to improve accuracy.", fix: nil,
                reason: .vocabularyDownloading)
        }
        if case .failed(let message) = modelState {
            return DictationReadinessStatus(
                kind: .error, text: "Speech model failed to load", detail: message, fix: .retryModel,
                reason: .modelFailed)
        }
        if modelState == .idle {
            return DictationReadinessStatus(
                kind: .error, text: "Speech model not loaded", detail: "Tap to load the speech model.",
                fix: .retryModel, reason: .modelNotLoaded)
        }
        let fnCaptureResolvesConflicts = triggerKey == .fn && fnCaptureActive
        if !fnCaptureResolvesConflicts {
            if triggerKey == .fn, globeKeyConflicts {
                return DictationReadinessStatus(
                    kind: .warning, text: "\(triggerKey.glyph) key is remapped in Keyboard settings",
                    detail: "\(triggerKey.glyph) is set to a different action in Keyboard settings, so it won't start dictation.",
                    fix: .openKeyboardSettings, reason: .keyRemapped)
            }
            if macDictationClashes {
                return DictationReadinessStatus(
                    kind: .warning, text: "Hotkey conflicts with macOS Dictation",
                    detail: "macOS Dictation's shortcut is “Press \(triggerKey.glyph) twice”. Hushy uses the same key for a single-tap hands-free dictation. Change it in Keyboard → Dictation → Shortcut.",
                    fix: .openKeyboardSettings, reason: .macDictationClash)
            }
        }
        return DictationReadinessStatus(
            kind: .ready, text: "Hold \(triggerKey.glyph) to dictate · ready",
            detail: "Hold \(triggerKey.glyph) anywhere to dictate; tap once for hands-free, again to finish.", fix: nil,
            reason: .ready)
    }
}
