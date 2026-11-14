import FluidAudio
import Foundation

// Benchmarks on-device ASR latency using speech synthesized by macOS `say`.
// Usage: murmur-bench <audio-file>...

@main
struct Bench {
    static func main() async throws {
        let files = CommandLine.arguments.dropFirst()
        guard !files.isEmpty else {
            print("usage: murmur-bench <audio>...")
            return
        }
        let loadStart = Date()
        let models = try await AsrModels.downloadAndLoad(version: .v3)
        let asr = AsrManager(config: .default)
        try await asr.loadModels(models)
        print(String(format: "model load: %.2fs", Date().timeIntervalSince(loadStart)))

        let converter = AudioConverter()
        // Warm-up run so the first measurement excludes ANE compilation.
        var warm = TdtDecoderState.make()
        _ = try await asr.transcribe([Float](repeating: 0, count: 16_000), decoderState: &warm)

        for path in files {
            let samples = try converter.resampleAudioFile(path: path)
            var state = TdtDecoderState.make()
            let start = Date()
            let result = try await asr.transcribe(samples, decoderState: &state)
            let elapsed = Date().timeIntervalSince(start)
            let audioSeconds = Double(samples.count) / 16_000
            print(String(format: "%.1fs audio -> %.0fms (%.0fx RT): %@",
                         audioSeconds, elapsed * 1000, audioSeconds / elapsed, result.text))
        }
    }
}
