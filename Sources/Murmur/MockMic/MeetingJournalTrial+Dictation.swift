#if DEBUG
import Foundation
import MurmurCore

/// Dictation while meetings run: the same recognition and cleanup a dictation makes after the key is released
/// (`speech.transcribeWithConfidence`, then `DictationPipeline.clean` with the cleanup model), timed from the release.
/// Each dictation marks itself busy from its key press, three seconds of speaking before the release, as the app's
/// `DictationController` does, so meeting work in the background yields to it.
extension MeetingJournalTrial.Runner {
    struct Dictated {
        let milliseconds: Double
        let usedModel: Bool
    }

    func dictation() async throws -> [String: Any] {
        let samples = LoudnessNormalizer.normalize(try clip("dictation.wav"))
        let target = arguments.trials
        _ = try await dictate(samples)   // warm the path once, not counted
        var idle: [Dictated] = []
        for _ in 0..<target { idle.append(try await dictate(samples)) }

        let mic = try synthetic("mic.wav")
        let call = try synthetic("call.wav")
        recorder.makeMicSource = { mic }
        recorder.makeCallSource = { call }
        try await recorder.start()
        guard let id = recorder.activeNote?.id else { throw MockMicRecordingError.noNote }
        try await Task.sleep(for: .seconds(35))   // the first part is sealed and being recognised
        var capturing: [Dictated] = []
        for _ in 0..<target {
            capturing.append(try await dictate(samples))
            try await Task.sleep(for: .seconds(Double.random(in: 1...4)))
        }
        recorder.stop()
        // While the meeting is finalized; Try again re-runs recognition of every part, assembly and the summary, so
        // the count reaches the target with real background work under it.
        var finalizing: [Dictated] = []
        var runs = 0
        while finalizing.count < target, runs < 8 {
            if !recorder.finalizer.runningNoteIDs.contains(id) {
                try await waitForFinish(id)
                guard let note = try rig.store.note(id: id) else { break }
                recorder.retryTranscription(for: note)
                runs += 1
                try await Task.sleep(for: .seconds(1))
            }
            finalizing.append(try await dictate(samples))
        }
        try await waitForFinish(id)
        // Idle again, so a change in the Mac's other load across the run shows as idle drift, not as meeting cost.
        var idleAfter: [Dictated] = []
        for _ in 0..<target { idleAfter.append(try await dictate(samples)) }
        recorder.makeMicSource = nil
        recorder.makeCallSource = nil
        return [
            "cleanupBackend": rig.cleanupBackend, "idle": summary(idle), "duringCapture": summary(capturing),
            "duringFinalize": summary(finalizing), "idleAfter": summary(idleAfter), "retries": runs, "note": try describe(id),
        ]
    }

    private func dictate(_ samples: [Float]) async throws -> Dictated {
        foreground.set(busy: true)
        defer { foreground.set(busy: false) }
        try await Task.sleep(for: .seconds(3))
        let began = ContinuousClock.now
        let settings = PipelineSettings(cleanupOptions: rig.settings.cleanupOptions, personalizer: Personalizer(),
                                        style: nil, mode: nil, contextTerms: [])
        let heard = try await rig.speech.transcribeWithConfidence(samples, vocabulary: settings.vocabulary)
        let pipeline = DictationPipeline(transcriber: rig.speech, cleaner: SmartCleaner(model: rig.cleanupModel, abandoned: .shared))
        let output = await pipeline.clean(heard.text, confidences: heard.confidences, settings: settings)
        return Dictated(milliseconds: mockMicSeconds(since: began) * 1_000, usedModel: output.usedModel)
    }

    private func summary(_ runs: [Dictated]) -> [String: Any] {
        let ms = runs.map(\.milliseconds)
        return [
            "count": runs.count, "usedModel": runs.filter(\.usedModel).count,
            "p50": MeetingJournalTrial.percentile(ms, 0.5).rounded(), "p95": MeetingJournalTrial.percentile(ms, 0.95).rounded(),
            "max": (ms.max() ?? 0).rounded(),
        ]
    }
}
#endif
