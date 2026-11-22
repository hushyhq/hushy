#if DEBUG
import Foundation
import MurmurCore

/// `--meeting-journal dictation-paired`: the same take, idle and while a meeting finalizes, alternating, so drift on the
/// Mac falls on both sides alike. Each round: two presses with nothing running, then Try again on the recorded meeting,
/// one press while its parts are recognised and one inside a summary or extract call on the shared 4B. Every press keeps
/// where its time went (recognition, cleanup, the 4B's own call, the wait for a cut-short summary call to stop), so the
/// report names what a dictation under finalize waits on, not only that it waits.
extension MeetingJournalTrial.Runner {
    struct Press {
        let condition: String
        let step: String
        let dictated: Dictated
        let breakdown: Breakdown
    }

    struct Breakdown {
        var recognizeMs = 0.0
        var cleanMs = 0.0
        /// The local leg's wall time (`ModelCallLog`, queue wait on the engine included).
        var localLegMs: Double?
        /// The 4B's own time for the call, from inside the engine (`MLXLanguageModel.lastCallTimings`).
        var engineMs: Double?
        var ttftMs: Double?
        var promptTokens: Int?
        var prefixUse: String?
        /// From the key press to a cut-short background call ending (`ModelCallLog` `cancelled` on the local leg).
        var preemptedAfterMs: Double?
        var appleCalls = 0
    }

    func pairedDictation() async throws -> [String: Any] {
        let samples = LoudnessNormalizer.normalize(try clip("dictation.wav"))
        let cleaner = SmartCleaner(model: cleanupModel, abandoned: .shared)
        let warm = KeyDownWarmScheduler { await cleaner.warmOnKeyDown() }
        let path = DictationPath(pipeline: DictationPipeline(transcriber: rig.speech, cleaner: cleaner, warmScheduler: warm), warm: warm)
        _ = try await press(samples, path, condition: "warm", step: "idle")

        let mic = try synthetic("mic.wav")
        let call = try synthetic("call.wav")
        recorder.makeMicSource = { mic }
        recorder.makeCallSource = { call }
        try await recorder.start()
        guard let id = recorder.activeNote?.id else { throw MockMicRecordingError.noNote }
        try await Task.sleep(for: .seconds(arguments.seconds ?? 240))
        recorder.stop()
        try await waitForFinish(id)
        recorder.makeMicSource = nil
        recorder.makeCallSource = nil

        var presses: [Press] = []
        let rounds = max(1, arguments.trials / 2)
        for _ in 0..<rounds {
            for _ in 0..<2 { presses.append(try await press(samples, path, condition: "idle", step: "idle")) }
            guard let note = try rig.store.note(id: id) else { break }
            recorder.retryTranscription(for: note)
            try await Task.sleep(for: .seconds(Double.random(in: 0.5...3)))
            if let step = try runningStep(id) { presses.append(try await press(samples, path, condition: "finalize", step: step)) }
            if arguments.localModel != nil, try await waitForSummaryCall(noteId: id) {
                try await Task.sleep(for: .seconds(Double.random(in: 0.2...6)))
                if let step = try runningStep(id) { presses.append(try await press(samples, path, condition: "finalize", step: step)) }
            }
            try await waitForFinish(id)
        }
        let idle = presses.filter { $0.condition == "idle" }
        let finalize = presses.filter { $0.condition == "finalize" }
        return [
            "cleanupBackend": arguments.localModel == nil ? rig.cleanupBackend : summaryModelLabel,
            "summaryModel": summaryModelLabel, "speakerLabels": FeatureFlags.speakerLabels, "rounds": rounds,
            "idle": summary(idle.map(\.dictated)), "duringFinalize": summary(finalize.map(\.dictated)),
            "duringFinalizeByStep": Dictionary(grouping: finalize, by: \.step).mapValues { summary($0.map(\.dictated)) },
            "presses": presses.map(row), "summaryCallsBegun": summaryCalls.begun, "note": try describe(id),
        ]
    }

    private func runningStep(_ id: Int64) throws -> String? {
        guard recorder.finalizer.runningNoteIDs.contains(id) else { return nil }
        return try rig.store.finalizeState(noteId: id)?.step.rawValue ?? "none"
    }

    private func press(_ samples: [Float], _ path: DictationPath, condition: String, step: String) async throws -> Press {
        let pressed = Date()
        var breakdown = Breakdown()
        let dictated = try await dictate(samples, path) { recognizeMs, cleanMs in
            breakdown.recognizeMs = recognizeMs
            breakdown.cleanMs = cleanMs
            if let timings = self.mlx?.lastCallTimings {
                breakdown.engineMs = timings.totalMilliseconds
                breakdown.ttftMs = timings.timeToFirstTokenMilliseconds
                breakdown.promptTokens = timings.promptTokens
                breakdown.prefixUse = timings.prefixUse
            }
        }
        let window = callLog.recent.filter { $0.at >= pressed }
        breakdown.localLegMs = window.last { $0.backend == "local" && $0.outcome == .answered }?.milliseconds
        breakdown.preemptedAfterMs = window.first { $0.backend == "local" && $0.outcome == .cancelled }
            .map { $0.at.timeIntervalSince(pressed) * 1_000 }
        breakdown.appleCalls = window.filter { $0.backend == "apple" }.count
        return Press(condition: condition, step: step, dictated: dictated, breakdown: breakdown)
    }

    private func row(_ press: Press) -> [String: Any] {
        let b = press.breakdown
        var row: [String: Any] = [
            "condition": press.condition, "step": press.step, "ms": press.dictated.milliseconds.rounded(),
            "usedLocal": press.dictated.usedLocal, "recognizeMs": b.recognizeMs.rounded(), "cleanMs": b.cleanMs.rounded(),
            "appleCalls": b.appleCalls,
        ]
        row["localLegMs"] = b.localLegMs?.rounded()
        row["engineMs"] = b.engineMs?.rounded()
        row["ttftMs"] = b.ttftMs?.rounded()
        row["promptTokens"] = b.promptTokens
        row["prefixUse"] = b.prefixUse
        row["preemptedAfterMs"] = b.preemptedAfterMs?.rounded()
        return row
    }
}
#endif
