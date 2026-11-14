#if DEBUG
import Foundation
import MurmurCore

/// Scenario A. Joins the dictation path at the same calls `DictationController.process` makes after
/// the hotkey is released: `SpeechGate`, `LoudnessNormalizer`, `speech.transcribeWithConfidence`
/// (whole utterance), then `DictationPipeline.clean`. What the real `AudioCapture` and the real
/// engine do is real; what is bypassed is the hotkey, focus target, mic-permission prompt, streaming
/// session, paste, persistence and pill.
extension MockMicHarness {
    static let captureLeadIn: Duration = .milliseconds(600)
    static let captureTail: Duration = .milliseconds(1200)

    func runDictationScenarios() async {
        let title = "Dictation through the real capture, ASR and cleanup"
        guard !manifest.dictation.isEmpty else { return }
        let missing = MockMicPreflight.missingForDictation()
        guard missing.isEmpty else {
            for clip in manifest.dictation {
                record(skipped("dictation.\(clip.id)", title, "skipped: model missing (\(missing.joined(separator: ", ")))"))
            }
            return
        }
        guard let deviceID = rig.verifiedDeviceID() else {
            for clip in manifest.dictation { record(skipped("dictation.\(clip.id)", title, "skipped: the capture device could not be verified")) }
            return
        }
        do { try await rig.prepareSpeech() } catch {
            for clip in manifest.dictation { record(failed("dictation.\(clip.id)", title, error, seconds: 0)) }
            return
        }
        for clip in manifest.dictation {
            let start = ContinuousClock.now
            let result: MockMicScenarioResult
            do { result = try await runDictation(clip, deviceID: deviceID, title: title, start: start) } catch {
                result = failed("dictation.\(clip.id)", title, error, seconds: mockMicSeconds(since: start))
            }
            record(result)
            if result.status == .blocked { return }
        }
    }

    private func runDictation(_ clip: MockMicManifest.Dictation, deviceID: UInt32, title: String,
                              start: ContinuousClock.Instant) async throws -> MockMicScenarioResult {
        let id = "dictation.\(clip.id)"
        let files = try resolve(clip.wavs)
        let samples = try await capture(files, deviceID: deviceID)
        if samples.allSatisfy({ $0 == 0 }) { return blockedResult(id, title, seconds: mockMicSeconds(since: start)) }
        let gate = SpeechGate.evaluate(samples)
        guard gate.hasSpeech else {
            return MockMicScenarioResult(
                id: id, title: title, status: enforcesQuality ? .fail : .reported,
                seconds: mockMicSeconds(since: start), detail: "the speech gate rejected the capture",
                checks: [check("speech gate passes", false, "rms=\(gate.metrics.rms)")], metrics: [:], texts: nil)
        }
        let normalized = LoudnessNormalizer.normalize(samples)
        let transcribed = try await rig.speech.transcribeWithConfidence(normalized, vocabulary: pipelineSettings.vocabulary)
        let output = await pipeline.clean(transcribed.text, confidences: transcribed.confidences, settings: pipelineSettings)
        return dictationResult(id: id, title: title, clip: clip, raw: transcribed.text, output: output,
                               captured: Double(samples.count) / 16_000, start: start)
    }

    private var pipelineSettings: PipelineSettings {
        PipelineSettings(cleanupOptions: rig.settings.cleanupOptions, personalizer: Personalizer(),
                         style: nil, mode: nil, contextTerms: [])
    }

    private var pipeline: DictationPipeline {
        DictationPipeline(transcriber: rig.speech, cleaner: SmartCleaner(model: rig.cleanupModel, abandoned: .shared))
    }

    /// Real `AudioCapture` on the verified virtual device while the player plays the clip.
    func capture(_ files: [URL], deviceID: UInt32) async throws -> [Float] {
        let audio = AudioCapture()
        audio.preferredDeviceID = deviceID
        audio.strictDevice = true
        audio.voiceProcessing = rig.settings.reduceBackgroundNoise
        try audio.start(onLevel: { _ in })
        defer { if audio.isRunning { audio.stop() } }
        try await Task.sleep(for: Self.captureLeadIn)
        try await config.player.play(files)
        try await Task.sleep(for: Self.captureTail)
        return audio.stop()
    }

    private func dictationResult(id: String, title: String, clip: MockMicManifest.Dictation, raw: String,
                                 output: PipelineResult, captured: Double,
                                 start: ContinuousClock.Instant) -> MockMicScenarioResult {
        let mode = manifest.scoringMode
        let cleaned = MockMicScoring.score(reference: clip.reference, hypothesis: output.text, mode: mode)
        let rawScore = MockMicScoring.score(reference: clip.reference, hypothesis: raw, mode: mode)
        let checks = [check("cleaned text word error", cleaned.wer <= MockMicThresholds.dictationWordError,
                            wordError(cleaned.wer), threshold: "<= \(wordError(MockMicThresholds.dictationWordError))",
                            quality: true)]
        let metrics: [String: Double] = [
            "cleanedWordError": cleaned.wer, "rawWordError": rawScore.wer,
            "referenceWords": Double(cleaned.referenceWords), "capturedSeconds": captured,
            "usedModel": output.usedModel ? 1 : 0,
        ]
        let detail = "wer \(wordError(cleaned.wer)) cleaned, \(wordError(rawScore.wer)) raw, backend \(rig.cleanupBackend), model used \(output.usedModel), scoring \(mode.rawValue)"
        return MockMicScenarioResult(
            id: id, title: title, status: MockMicReport.status(for: checks), seconds: mockMicSeconds(since: start),
            detail: detail, checks: checks, metrics: metrics,
            texts: ["reference": clip.reference, "raw": raw, "cleaned": output.text])
    }
}
#endif
