#if DEBUG
import Foundation
import MurmurCore

/// Dictation while meetings run: the same recognition and cleanup a dictation makes after the key is released
/// (`speech.transcribeWithConfidence`, then `DictationPipeline.clean` with the cleanup model), timed from the release.
/// Each dictation marks itself busy from its key press, three seconds of speaking before the release, and schedules
/// the key-down warm, as the app's `DictationController` does, so meeting work in the background yields to it.
/// With `--local-model-dir` the cleanup model and the summaries are one local 4B; `usedLocal` counts the dictations
/// the 4B itself answered (`ModelCallLog`, the leg labelled "local"), not Apple FM behind it.
extension MeetingJournalTrial.Runner {
    struct Dictated {
        let milliseconds: Double
        let usedModel: Bool
        let usedLocal: Bool
    }

    /// One cleaner and key-down warm for the whole run, as `DictationController` keeps them.
    struct DictationPath {
        let pipeline: DictationPipeline
        let warm: KeyDownWarmScheduler
    }

    func dictation() async throws -> [String: Any] {
        let samples = LoudnessNormalizer.normalize(try clip("dictation.wav"))
        let target = arguments.trials
        let cleaner = SmartCleaner(model: cleanupModel, abandoned: .shared)
        let warm = KeyDownWarmScheduler { await cleaner.warmOnKeyDown() }
        let path = DictationPath(pipeline: DictationPipeline(transcriber: rig.speech, cleaner: cleaner, warmScheduler: warm), warm: warm)
        _ = try await dictate(samples, path)   // warm the path once, not counted
        var idle: [Dictated] = []
        for _ in 0..<target { idle.append(try await dictate(samples, path)) }

        let mic = try synthetic("mic.wav")
        let call = try synthetic("call.wav")
        recorder.makeMicSource = { mic }
        recorder.makeCallSource = { call }
        try await recorder.start()
        guard let id = recorder.activeNote?.id else { throw MockMicRecordingError.noNote }
        try await Task.sleep(for: .seconds(35))   // the first part is sealed and being recognised
        var capturing: [Dictated] = []
        for _ in 0..<target {
            capturing.append(try await dictate(samples, path))
            try await Task.sleep(for: .seconds(Double.random(in: 1...4)))
        }
        recorder.stop()
        // While the meeting is finalized; Try again re-runs recognition of every part, assembly and the summary, so
        // the count reaches the target with real background work under it.
        // With the summaries on the shared 4B, each press waits for a summary call to be running on it and lands at a
        // random moment of that call (its prompt or its answer), so the dictation has to take the model from it.
        var finalizing: [Dictated] = []
        var runs = 0
        var duringCall = 0
        while finalizing.count < target, runs < 24 {
            if !recorder.finalizer.runningNoteIDs.contains(id) {
                try await waitForFinish(id)
                guard let note = try rig.store.note(id: id) else { break }
                recorder.retryTranscription(for: note)
                runs += 1
                try await Task.sleep(for: .seconds(1))
            }
            if arguments.localModel != nil, try await waitForSummaryCall(noteId: id) {
                duringCall += 1
                try await Task.sleep(for: .seconds(Double.random(in: 0.2...6)))
            }
            finalizing.append(try await dictate(samples, path))
        }
        try await waitForFinish(id)
        // Idle again, so a change in the Mac's other load across the run shows as idle drift, not as meeting cost.
        var idleAfter: [Dictated] = []
        for _ in 0..<target { idleAfter.append(try await dictate(samples, path)) }
        recorder.makeMicSource = nil
        recorder.makeCallSource = nil
        return [
            "cleanupBackend": arguments.localModel == nil ? rig.cleanupBackend : summaryModelLabel,
            "summaryModel": summaryModelLabel, "speakerLabels": FeatureFlags.speakerLabels, "idle": summary(idle), "duringCapture": summary(capturing),
            "duringFinalize": summary(finalizing), "idleAfter": summary(idleAfter), "retries": runs, "note": try describe(id),
            "pressedDuringSummaryCall": duringCall, "summaryCallsBegun": summaryCalls.begun,
        ]
    }

    /// Waits (at most 60 s, or until the note's run ends) for a new summary call to begin on the shared model; true
    /// when one did.
    func waitForSummaryCall(noteId: Int64) async throws -> Bool {
        let seen = summaryCalls.begun
        let deadline = ContinuousClock.now + .seconds(60)
        while ContinuousClock.now < deadline, recorder.finalizer.runningNoteIDs.contains(noteId) {
            if summaryCalls.begun > seen { return true }
            try await Task.sleep(for: .milliseconds(20))
        }
        return false
    }

    /// `observe` gets the recognition and cleanup milliseconds while the dictation still counts as busy, so what it
    /// reads about this call (the 4B's last timings) cannot belong to a summary call that resumed after it.
    func dictate(
        _ samples: [Float], _ path: DictationPath, observe: ((_ recognizeMs: Double, _ cleanMs: Double) -> Void)? = nil
    ) async throws -> Dictated {
        foreground.set(busy: true)
        defer { foreground.set(busy: false) }
        path.warm.schedule()
        try await Task.sleep(for: .seconds(3))
        let began = ContinuousClock.now
        let released = Date()
        let settings = PipelineSettings(cleanupOptions: rig.settings.cleanupOptions, personalizer: Personalizer(),
                                        style: nil, mode: nil, contextTerms: [])
        let heard = try await rig.speech.transcribeWithConfidence(samples, vocabulary: settings.vocabulary)
        let recognized = ContinuousClock.now
        let output = await path.pipeline.clean(heard.text, confidences: heard.confidences, settings: settings)
        let cleanMs = mockMicSeconds(since: recognized) * 1_000
        let milliseconds = mockMicSeconds(since: began) * 1_000
        observe?(milliseconds - cleanMs, cleanMs)
        // Summary calls are cut short while this dictation is busy, so an answer from the local leg since the release is
        // this dictation's.
        let local = callLog.recent.contains { $0.at >= released && $0.backend == "local" && $0.outcome == .answered }
        return Dictated(milliseconds: milliseconds, usedModel: output.usedModel, usedLocal: local)
    }

    func summary(_ runs: [Dictated]) -> [String: Any] {
        let ms = runs.map(\.milliseconds)
        return [
            "count": runs.count, "usedModel": runs.filter(\.usedModel).count, "usedLocal": runs.filter(\.usedLocal).count,
            "p50": MeetingJournalTrial.percentile(ms, 0.5).rounded(), "p95": MeetingJournalTrial.percentile(ms, 0.95).rounded(),
            "max": (ms.max() ?? 0).rounded(),
        ]
    }
}
#endif
