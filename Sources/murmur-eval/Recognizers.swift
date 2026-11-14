@preconcurrency import AVFoundation
import FluidAudio
import Foundation
import MurmurCore
import Speech

/// Anything that turns an audio file into text, so every eval can compare engines.
protocol Recognizer: Sendable {
    var name: String { get }
    /// Returns the transcript and the seconds spent recognizing (excluding file decoding).
    func transcribe(file: URL) async throws -> (text: String, seconds: Double)

    /// Confidence-aware variant so `murmur-eval e2e` can exercise the same confidence-guided
    /// cleanup path the app does end to end (TTS audio -> ASR with confidences -> cleanup).
    /// Recognizers with no confidence signal (Apple's Speech framework recognizers) inherit the
    /// default below, which reports `confidences: nil` — `SmartCleaner` treats that exactly as
    /// it did before this feature existed.
    func transcribeWithConfidence(file: URL) async throws -> (result: TranscriptionResult, seconds: Double)
}

extension Recognizer {
    func transcribeWithConfidence(file: URL) async throws -> (result: TranscriptionResult, seconds: Double) {
        let (text, seconds) = try await transcribe(file: file)
        return (TranscriptionResult(text: text), seconds)
    }
}

extension Engine: Recognizer {
    nonisolated var name: String { "parakeet" }

    func transcribe(file: URL) async throws -> (text: String, seconds: Double) {
        let samples = try AudioConverter().resampleAudioFile(file)
        let (text, seconds) = try await transcribe(samples)
        return (text, seconds)
    }

    /// Runs the base ASR pass directly (bypassing vocabulary boosting, which has no per-token
    /// confidence of its own — matches `SpeechEngine.transcribeWithConfidence`'s own tradeoff)
    /// so `e2e`'s confidence-guided cleanup path measures against real Parakeet confidences.
    func transcribeWithConfidence(file: URL) async throws -> (result: TranscriptionResult, seconds: Double) {
        let samples = try AudioConverter().resampleAudioFile(file)
        let start = Date()
        let result = try await transcribeRawResult(samples)
        let seconds = Date().timeIntervalSince(start)
        let text = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
        let confidences = result.tokenTimings.map(FluidAudioWordConfidence.aggregate)
        return (TranscriptionResult(text: text, confidences: confidences), seconds)
    }
}

extension Engine: Transcriber {
    /// `Transcriber` conformance so `DictationPipeline` can drive the eval's own ASR engine
    /// exactly the way the app drives `SpeechEngine` — same normalization, same padding.
    func transcribe(_ samples: [Float]) async throws -> String {
        try await transcribe(samples).0
    }

    /// Vocabulary-aware conformance so `DictationPipeline` (used by `e2e`/`voicelab`) can drive
    /// boosting the same way the app does.
    func transcribe(_ samples: [Float], vocabulary: VocabularyContext) async throws -> String {
        try await transcribe(samples, vocabulary: vocabulary).0
    }

    /// Confidence-aware conformance so `voicelab` (which drives `DictationPipeline.run` directly
    /// with `Engine` as the `Transcriber`, not through `RecognizerTranscriber`) also exercises
    /// the confidence-guided cleanup path on real recorded takes, not just `e2e`'s synthesized
    /// audio. Vocabulary-boosted requests intentionally drop confidences — see
    /// `transcribeWithConfidence(file:)`'s doc comment for why.
    func transcribeWithConfidence(_ samples: [Float], vocabulary: VocabularyContext) async throws -> TranscriptionResult {
        guard vocabulary.isEmpty else {
            return TranscriptionResult(text: try await transcribe(samples, vocabulary: vocabulary))
        }
        let result = try await transcribeRawResult(samples)
        let text = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
        return TranscriptionResult(text: text, confidences: result.tokenTimings.map(FluidAudioWordConfidence.aggregate))
    }
}

/// Adapts any file-based `Recognizer` (Parakeet, Apple dictation/transcriber) into the
/// sample-based `Transcriber` the pipeline expects, by round-tripping through a temp WAV.
/// Used so `e2e` can share `DictationPipeline` regardless of which engine `--engine` selects.
struct RecognizerTranscriber: Transcriber {
    let recognizer: any Recognizer

