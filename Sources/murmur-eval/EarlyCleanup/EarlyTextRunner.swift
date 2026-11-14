@preconcurrency import AVFoundation
import FluidAudio
import Foundation
import MurmurCore
import Synchronization

/// `murmur-eval early-text --out <dir> [--sets long,live,long2] [--limit N] [--voice Samantha] [--rate 150] [--model ultra]
///   [--pause-ms 550 --pause-every 5]`
///
/// `say` does not speak slower than about 3.4 words a second with this voice whatever `--rate` says. `--pause-ms` puts a
/// silence of that length after every `--pause-every` words, which brings the pace down to an everyday one (550 ms
/// every 5 words is about 2.5 words a second) and gives the recogniser the pauses real speech has.
///
/// What the recogniser knows while a dictation is still being spoken. Each dev dictation is spoken by `/usr/bin/say`
/// (invented text, as `reformat --via-asr` does) and the audio goes three ways:
/// - one pass over the whole recording, loudness-normalised: the transcript the app cleans (`final`);
/// - the same pass over the audio so far, every two seconds (`prefixes`), with how long each took;
/// - the while-speaking recogniser the app uses today (`SlidingWindowAsrManager`, 11 s chunks), fed in two-second steps
///   from the start, with its confirmed and not-yet-confirmed text after each step (`sliding`) and how long its
///   `finish()` takes after the last audio (`slidingStopMs`, the wait the app pays at the release today).
///
/// No cleanup model is loaded. The result is `<out>/events.json` for `murmur-eval early-clean`.
enum EarlyTextRunner {
    static let tick = 2.0

    private final class Counter: Sendable {
        private let count = Mutex(0)
        var value: Int { count.withLock { $0 } }
        func add() { count.withLock { $0 += 1 } }
    }

    static func run(_ args: Arguments) async throws {
        guard let outPath = args.string("out") else { throw EvalError.missing("early-text needs --out <folder>") }
        let out = URL(fileURLWithPath: outPath, isDirectory: true)
        let audioFolder = out.appendingPathComponent("audio", isDirectory: true)
        try FileManager.default.createDirectory(at: audioFolder, withIntermediateDirectories: true)
        let voice = args.string("voice") ?? "Samantha"
        let rate = args.int("rate") ?? 150
        let pauseMs = args.int("pause-ms") ?? 0
        let pauseEvery = max(1, args.int("pause-every") ?? 5)
        let items = try SecondPassRunner.loadItems(args)
        let started = Date()
        let loadAtStart = SecondPassRunner.loadAverages()

        // Speak everything before any inference runs: `say` under load has returned cut-off files.
        print("### Early text · \(items.count) dictations · voice \(voice) at \(rate) words a minute"
            + (pauseMs > 0 ? ", a \(pauseMs) ms pause every \(pauseEvery) words" : ""))
        var audio: [(item: SecondPassRunner.Item, url: URL)] = []
        for item in items {
            let url = audioFolder.appendingPathComponent("\(item.set)-\(item.id).wav")
            if !FileManager.default.fileExists(atPath: url.path) {
                try speak(item.spoken, voice: voice, rate: rate, pauseMs: pauseMs, pauseEvery: pauseEvery, to: url)
            }
            audio.append((item, url))
        }
        print("spoken in \(Int(Date().timeIntervalSince(started))) s")

        let engine = try await Engine.load(args.model)
        let models = try await AsrModels.downloadAndLoad(to: Engine.modelDirectory(for: args.model), version: args.model)
        var clips: [EarlyRecords.Clip] = []
        for (item, url) in audio {
            let samples = try AudioConverter().resampleAudioFile(url)
            let clip = try await measure(item, samples: samples, engine: engine, models: models)
            clips.append(clip)
            print("  \(clip.set)/\(clip.id): \(String(format: "%.1f", clip.seconds)) s, \(TextStats.wordCount(clip.final)) words heard, "
                + "\(clip.prefixes.count) passes (last \(Int(clip.prefixes.last?.ms ?? 0)) ms), final \(Int(clip.finalMs)) ms, "
                + "while-speaking finish \(Int(clip.slidingStopMs)) ms")
        }
        let file = EarlyRecords.EventsFile(
            started: ISO8601DateFormatter().string(from: started), seconds: Date().timeIntervalSince(started), voice: voice,
            rate: rate, pauseMs: pauseMs, pauseEvery: pauseEvery, tick: tick, recogniser: args.modelName, loadAtStart: loadAtStart,
            loadAtEnd: SecondPassRunner.loadAverages(), clips: clips)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(file).write(to: out.appendingPathComponent("events.json"))
        print("wrote \(out.appendingPathComponent("events.json").path): \(clips.count) dictations in \(Int(file.seconds)) s")
    }

