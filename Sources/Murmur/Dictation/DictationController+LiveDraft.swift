import Foundation
import MurmurCore
import os

/// The recogniser work that runs while a dictation is still being spoken: early cleaning (`EarlyCleanupSession`) and
/// the pill's live words (`LiveDraftSession`). Both go through one `RecogniserLane`, with the pass after the release,
/// so the draft never runs at the same time as either of the passes whose text is used.
extension DictationController {
    private nonisolated static let draftLog = Logger(subsystem: "app.hushy", category: "dictation")

    /// Early cleaning uses the same recogniser and settings as the release pass, or nil when it is switched off (a
    /// DEBUG-only switch, `FeatureFlags.streamingLongDictation`). Its passes are exactly what they were; the lane only
    /// makes one wait for a draft pass already running.
    func earlySession(for target: FocusTarget, settings captured: SessionSettings) -> EarlyCleanupSession? {
        // Terminal routing resolves after this session starts; an early group could use the wrong category.
        guard FeatureFlags.streamingLongDictation,
              !TerminalAgentContext.isCandidate(bundleID: target.bundleID) else { return nil }
        let run = pipelineSettings(for: target, settings: captured)
        let speech = self.speech
        let lane = recogniserLane
        let vocabulary = run.vocabulary
        let window = captured.windowContext
        return EarlyCleanupSession(
            pipeline: pipeline, settings: run, detectsLanguage: settings.speechLanguageMode == .automatic
        ) { samples in
            // The window read may finish while the person speaks; its vocabulary is then the one the release will ask
            // for, and asking for it here keeps the recogniser from rebuilding between the two.
            let current = window?.readyVocabulary ?? vocabulary
            return try await lane.exclusive { try await speech.transcribeWithConfidence(samples, vocabulary: current).text }
        }
    }

    /// The live draft for this recording, whatever the writing setting: As spoken, a code editor and cleanup off
    /// all paste exactly what was heard, so the words in the pill are as useful there as anywhere. None in Low Power
    /// Mode, where the person has asked the Mac to save its battery; the pill shows its bars as before.
    ///
    /// The pill draws the words only when it is Large (`AppSettings.pillShowsLiveWords`). Mini still runs the draft:
    /// the release reconciles against it (`DraftCommonWordGuard`), so skipping it would change the text.
    func liveDraft(recordingID: UUID) -> LiveDraftSession? {
        let draftRuns = !ProcessInfo.processInfo.isLowPowerModeEnabled
        pill.liveWordsAllowed = draftRuns && settings.pillShowsLiveWords
        guard draftRuns else { return nil }
        let speech = self.speech
        return LiveDraftSession(
            lane: recogniserLane,
            recognise: { try await speech.draftTranscript($0) },
            onDraft: { [weak self] text in
                Task { @MainActor [weak self] in
                    guard let self, self.isRecording(recordingID) else { return }
                    self.lastLiveDraftText = text
                    self.pill.noteHeard(text)
                }
            })
    }

    /// The pass over the whole recording after the release, through the lane: it waits only for a draft pass that
    /// was already running when the key came up (none can start after), and says how long that was.
    ///
    /// It gives up after `limit` (`DeadlineExpired`): a recogniser stalled behind a hung draft or on the Neural Engine
    /// must not hold the take in processing for ever. The caller fails the take to its saved audio and Try again.
    func transcribeRelease(_ samples: [Float], vocabulary: VocabularyContext,
                           within limit: Duration) async throws -> TranscriptionResult {
        let transcriber = self.transcriber
        let lane = recogniserLane
        return try await Deadline.race(limit) {
            try await lane.exclusive(onWait: Self.noteReleaseWait) {
                try await transcriber.transcribeWithConfidence(samples, vocabulary: vocabulary)
            }
        }
    }

    /// Esc ended the recognition together with the take, so its words are read again from the recording. That
    /// read must never make the next take wait: it starts only when no dictation is under way or starting and the
    /// lane has no other pass running or waiting, and the next take's own pass waits at most for the one already
    /// running (`RecogniserLane.whenIdle`). A take that begins while the read waits in the lane or runs on it
    /// cancels it (`yieldToNewTake`), so the read cannot take the gap between that take's drafts; it asks again once
    /// the controller is idle. A read that fails leaves the take with audio and no words, which History offers to
    /// read again. A recogniser that ignores cancellation finishes the read it began, and its words are used.
    func rereadCancelled(_ samples: [Float]) async -> String {
        let id = UUID()
        defer {
            rereadAttempts[id] = nil
            yieldedRereads.remove(id)
        }
        while !Task.isCancelled {
            while isTakeUnderWay { try? await Task.sleep(for: .milliseconds(250)) }
            let transcriber = self.transcriber
            let lane = recogniserLane
            let attempt = Task { try await lane.whenIdle { try await transcriber.transcribe(samples) } }
            rereadAttempts[id] = attempt
            if case .success(let words) = await attempt.result { return words }
            guard yieldedRereads.remove(id) != nil else { return "" }
        }
        return ""
    }

    /// A take is starting: whatever is left over from the last one stops asking for the Mac. A look at the last paste
    /// ends, and an Esc re-read waiting for the lane or running on it gives the lane up and goes to the back.
    func yieldToNewTake() {
        cancelLateLanding()
        for (id, attempt) in rereadAttempts {
            yieldedRereads.insert(id)
            attempt.cancel()
        }
    }

    /// A dictation is being recorded, processed or delivered, or its microphone is opening.
    var isTakeUnderWay: Bool { isBusy || startPending }

    private nonisolated static func noteReleaseWait(_ waited: Duration) {
        let ms = Double(waited.components.seconds) * 1_000 + Double(waited.components.attoseconds) / 1e15
        guard ms >= 1 else { return }
        draftLog.notice("live draft: release pass waited \(Int(ms.rounded())) ms for a draft pass")
    }
}
