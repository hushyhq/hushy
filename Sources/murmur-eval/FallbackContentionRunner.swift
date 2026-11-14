import FluidAudio
import Foundation
import MurmurCore

/// `murmur-eval fallback-contention`: does loading the fallback recogniser in the background slow
/// a recognition that runs at the same time?
///
/// Measurement only. The app warms the English-only fallback (Parakeet v2) at background priority
/// once the first recogniser is ready. This times the first recogniser on public clips three
/// times: alone, while the fallback is being loaded over and over at background priority, and
/// alone again (so drift between the first and last pass is visible). It reports each pass's
/// median and slowest clip, the clip-by-clip ratio, and whether the text changed.
///
/// What it cannot show: the very first load of a model on a Mac includes a one-time compile that
/// the system then caches. Every load here is a later one, from that cache.
///
///   murmur-eval fallback-contention [--dataset librispeech-clean] [--limit 30] [--data <folder>]
///       [--max-seconds 20]
///
/// Never downloads: it stops when either model is not already on disk.
enum FallbackContentionRunner {
    struct Pass {
        var name: String
        var seconds: [Double]
        var texts: [String]

        var median: Double { seconds.sorted()[seconds.count / 2] }
        var slowest: Double { seconds.max() ?? 0 }
        var total: Double { seconds.reduce(0, +) }
    }

    /// Counts the background loads and how long each took.
    private actor Loads {
        private(set) var seconds: [Double] = []
        func add(_ value: Double) { seconds.append(value) }
    }

    static func run(_ args: Arguments) async throws {
        let dataset = args.string("dataset") ?? "librispeech-clean"
        if let reason = MicConditionsRunner.refusal(for: dataset) {
            throw EvalError.missing("murmur-eval fallback-contention: \(reason)")
        }
        for version in [AsrModelVersion.ultra, .v2] {
            guard AsrModels.modelsExist(at: AsrModels.defaultCacheDirectory(for: version), version: version) else {
                throw EvalError.missing("murmur-eval fallback-contention: \(version) is not on disk; this probe never downloads")
            }
        }
        let dataRoot = args.string("data").map { URL(fileURLWithPath: $0, isDirectory: true) } ?? Paths.data
        let limit = args.int("limit") ?? 30
        let maxSeconds = Double(args.string("max-seconds") ?? "") ?? 20

        let manifest = dataRoot.appendingPathComponent(dataset, isDirectory: true).appendingPathComponent("manifest.json")
        let listed = try JSONDecoder().decode([EvalClip].self, from: Data(contentsOf: manifest))
        var clips: [[Float]] = []
        for clip in listed where clips.count < limit {
            let samples = try AudioConverter().resampleAudioFile(path: clip.audioPath)
            guard !samples.isEmpty, Double(samples.count) / 16_000 <= maxSeconds else { continue }
            clips.append(samples)
        }
        guard !clips.isEmpty else { throw EvalError.missing("murmur-eval fallback-contention: no clips under \(dataRoot.path)") }
        let audioSeconds = Double(clips.reduce(0) { $0 + $1.count }) / 16_000

        let engine = try await Engine.load(.ultra)
        _ = try await pass("warm-up", clips: Array(clips.prefix(3)), engine: engine)

        let alone = try await pass("alone", clips: clips, engine: engine)

        let loads = Loads()
        let loading = Task(priority: .background) {
            while !Task.isCancelled {
                let started = Date()
                guard (try? await Engine.load(.v2)) != nil else { return }
                await loads.add(Date().timeIntervalSince(started))
            }
        }
        // Let the first load get going before the timed pass starts.
        try await Task.sleep(for: .milliseconds(300))
        let whileLoading = try await pass("while the fallback loads", clips: clips, engine: engine)
        loading.cancel()
        _ = await loading.value
        let loadSeconds = await loads.seconds

        let aloneAgain = try await pass("alone again", clips: clips, engine: engine)

        let ratios = zip(whileLoading.seconds, zip(alone.seconds, aloneAgain.seconds))
            .map { loaded, base in loaded / max(min(base.0, base.1), 0.000_1) }
            .sorted()
        let changed = zip(alone.texts, whileLoading.texts).filter { $0 != $1 }.count
        func line(_ pass: Pass) -> String {
            String(format: "  - %@: median %.0f ms, slowest %.0f ms, total %.1f s",
                   pass.name, pass.median * 1_000, pass.slowest * 1_000, pass.total)
        }
        let loadLine = loadSeconds.isEmpty
            ? "  - no fallback load finished during the pass"
            : String(format: "  - fallback loads finished during and after the pass: %d, median %.1f s, slowest %.1f s",
                     loadSeconds.count, loadSeconds.sorted()[loadSeconds.count / 2], loadSeconds.max() ?? 0)
        Runners.emit(
            "### Fallback load contention · \(dataset) · \(clips.count) clips, \(Int(audioSeconds)) s of audio · ultra, v2 loading at background priority\n"
                + [line(alone), line(whileLoading), line(aloneAgain), loadLine,
                   String(format: "  - clip-by-clip, loading ÷ the faster alone pass: median ×%.2f, 95th ×%.2f, worst ×%.2f",
                          ratios[ratios.count / 2], ratios[min(ratios.count - 1, ratios.count * 95 / 100)], ratios.last ?? 0),
                   "  - texts that differ between alone and loading: \(changed)/\(clips.count)"].joined(separator: "\n"))
    }

    private static func pass(_ name: String, clips: [[Float]], engine: Engine) async throws -> Pass {
        var result = Pass(name: name, seconds: [], texts: [])
        for clip in clips {
            let (text, seconds) = try await engine.transcribe(clip)
            result.seconds.append(seconds)
            result.texts.append(text)
        }
        return result
    }
}
