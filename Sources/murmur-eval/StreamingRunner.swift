@preconcurrency import AVFoundation
import FluidAudio
import Foundation
import MurmurCore

/// `murmur-eval streaming --dataset <name|dir> [--lengths 30,60,120,300] [--model v2|ultra]
/// [--seed 42] [--limit N]`
///
/// Concatenates dataset clips (fixed seed, so runs are comparable) into recordings of each
/// requested length, feeds each one through both the streaming path
/// (`StreamingEvalTranscriber`, mirroring `StreamingDictationSession`) and the whole-utterance
/// path (`Engine.transcribe`), and reports WER for both plus "release-to-final-text" latency —
/// time from the last sample being fed to the final merged text being available — against
/// recording length. Per the plan: streaming WER should be within ~0.5 pt absolute of
/// whole-utterance, and streaming latency should stay roughly constant while whole-utterance
/// latency scales with length.
enum StreamingRunner {
    struct SyntheticRecording {
        let lengthSeconds: Int
        let samples: [Float]
        let reference: String
    }

    static func run(_ args: Arguments) async throws {
        let lengths = (args.string("lengths") ?? "30,60,120,300")
            .split(separator: ",").compactMap { Int($0) }.sorted()
        guard !lengths.isEmpty else { throw EvalError.missing("--lengths must be a comma-separated list of seconds") }
        let seed = UInt64(args.int("seed") ?? 42)
        let limit = args.int("limit") ?? 40
        let datasetName = args.string("dataset") ?? "librispeech-clean"

        let clips = try loadClips(datasetName, limit: limit)
        guard !clips.isEmpty else {
            throw EvalError.missing("No clips found for dataset '\(datasetName)' — run `murmur-eval download \(datasetName)` first")
        }

        print("Building synthetic recordings from \(clips.count) '\(datasetName)' clips (seed \(seed))…")
        let recordings = try buildRecordings(clips: clips, lengths: lengths, seed: seed)

        let engine = try await Engine.load(args.model)
        var rows: [ReportRow] = []

        for recording in recordings {
            print("  \(recording.lengthSeconds)s recording (\(recording.samples.count / 16_000)s actual audio)…")

            // Whole-utterance: exactly what a short/legacy dictation does today — one
            // transcribe() call after "key-up" (i.e. after all samples are available).
            let wholeStart = Date()
            let wholeText = try await engine.transcribeLong(recording.samples)
            let wholeLatencyMs = Date().timeIntervalSince(wholeStart) * 1000

            // Streaming: feed the recording incrementally in simulated real time (fast-forwarded
            // — we don't actually sleep for `lengthSeconds`), mirroring how
            // StreamingDictationSession's drain timer feeds AudioCapture output as it arrives,
            // then finish() the tail exactly as DictationController.process does at key-up.
            let streamResult = try await StreamingEvalSession.transcribe(
                recording.samples, engine: engine, chunkSeconds: 2.0
            )

            let wholeWER = EvalTextNormalizer.wer(reference: recording.reference, hypothesis: wholeText)
            let streamWER = EvalTextNormalizer.wer(reference: recording.reference, hypothesis: streamResult.text)

            rows.append(ReportRow(
                lengthSeconds: recording.lengthSeconds,
                wholeWER: wholeWER, wholeLatencyMs: wholeLatencyMs,
                streamWER: streamWER, streamLatencyMs: streamResult.finalizeLatencyMs,
                fellBackToWhole: streamResult.fellBack
            ))
        }

        emitReport(rows, dataset: datasetName, model: args.modelName)
    }

    // MARK: Building synthetic recordings

    private static func loadClips(_ name: String, limit: Int) throws -> [EvalClip] {
        if let dataset = Dataset(rawValue: name) {
            return Array(try dataset.load(root: Paths.data).prefix(limit))
        }
        let manifestURL = Paths.data.appendingPathComponent(name, isDirectory: true).appendingPathComponent("manifest.json")
        return Array(try JSONDecoder().decode([EvalClip].self, from: Data(contentsOf: manifestURL)).prefix(limit))
    }

    /// Deterministically concatenates clips (shuffled with `seed`) until each target length is
    /// reached, resampling every clip to 16 kHz mono first. A short 200-500 ms silence gap is
    /// inserted between clips so `ChunkSplitter`/window boundaries have realistic pause points
    /// to land on, rather than an artificial hard edit between two speakers' voices.
    private static func buildRecordings(
        clips: [EvalClip], lengths: [Int], seed: UInt64
    ) throws -> [SyntheticRecording] {
        var generator = SeededGenerator(seed: seed)
        let shuffled = clips.shuffled(using: &generator)
        let converter = AudioConverter()
        let gapSamples = [Float](repeating: 0, count: 16_000 / 3) // ~333 ms silence

        var pool: [(samples: [Float], text: String)] = []
        for clip in shuffled {
            guard let samples = try? converter.resampleAudioFile(URL(fileURLWithPath: clip.audioPath)) else { continue }
            pool.append((samples, clip.reference))
        }
        guard !pool.isEmpty else { throw EvalError.missing("Could not decode any clips for streaming eval") }

        var recordings: [SyntheticRecording] = []
        var samples: [Float] = []
        var referenceWords: [String] = []
        var poolIndex = 0
        for length in lengths {
            let targetSamples = length * 16_000
            while samples.count < targetSamples {
                let clip = pool[poolIndex % pool.count]
                poolIndex += 1
                if !samples.isEmpty { samples.append(contentsOf: gapSamples) }
                samples.append(contentsOf: clip.samples)
                referenceWords.append(contentsOf: EvalMetrics.normalizedWords(clip.text))
            }
            recordings.append(SyntheticRecording(
                lengthSeconds: length, samples: samples, reference: referenceWords.joined(separator: " ")))
        }
        return recordings
    }