    /// `Runners.synthesize` with a speaking rate, and the same guard against a cut-off file.
    static func speak(_ text: String, voice: String, rate: Int, pauseMs: Int = 0, pauseEvery: Int = 5, to url: URL) throws {
        let script = paused(text, ms: pauseMs, every: pauseEvery)
        let minimum = Double(max(1, TextStats.wordCount(text))) * Runners.minSecondsPerWord
        for _ in 1...Runners.synthesisAttempts {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/say")
            process.arguments = ["-v", voice, "-r", String(rate), "-o", url.path, "--data-format=LEI16@16000", script]
            try process.run()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else { throw EvalError.missing("say failed for voice \(voice)") }
            if (Runners.audioSeconds(url) ?? 0) >= minimum { return }
            try? FileManager.default.removeItem(at: url)
            Thread.sleep(forTimeInterval: 1)
        }
        throw EvalError.missing("say kept returning cut-off audio for voice \(voice)")
    }

    /// The text with `say`'s silence command after every `every` words (never after the last word).
    static func paused(_ text: String, ms: Int, every: Int) -> String {
        guard ms > 0, every > 0 else { return text }
        let words = text.split(whereSeparator: \.isWhitespace).map(String.init)
        return words.enumerated().map { index, word in
            (index + 1) % every == 0 && index + 1 < words.count ? "\(word) [[slnc \(ms)]]" : word
        }.joined(separator: " ")
    }

    static func measure(
        _ item: SecondPassRunner.Item, samples: [Float], engine: Engine, models: AsrModels
    ) async throws -> EarlyRecords.Clip {
        let seconds = Double(samples.count) / 16_000
        let clockStart = Date().timeIntervalSince1970
        func pass(_ audio: [Float]) async throws -> (TranscriptionResult, Double) {
            let start = ContinuousClock.now
            let result = try await engine.transcribeWithConfidence(LoudnessNormalizer.normalize(audio), vocabulary: .empty)
            return (result, ModelPace.ms(ContinuousClock.now - start))
        }
        let (final, finalMs) = try await pass(samples)
        var prefixes: [EarlyRecords.Heard] = []
        var t = tick
        while t < seconds {
            let (heard, ms) = try await pass(Array(samples.prefix(Int(t * 16_000))))
            prefixes.append(.init(t: t, text: heard.text, ms: ms))
            t += tick
        }
        let sliding = try await slide(samples, models: models)
        return EarlyRecords.Clip(
            set: item.set, id: item.id, spokenWords: TextStats.wordCount(item.spoken), seconds: seconds, final: final.text,
            finalConfidences: final.confidences?.map { .init(word: $0.word, confidence: $0.confidence) }, finalMs: finalMs,
            prefixes: prefixes, sliding: sliding.states, slidingStopMs: sliding.stopMs, slidingFinal: sliding.final,
            clockStart: clockStart, clockEnd: Date().timeIntervalSince1970)
    }

    /// The while-speaking recogniser, fed as the app's two-second timer feeds it, then finished with what is left.
    static func slide(_ samples: [Float], models: AsrModels) async throws -> (states: [EarlyRecords.Sliding], stopMs: Double, final: String) {
        guard let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false)
        else { throw EvalError.missing("no 16 kHz audio format") }
        let config = SlidingWindowAsrConfig.default
        let manager = SlidingWindowAsrManager(config: config)
        try await manager.loadModels(models)
        try await manager.startStreaming(source: .microphone)
        let decoded = Counter()
        let updates = await manager.transcriptionUpdates
        let watcher = Task { for await _ in updates { decoded.add() } }
        defer { watcher.cancel() }

        func feed(_ range: Range<Int>) async {
            guard !range.isEmpty, let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(range.count))
            else { return }
            buffer.frameLength = AVAudioFrameCount(range.count)
            samples.withUnsafeBufferPointer { source in
                guard let base = source.baseAddress else { return }
                buffer.floatChannelData?[0].update(from: base + range.lowerBound, count: range.count)
            }
            await manager.streamAudio(buffer)
        }

        let seconds = Double(samples.count) / 16_000
        let needed = config.chunkSeconds + config.rightContextSeconds
        var states: [EarlyRecords.Sliding] = []
        var fed = 0
        var t = tick
        while t < seconds {
            let end = Int(t * 16_000)
            await feed(fed..<end)
            fed = end
            // A chunk is decoded once the audio reaches its end plus the look-ahead; wait for the ones now due.
            let due = t >= needed ? Int((t - needed) / config.chunkSeconds) + 1 : 0
            let waitUntil = ContinuousClock.now.advanced(by: .seconds(10))
            while decoded.value < due, ContinuousClock.now < waitUntil { try await Task.sleep(for: .milliseconds(5)) }
            states.append(.init(t: t, confirmed: await manager.confirmedTranscript, volatile: await manager.volatileTranscript))
            t += tick
        }
        let stopStart = ContinuousClock.now
        await feed(fed..<samples.count)
        let final = try await manager.finish()
        return (states, ModelPace.ms(ContinuousClock.now - stopStart), final.trimmingCharacters(in: .whitespacesAndNewlines))
    }
}