    func transcribe(_ samples: [Float]) async throws -> String {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).wav")
        defer { try? FileManager.default.removeItem(at: url) }
        try EvalWAV.write(samples, to: url)
        return try await recognizer.transcribe(file: url).text
    }

    /// Confidence-aware entry point `DictationPipeline.run` calls, so `e2e` exercises the
    /// confidence-guided cleanup path exactly like `DictationController`/`SpeechEngine` do.
    func transcribeWithConfidence(_ samples: [Float], vocabulary: VocabularyContext) async throws -> TranscriptionResult {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).wav")
        defer { try? FileManager.default.removeItem(at: url) }
        try EvalWAV.write(samples, to: url)
        return try await recognizer.transcribeWithConfidence(file: url).result
    }
}

/// Writes 16 kHz mono samples to a WAV file, matching the app's `WAVWriter` (which is not
/// visible outside the `Murmur` target) closely enough for round-tripping through the ASR file API.
enum EvalWAV {
    static func write(_ samples: [Float], to url: URL) throws {
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false)!
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: 16_000,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
        ]
        let file = try AVAudioFile(forWriting: url, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count)) else { return }
        buffer.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { source in
            buffer.floatChannelData?[0].update(from: source.baseAddress!, count: samples.count)
        }
        try file.write(from: buffer)
    }
}

/// Apple's on-device recognizers from the Speech framework (macOS 26+).
/// `dictation` is the engine behind the system's own Dictation feature.
struct AppleRecognizer: Recognizer {
    enum Kind: String { case dictation, transcriber }

    let kind: Kind
    var name: String { kind == .dictation ? "apple-dictation" : "apple-transcriber" }

    static func make(_ kind: Kind) async throws -> AppleRecognizer {
        guard #available(macOS 26.0, *) else { throw EvalError.missing("Apple SpeechAnalyzer needs macOS 26") }
        let recognizer = AppleRecognizer(kind: kind)
        let module = recognizer.module()
        if let request = try await AssetInventory.assetInstallationRequest(supporting: [module]) {
            print("  downloading Apple speech assets…")
            try await request.downloadAndInstall()
        }
        return recognizer
    }

    @available(macOS 26.0, *)
    private func module() -> any SpeechModule {
        let locale = Locale(identifier: "en-US")
        switch kind {
        case .dictation: return DictationTranscriber(locale: locale, preset: .shortDictation)
        case .transcriber: return SpeechTranscriber(locale: locale, preset: .transcription)
        }
    }

    func transcribe(file: URL) async throws -> (text: String, seconds: Double) {
        guard #available(macOS 26.0, *) else { throw EvalError.missing("macOS 26 required") }
        let audio = try AVAudioFile(forReading: file)
        let start = Date()
        let text: String
        switch kind {
        case .dictation:
            let module = DictationTranscriber(locale: Locale(identifier: "en-US"), preset: .shortDictation)
            text = try await run(module, audio: audio) { results in
                try await results.reduce(into: "") { $0 += String($1.text.characters) }
            } results: { module.results }
        case .transcriber:
            let module = SpeechTranscriber(locale: Locale(identifier: "en-US"), preset: .transcription)
            text = try await run(module, audio: audio) { results in
                try await results.reduce(into: "") { $0 += String($1.text.characters) }
            } results: { module.results }
        }
        return (text.trimmingCharacters(in: .whitespacesAndNewlines), Date().timeIntervalSince(start))
    }

    @available(macOS 26.0, *)
    private func run<Results: AsyncSequence & Sendable>(
        _ module: any SpeechModule,
        audio: AVAudioFile,
        collect: @escaping @Sendable (Results) async throws -> String,
        results: () -> Results
    ) async throws -> String {
        let analyzer = SpeechAnalyzer(modules: [module])
        let sequence = results()
        async let collected = collect(sequence)
        if let last = try await analyzer.analyzeSequence(from: audio) {
            try await analyzer.finalizeAndFinish(through: last)
        } else {
            await analyzer.cancelAndFinishNow()
        }
        return try await collected
    }
}

enum Recognizers {
    static func make(_ args: Arguments) async throws -> any Recognizer {
        switch args.string("engine") ?? "parakeet" {
        case "apple-dictation": try await AppleRecognizer.make(.dictation)
        case "apple": try await AppleRecognizer.make(.transcriber)
        default: try await Engine.load(args.model)
        }
    }
}