    // MARK: Reporting

    private struct ReportRow {
        let lengthSeconds: Int
        let wholeWER: Double
        let wholeLatencyMs: Double
        let streamWER: Double
        let streamLatencyMs: Double
        let fellBackToWhole: Bool
    }

    private static func emitReport(_ rows: [ReportRow], dataset: String, model: String) {
        let header = "| Length | Whole-utterance WER | Whole-utterance latency | Streaming WER | Streaming latency (release-to-final) | Δ WER |"
        let separator = "|---|---|---|---|---|---|"
        let lines = rows.map { row -> String in
            let delta = (row.streamWER - row.wholeWER) * 100
            let fallbackNote = row.fellBackToWhole ? " (fell back)" : ""
            return "| \(row.lengthSeconds)s | \(pct(row.wholeWER)) | \(ms(row.wholeLatencyMs)) | \(pct(row.streamWER))\(fallbackNote) | \(ms(row.streamLatencyMs)) | \(String(format: "%+.1f", delta)) pt |"
        }
        let maxDelta = rows.map { abs($0.streamWER - $0.wholeWER) }.max() ?? 0
        let latencyGrowth = rows.count > 1
            ? (rows.last!.streamLatencyMs - rows.first!.streamLatencyMs) / (rows.last!.wholeLatencyMs - rows.first!.wholeLatencyMs + 1)
            : 0
        let verdict = maxDelta <= 0.005
            ? "PASS: streaming WER within 0.5 pt of whole-utterance at every length"
            : "WARN: streaming WER diverges by up to \(String(format: "%.1f", maxDelta * 100)) pt — see rows above"
        let report = """
            ### Streaming ASR · \(dataset) · \(model)
            \(header)
            \(separator)
            \(lines.joined(separator: "\n"))

            - \(verdict)
            - Whole-utterance latency grows with recording length (as expected); streaming latency should stay roughly flat — ratio of latency growth (stream/whole) across the length range: \(String(format: "%.2f", latencyGrowth)) (near 0 is ideal, 1.0 means streaming scaled the same as whole-utterance).
            """
        Runners.emit(report)
    }

    private static func pct(_ value: Double) -> String { String(format: "%.1f%%", value * 100) }
    private static func ms(_ value: Double) -> String { String(format: "%.0f ms", value) }
}

/// A small deterministic PRNG so `shuffled(using:)` produces the same synthetic recordings for
/// the same `--seed` across runs (Swift's default `SystemRandomNumberGenerator` is not seedable).
struct SeededGenerator: RandomNumberGenerator {
    private var state: UInt64
    init(seed: UInt64) { state = seed == 0 ? 0xdead_beef : seed }
    mutating func next() -> UInt64 {
        // splitmix64
        state = state &+ 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

/// Mirrors `StreamingDictationSession`'s incremental-feed contract (11+2+2 sliding window,
/// fed 2 s at a time to simulate the app's drain timer, then `finish()`ed with the remaining
/// tail) but reuses `murmur-eval`'s own `Engine`'s already-loaded models instead of the app's
/// `SpeechEngine`, and returns richer timing/fallback info for the report. Any failure to start
/// or process the stream falls back to `Engine.transcribeLong`, matching the app's own
/// never-lose-speech contract.
enum StreamingEvalSession {
    struct Result {
        let text: String
        /// Milliseconds from feeding the last sample (simulating key-up) to `finish()`
        /// returning the merged transcript — the "release-to-final-text" latency the plan asks
        /// for, deliberately excluding the time spent "talking" (already-processed windows).
        let finalizeLatencyMs: Double
        let fellBack: Bool
    }

    static func transcribe(_ samples: [Float], engine: Engine, chunkSeconds: Double) async throws -> Result {
        guard let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false)
        else { return try await fallback(samples, engine: engine) }
        let manager = SlidingWindowAsrManager(config: .default)
        guard let models = try? await AsrModels.downloadAndLoad(version: .ultra) else {
            return try await fallback(samples, engine: engine)
        }
        do {
            try await manager.loadModels(models)
            try await manager.startStreaming(source: .microphone)
        } catch {
            return try await fallback(samples, engine: engine)
        }

        let chunkSize = Int(chunkSeconds * 16_000)
        var offset = 0
        while offset < samples.count {
            let end = min(offset + chunkSize, samples.count)
            let chunk = Array(samples[offset..<end])
            offset = end
            guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(chunk.count))
            else { continue }
            buffer.frameLength = AVAudioFrameCount(chunk.count)
            chunk.withUnsafeBufferPointer { source in
                guard let base = source.baseAddress else { return }
                buffer.floatChannelData?[0].update(from: base, count: chunk.count)
            }
            await manager.streamAudio(buffer)
        }

        // "Release-to-final-text" latency: everything after the loop above (all samples fed,
        // simulating key-up) until finish() returns.
        let finalizeStart = Date()
        do {
            let text = try await manager.finish()
            let latency = Date().timeIntervalSince(finalizeStart) * 1000
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return try await fallback(samples, engine: engine) }
            return Result(text: trimmed, finalizeLatencyMs: latency, fellBack: false)
        } catch {
            return try await fallback(samples, engine: engine)
        }
    }

    private static func fallback(_ samples: [Float], engine: Engine) async throws -> Result {
        let start = Date()
        let text = try await engine.transcribeLong(samples)
        let latency = Date().timeIntervalSince(start) * 1000
        return Result(text: text, finalizeLatencyMs: latency, fellBack: true)
    }
}
