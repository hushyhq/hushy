@preconcurrency import AVFoundation
import Foundation
import Testing

@testable import murmur_eval
@testable import MurmurCore

/// Mock-mic seam unit tests (no audio hardware, no network, no models) + golden voice-trace
/// assembly cases (no ASR: fixed stage outputs through the pure `assemble` path).
@Suite("Voice trace (mock mic)")
struct VoiceTraceTests {
    // MARK: Mock-mic seam

    @Test func drainOf16kFilePreservesSampleCount() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(UUID().uuidString).wav")
        defer { try? FileManager.default.removeItem(at: url) }
        try EvalWAV.write(MockMicFeed.sine(hertz: 440, seconds: 1.0), to: url)
        let drained = try MockMicFeed.drain(file: url)
        // 1 s at 16 kHz, in 1,024-frame mic buffers through the real resampler.
        #expect(abs(drained.count - 16_000) < 320)
    }

    @Test func drainResamples48kLikeAMicrophoneWould() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(UUID().uuidString).wav")
        defer { try? FileManager.default.removeItem(at: url) }
        let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32, sampleRate: 48_000, channels: 1, interleaved: false)!
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: 48_000,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
        ]
        let samples = MockMicFeed.sine(hertz: 440, seconds: 0.5, sampleRate: 48_000)
        do {
            // Scoped so the writer is deallocated (header flushed) before the drain reads.
            let file = try AVAudioFile(
                forWriting: url, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
            guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count)) else {
                Issue.record("no buffer"); return
            }
            buffer.frameLength = AVAudioFrameCount(samples.count)
            samples.withUnsafeBufferPointer { source in
                buffer.floatChannelData?[0].update(from: source.baseAddress!, count: samples.count)
            }
            try file.write(from: buffer)
        }

        let drained = try MockMicFeed.drain(file: url)
        // 0.5 s of 48 kHz mic audio must come out as ~0.5 s of 16 kHz mono.
        #expect(abs(drained.count - 8_000) < 320)
    }

    @Test func drainThrowsOnMissingFile() {
        #expect(throws: (any Error).self) {
            try MockMicFeed.drain(file: URL(fileURLWithPath: "/nonexistent/clip.wav"))
        }
    }

    // MARK: Local-pair loading (the PRIMARY corpus format)

    @Test func localPairsLoadWavPlusSidecarAndSkipMissingAudio() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try EvalWAV.write(MockMicFeed.sine(hertz: 440, seconds: 0.2),
                          to: dir.appendingPathComponent("b.wav"))
        try EvalWAV.write(MockMicFeed.sine(hertz: 440, seconds: 0.2),
                          to: dir.appendingPathComponent("a.wav"))
        let sidecar = ["a": "first clip", "b": "second clip", "ghost": "no audio file"]
        try JSONEncoder().encode(sidecar)
            .write(to: dir.appendingPathComponent("transcripts.json"), options: .atomic)

        let clips = try VoiceTraceRunner.loadLocalPairs(dir: dir)
        #expect(clips.count == 2)
        #expect(clips.map(\.id) == ["local-a", "local-b"])
        #expect(clips.allSatisfy { $0.corpus == "local" })
        #expect(clips.first?.reference == "first clip")
    }

    // MARK: Golden traces (fixed stage outputs — the per-clip contract)

    private func golden(
        id: String, reference: String, base: String,
        decision: AsrDriftGuard.Decision = .accept, fallbackTaken: Bool = false,
        raw: String? = nil, rules: String? = nil, rulesRejection: String? = nil,
        main: String? = nil, mainUsedModel: Bool = false, mainRejection: String? = nil,
        group: String? = nil, feed: String = "mock-mic"
    ) -> VoiceTraceRunner.Trace {
        VoiceTraceRunner.assemble(
            id: id, corpus: "golden", reference: reference, group: group, feed: feed,
            micSeconds: 2.0,
            baseText: base, decision: decision, fallbackTaken: fallbackTaken,
            rawText: raw ?? base, rulesText: rules ?? base, rulesRejection: rulesRejection,
            mainBackend: "apple/hybrid", mainText: main ?? base,
            mainUsedModel: mainUsedModel, mainRejection: mainRejection,
            asrMs: 45, totalMs: 200)
    }

    @Test func cleanPassTrace() {
        let trace = golden(id: "g1", reference: "call me back in five minutes",
                           base: "call me back in five minutes")
        #expect(trace.passed)
        #expect(trace.rawWER == 0)
        #expect(trace.vsRules == "tie")
        #expect(!trace.fallbackTaken)
        #expect(trace.driftDecision == "accept")
    }

    @Test func rotationSymptomTrace() {
        // Founder live report: "dictation" heard as "rotation" — an acoustic confusion no
        // cleanup stage can repair. The trace must show a failed verdict with WER 1.0 at
        // the ASR stage, not a cleanup loss.
        let trace = golden(id: "g2", reference: "dictation", base: "rotation")
        #expect(!trace.passed)
        #expect(trace.rawWER == 1.0)
        #expect(trace.vsRules == "tie")
        #expect(trace.rules.text == "rotation")
    }

    @Test func spanishDriftTrace() {
        // Founder live report: stop → Spanish-gibberish note. Shape of that failure: the
        // Ultra pass comes out non-English, the guard fires, v2 gets the same audio.
        let trace = golden(id: "g3", reference: "stop the recording",
                           base: "Chala y punto",
                           decision: .fallback(.unrecognizedShortWords),
                           fallbackTaken: true, raw: "Chala y punto")
        #expect(trace.fallbackTaken)
        #expect(trace.driftDecision == "fallback(unrecognizedShortWords)")
        #expect(!trace.passed)
    }

    @Test func cleanupWinTrace() {
        let trace = golden(id: "g4", reference: "call me back in five minutes",
                           base: "um call me back uh in five minutes",
                           rules: "call me back uh in five minutes",
                           main: "call me back in five minutes", mainUsedModel: true)
        #expect(trace.passed)
        #expect(trace.vsRules == "win")
        #expect(trace.main.usedModel)
        #expect(trace.rawWER > 0)
    }

    @Test func guardRejectionTrace() {
        // A model rewrite the guards refuse must keep its `why=` on the trace and count as
        // rules-fallback in the backend mix — never silently scored as model output.
        let trace = golden(id: "g5", reference: "buy milk and eggs",
                           base: "buy milk and eggs",
                           mainRejection: "why=rejected-by-guard(list-without-signal)")
        #expect(trace.passed)
        #expect(!trace.main.usedModel)
        #expect(trace.main.rejection == "why=rejected-by-guard(list-without-signal)")
    }

    @Test func accentGroupIsCarriedForParityBreakdown() {
        let trace = golden(id: "g6", reference: "good morning", base: "good morning",
                           group: "Indian English")
        #expect(trace.group == "Indian English")
        #expect(trace.passed)
    }

    @Test func feedLabelsDistinguishIngestionPaths() {
        let direct = golden(id: "g7", reference: "hello", base: "hello", feed: "direct")
        #expect(direct.feed == "direct")
        let mic = golden(id: "g8", reference: "hello", base: "hello")
        #expect(mic.feed == "mock-mic")
    }

    @Test func argumentsParseDirectFlagAndScoreLines() {
        let direct = Arguments(ArraySlice(["voice-trace", "--direct"]))
        #expect(direct.command == "voice-trace")
        #expect(direct.flag("direct"))
        let scoring = Arguments(ArraySlice(["voice-trace", "score-lines", "--lines", "r.txt"]))
        #expect(scoring.positional == ["score-lines"])
        #expect(scoring.string("lines") == "r.txt")
    }

    @Test func scoreLinesScoresFounderResultsOffline() throws {
        // Path (c) needs no audio, models, or network: two local pairs plus a two-line
        // results file go straight through the positional alignment + WER path.
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        // Keep `Runners.emit` (which appends to Evals/results.md) inside the temp dir.
        setenv("MURMUR_EVAL_HOME", dir.path, 1)
        defer { unsetenv("MURMUR_EVAL_HOME") }
        try EvalWAV.write(MockMicFeed.sine(hertz: 440, seconds: 0.2),
                          to: dir.appendingPathComponent("a.wav"))
        try EvalWAV.write(MockMicFeed.sine(hertz: 440, seconds: 0.2),
                          to: dir.appendingPathComponent("b.wav"))
        try JSONEncoder().encode(["a": "first clip", "b": "second clip"])
            .write(to: dir.appendingPathComponent("transcripts.json"), options: .atomic)
        let linesURL = dir.appendingPathComponent("results.txt")
        try "first clip\nsecond line wrong\n".write(to: linesURL, atomically: true, encoding: .utf8)
        let reportURL = dir.appendingPathComponent("report.json")
        let args = Arguments(ArraySlice([
            "voice-trace", "score-lines", "--lines", linesURL.path,
            "--local-dir", dir.path, "--no-web", "--report", reportURL.path,
        ]))
        try VoiceTraceRunner.scoreLines(args)
        let payload = try JSONDecoder().decode(
            LoopbackReport.self, from: Data(contentsOf: reportURL))
        #expect(payload.traces.count == 2)
        #expect(payload.traces.allSatisfy { $0.feed == "loopback" })
        #expect(payload.traces[0].passed)
        #expect(!payload.traces[1].passed)
        #expect(payload.model == "live-app (acoustic loopback)")
    }

    private struct LoopbackReport: Decodable {
        let model: String
        let traces: [VoiceTraceRunner.Trace]
    }

    @Test func decisionLabels() {        #expect(VoiceTraceRunner.decisionLabel(.accept) == "accept")
        #expect(VoiceTraceRunner.decisionLabel(.fallback(.nonLatinScript))
            == "fallback(nonLatinScript)")
        #expect(VoiceTraceRunner.decisionLabel(.fallback(.nonEnglishLanguage))
            == "fallback(nonEnglishLanguage)")
    }
}
