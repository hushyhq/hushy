@preconcurrency import AVFoundation
import FluidAudio
import Foundation
import MurmurCore
import Testing
@testable import Murmur

/// Measurement probe, not a regression test: runs only when `HUSHY_FIRSTRUN_PROBE_CLIP` points at
/// a synthetic `say` clip (16 kHz). Times a cold launch's first and second dictation through the
/// real `SpeechEngine`, with FluidAudio in offline mode (never downloads, never purges a cache).
/// Results go to `HUSHY_FIRSTRUN_PROBE_OUT` (appended, content-free: numbers only).
///
/// How to run (through the heavy-job queue, with a throwaway home, from the repo root):
///
///     export HUSHY_HOME=$(mktemp -d) MURMUR_HOME=$HUSHY_HOME
///     export HUSHY_FIRSTRUN_PROBE_CLIP=/path/to/clip.wav            # a ~3 s `say` clip, 16 kHz
///     export HUSHY_FIRSTRUN_PROBE_OUT=/path/to/results.txt          # optional, appended
///     scripts/mac-heavy.sh first-run-probe swift test -j 4 --filter FirstDictationProbeTests/coldLaunch
///
/// Optional switches: `HUSHY_FIRSTRUN_PROBE_DELAY=<s>` waits that long after the speech model is
/// ready and before the first dictation (the boosting models finish warming in the background);
/// `_SETTLE=<s>` adds one more dictation after the three timed ones, that long after them;
/// `_NOWARM=1` skips the background warm-up (to compare with a launch that has none). Without
/// the CLIP variable the tests do nothing. `boostingBreakdown` splits the cold cost into its parts.
@Suite("First-dictation probe", .timeLimit(.minutes(5)))
struct FirstDictationProbeTests {
    private static var clipPath: String? { ProcessInfo.processInfo.environment["HUSHY_FIRSTRUN_PROBE_CLIP"] }

