import Foundation
import Testing
import MurmurCore
@testable import Murmur

/// The sidebar's "Hold fn to dictate · ready" / specific-problem status line, read from
/// `DictationReadinessStatus.compute`. These tests lock down the state → copy → fix mapping
/// directly, without needing a live `AppModel`.
@Suite("Dictation readiness status")
@MainActor
struct DictationReadinessStatusTests {
    private func status(
        modelState: SpeechModelStatus.State = .ready,
        microphone: Permissions.Status = .granted,
        accessibility: Permissions.Status = .granted,
        triggerKey: TriggerKey = .fn,
        fnCaptureActive: Bool = true,
        globeKeyConflicts: Bool = false,
        macDictationClashes: Bool = false
    ) -> DictationReadinessStatus {
        .compute(
            modelState: modelState, microphone: microphone, accessibility: accessibility,
            triggerKey: triggerKey, fnCaptureActive: fnCaptureActive,
            globeKeyConflicts: globeKeyConflicts, macDictationClashes: macDictationClashes)
    }

    @Test("everything ready reports the trigger glyph and no fix")
    func allReady() {
        let result = status()
        #expect(result.kind == .ready)
        #expect(result.text == "Hold fn to dictate · ready")
        #expect(result.fix == nil)
    }

    @Test("a non-fn trigger shows its own glyph")
    func nonFnTrigger() {
        let result = status(triggerKey: .rightOption, fnCaptureActive: false)
        #expect(result.kind == .ready)
        #expect(result.text == "Hold ⌥ to dictate · ready")
    }

    @Test("speech model downloading reports a percentage and no fix")
    func modelDownloading() {
        let result = status(modelState: .downloading(0.42))
        #expect(result.kind == .downloading)
        #expect(result.text == "Speech model 42%")
        #expect(result.fix == nil)
    }

    @Test("speech model loading takes the purple 'loading' kind, not the ink 'downloading' kind")
    func modelLoading() {
        let result = status(modelState: .loading)
        #expect(result.kind == .loading)
        #expect(result.text.contains("loading"))
    }

    @Test("vocabulary model downloading is a transfer, so it takes the ink 'downloading' kind")
    func vocabularyDownloading() {
        let result = status(modelState: .downloadingVocabulary(0.7))
        #expect(result.kind == .downloading)
        #expect(result.text.contains("70%"))
    }

    @Test("speech model failed offers a retry fix")
    func modelFailed() {
        let result = status(modelState: .failed("Out of disk space"))
        #expect(result.kind == .error)
        #expect(result.text == "Speech model failed to load")
        #expect(result.detail == "Out of disk space")
        #expect(result.fix == .retryModel)
    }

    @Test("speech model idle offers a retry fix")
    func modelIdle() {
        let result = status(modelState: .idle)
        #expect(result.kind == .error)
        #expect(result.fix == .retryModel)
    }

    @Test("missing microphone access takes priority over hotkey state")
    func microphoneMissing() {
        let result = status(microphone: .denied, accessibility: .denied)
        #expect(result.kind == .error)
        #expect(result.text == "Microphone access needed")
        #expect(result.fix == .requestMicrophone)
    }

    @Test("missing accessibility blocks the hotkey")
    func accessibilityMissing() {
        let result = status(accessibility: .denied)
        #expect(result.kind == .error)
        #expect(result.text == "Accessibility needed for the hotkey")
        #expect(result.fix == .requestAccessibility)
    }

    @Test("a remapped Globe key warns and offers Keyboard settings")
    func globeKeyConflict() {
        let result = status(fnCaptureActive: false, globeKeyConflicts: true)
        #expect(result.kind == .warning)
        #expect(result.fix == .openKeyboardSettings)
    }

    @Test("a macOS Dictation shortcut clash warns and offers Keyboard settings")
    func dictationClash() {
        let result = status(triggerKey: .rightCommand, fnCaptureActive: false, macDictationClashes: true)
        #expect(result.kind == .warning)
        #expect(result.fix == .openKeyboardSettings)
    }

    @Test("active fn capture resolves Globe/Dictation warnings even if they'd otherwise apply")
    func fnCaptureResolvesConflicts() {
        let result = status(fnCaptureActive: true, globeKeyConflicts: true, macDictationClashes: true)
        #expect(result.kind == .ready)
    }

    /// The five states `Snapshots.render` captures for the Dictate status row (see
    /// `Snapshots.dictateStatusStates`): ready, downloading, an error and a warning, one of
    /// each `Kind` the row actually renders differently. Locks down that each one keeps its own
    /// `kind` — a state silently collapsing into another would be invisible in a snapshot diff
    /// but very visible as a wrong dot color/icon in the running app.
    @Test("the five snapshot states each keep a distinct kind")
    func snapshotStatesCoverDistinctKinds() {
        let ready = status()
        let downloading = status(modelState: .downloading(0.42))
        let micNeeded = status(microphone: .denied)
        let accessibilityNeeded = status(accessibility: .denied)
        let keyboardConflict = status(fnCaptureActive: false, globeKeyConflicts: true)

        #expect(ready.kind == .ready)
        #expect(downloading.kind == .downloading)
        #expect(micNeeded.kind == .error)
        #expect(accessibilityNeeded.kind == .error)
        #expect(keyboardConflict.kind == .warning)

        // Each of the five renders visibly different text, so a snapshot reviewer can tell them
        // apart without inspecting color.
        let texts = Set([ready.text, downloading.text, micNeeded.text, accessibilityNeeded.text, keyboardConflict.text])
        #expect(texts.count == 5)
    }

    @Test("with download detail the row shows time left, never a bare percentage")
    func downloadDetail() {
        let progress = ModelDownloadProgress(fraction: 0.5, expectedBytes: 632_000_000, estimatedSecondsRemaining: 230)
        let result = DictationReadinessStatus.compute(
            modelState: .downloading(0.5), microphone: .granted, accessibility: .granted, triggerKey: .fn,
            fnCaptureActive: true, globeKeyConflicts: false, macDictationClashes: false, download: progress)
        #expect(result.text == "Speech model · about 4 min left")
        #expect(result.detail.hasPrefix("Speech model · 316 of ~632 MB · about 4 min."))
        let early = DictationReadinessStatus.compute(
            modelState: .downloading(0.01), microphone: .granted, accessibility: .granted, triggerKey: .fn,
            fnCaptureActive: true, globeKeyConflicts: false, macDictationClashes: false,
            download: ModelDownloadProgress(fraction: 0.01, expectedBytes: 632_000_000))
        #expect(early.text == "Speech model · 6.3 MB")
    }

    @Test("a metered pause offers to download; an offline pause just waits")
    func paused() {
        let metered = DictationReadinessStatus.compute(
            modelState: .paused, microphone: .granted, accessibility: .granted, triggerKey: .fn,
            fnCaptureActive: true, globeKeyConflicts: false, macDictationClashes: false, meteredPause: true)
        #expect(metered.kind == .warning)
        #expect(metered.fix == .approveMeteredDownload)
        let offline = status(modelState: .paused)
        // A paused download is still a transfer state (ink), not the model working (purple).
        #expect(offline.kind == .downloading)
        #expect(offline.text == "Speech model paused · offline")
    }
}