    private func samples(at path: String) throws -> [Float] {
        let file = try AVAudioFile(forReading: URL(fileURLWithPath: path))
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false)!
        guard let converter = AVAudioConverter(from: file.processingFormat, to: format),
              let input = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length))
        else { throw CocoaError(.fileReadUnknown) }
        try file.read(into: input)
        let output = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(Double(file.length) * 16_000 / file.fileFormat.sampleRate) + 1024)!
        var supplied = false
        var error: NSError?
        converter.convert(to: output, error: &error) { _, status in
            if supplied { status.pointee = .endOfStream; return nil }
            supplied = true
            status.pointee = .haveData
            return input
        }
        if let error { throw error }
        return Array(UnsafeBufferPointer(start: output.floatChannelData![0], count: Int(output.frameLength)))
    }

    private func ms(_ block: () async throws -> Void) async rethrows -> Double {
        let start = Date()
        try await block()
        return Date().timeIntervalSince(start) * 1000
    }

    private func record(_ line: String) {
        print("PROBE \(line)")
        guard let out = ProcessInfo.processInfo.environment["HUSHY_FIRSTRUN_PROBE_OUT"] else { return }
        let url = URL(fileURLWithPath: out)
        let data = Data((line + "\n").utf8)
        if let handle = try? FileHandle(forWritingTo: url) {
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: data)
            try? handle.close()
        } else {
            try? data.write(to: url)
        }
    }

    @Test("cold launch: first and second dictation with the built-in vocabulary",
          .enabled(if: FirstDictationProbeTests.clipPath != nil))
    func coldLaunch() async throws {
        ModelHub.offlineMode = true
        let clip = try samples(at: try #require(Self.clipPath))
        let integrity = SpeechModelIntegrity(fetchManifest: { _ in throw CocoaError(.fileReadUnknown) },
                                             defaultsSuiteName: "hushy-probe-\(UUID().uuidString)")
        let status = await MainActor.run { SpeechModelStatus() }
        let engine = SpeechEngine(status: status, integrity: integrity)
        let vocabulary = VocabularyContext(terms: VocabularyContext.builtInTerms)
        record("clip seconds=\(String(format: "%.2f", Double(clip.count) / 16_000)) terms=\(vocabulary.terms.count)")

        if ProcessInfo.processInfo.environment["HUSHY_FIRSTRUN_PROBE_NOWARM"] == nil {
            await engine.setBoostingVocabulary(vocabulary)
        }
        record("prepare ms=\(Int(try await ms { try await engine.prepare(version: .ultra, driftGuard: true) }))")
        let delay = Double(ProcessInfo.processInfo.environment["HUSHY_FIRSTRUN_PROBE_DELAY"] ?? "") ?? 0
        if delay > 0 { try await Task.sleep(for: .seconds(delay)) }
        record("delay seconds=\(delay)")
        for run in 1...3 {
            var text = ""
            let took = try await ms { text = try await engine.transcribeWithConfidence(clip, vocabulary: vocabulary).text }
            record("dictation\(run) ms=\(Int(took)) chars=\(text.count)")
        }
        guard let settle = Double(ProcessInfo.processInfo.environment["HUSHY_FIRSTRUN_PROBE_SETTLE"] ?? "") else { return }
        try await Task.sleep(for: .seconds(settle))
        var text = ""
        let took = try await ms { text = try await engine.transcribeWithConfidence(clip, vocabulary: vocabulary).text }
        record("settled(\(settle)s) dictation ms=\(Int(took)) chars=\(text.count)")
    }

    @Test("cost breakdown of the boosting pieces on a cold process",
          .enabled(if: FirstDictationProbeTests.clipPath != nil))
    func boostingBreakdown() async throws {
        ModelHub.offlineMode = true
        let clip = try samples(at: try #require(Self.clipPath))
        var asrModels: AsrModels?
        record("asr models load ms=\(Int(try await ms { asrModels = try await AsrModels.downloadAndLoad(version: .ultra) }))")
        let asr = AsrManager(config: .default)
        try await asr.loadModels(try #require(asrModels))
        var state = TdtDecoderState.make()
        var result: ASRResult?
        record("asr first inference ms=\(Int(try await ms { result = try await asr.transcribe(clip, decoderState: &state) }))")
        var state2 = TdtDecoderState.make()
        record("asr second inference ms=\(Int(try await ms { result = try await asr.transcribe(clip, decoderState: &state2) }))")
        let first = try #require(result)
        let timings = try #require(first.tokenTimings)

        var ctc: CtcModels?
        record("ctc models load ms=\(Int(try await ms { ctc = try await CtcModels.downloadAndLoad(variant: .ctc110m) }))")
        func context(_ terms: [VocabularyTerm]) -> CustomVocabularyContext {
            CustomVocabularyContext(terms: terms.map { CustomVocabularyTerm(text: $0.text, aliases: $0.aliases.isEmpty ? nil : $0.aliases) })
        }
        let config = VocabularyRescorer.Config(spotterRescueEnabled: false)
        var session: VocabularyBoostingSession?
        let built = VocabularyContext.builtInTerms
        record("session build (models loaded) ms=\(Int(try await ms { session = try await VocabularyBoostingSession(vocabulary: context(built), ctcModels: try #require(ctc), config: config) }))")
        let live = try #require(session)
        for run in 1...3 {
            record("rescore\(run) ms=\(Int(await ms { _ = await live.rescore(text: first.text, tokenTimings: timings, audioSamples: clip) }))")
        }
        let edited = built + [VocabularyTerm(text: "Priya", aliases: ["Pria"])]
        record("rebuild on edit, models kept ms=\(Int(try await ms { session = try await VocabularyBoostingSession(vocabulary: context(edited), ctcModels: try #require(ctc), config: config) }))")
        var again: CtcModels?
        record("second ctc load (as streaming start does) ms=\(Int(try await ms { again = try await CtcModels.downloadAndLoad(variant: .ctc110m) }))")
        _ = again
        var v2: AsrModels?
        record("v2 drift model load ms=\(Int(try await ms { v2 = try await AsrModels.downloadAndLoad(version: .v2) }))")
        let v2Manager = AsrManager(config: .default)
        try await v2Manager.loadModels(try #require(v2))
        var s3 = TdtDecoderState.make()
        record("v2 first inference ms=\(Int(try await ms { _ = try await v2Manager.transcribe(clip, decoderState: &s3) }))")
        let streaming = SlidingWindowAsrManager(config: .default)
        record("streaming loadModels (shared) ms=\(Int(try await ms { try await streaming.loadModels(try #require(asrModels)) }))")
    }
}
