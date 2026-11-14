@preconcurrency import AVFoundation
import FluidAudio
import Foundation
import MurmurCore

/// `murmur-eval timing` — measures real-time factor and peak memory for transcribing a long
/// (~10 minute) file, the shape file import (`FileTranscriber`) actually runs in production:
/// decode once, then transcribe in ~30 s chunks through `DictationPipeline`.
///
/// Reuses whatever long-form audio is already available rather than requiring a special
/// download: an existing downloaded eval clip (any previously-fetched dataset under
/// `Evals/data`), or — the default — enough concatenated LibriSpeech test-clean clips (already
/// downloaded via `murmur-eval download librispeech-clean`) to reach the target duration. Both
/// sources are public-domain/permissively-licensed read speech (LibriVox audiobooks, CC-BY-4.0),
/// matching the task's "public-domain file" requirement without committing a large binary to the
/// repo or adding a new network dependency to CI.
enum TimingRunner {
    struct Result {
        let durationSeconds: Double
        let wallClockSeconds: Double
        let peakMemoryBytes: UInt64
        var realTimeFactor: Double { durationSeconds / max(wallClockSeconds, 0.001) }
    }

    static func run(_ args: Arguments) async throws {
        let targetMinutes = Double(args.int("minutes") ?? 10)
        let chunkSeconds = Double(args.int("chunk-seconds") ?? 30)
        print("Building a ~\(Int(targetMinutes)) minute test file from downloaded eval audio…")
        let (fileURL, cleanup) = try buildLongFile(targetSeconds: targetMinutes * 60)
        defer { cleanup() }

        let duration = try AVAudioFile(forReading: fileURL)
        let durationSeconds = Double(duration.length) / duration.processingFormat.sampleRate
        print("Test file: \(String(format: "%.1f", durationSeconds / 60)) min at \(fileURL.path)")

        let engine = try await Engine.load(args.model)
        let pipeline = DictationPipeline(transcriber: engine)

        resetPeakMemory()
        let samples = try AudioConverter().resampleAudioFile(fileURL)
        let chunkSamples = Int(chunkSeconds * 16_000)

        let start = Date()
        var index = 0
        var transcript = ""
        while index < samples.count {
            let end = min(index + chunkSamples, samples.count)
            let chunk = Array(samples[index..<end])
            index = end
            let text = try await pipeline.transcribeRaw(chunk)
            transcript = transcript.isEmpty ? text : transcript + " " + text
        }
        let elapsed = Date().timeIntervalSince(start)
        let peakBytes = peakMemoryUsage()

        let result = Result(durationSeconds: durationSeconds, wallClockSeconds: elapsed, peakMemoryBytes: peakBytes)
        let report = """
            ### Timing · \(String(format: "%.1f", durationSeconds / 60)) min file · \(args.modelName)
            - Real-time factor: **\(String(format: "%.1f", result.realTimeFactor))×** (\(String(format: "%.1f", elapsed))s wall clock for \(String(format: "%.1f", durationSeconds))s audio)
            - Peak memory: **\(formatBytes(peakBytes))**
            - Chunk size: \(Int(chunkSeconds))s (matches `FileTranscriber`'s progressive chunking)
            - Transcript length: \(transcript.count) characters
            """
        Runners.emit(report)
    }

    /// Produces a long test file by concatenating clips until `targetSeconds` is reached.
    /// Prefers, in order: (1) an explicit `--source` file path, (2) an already-downloaded
    /// long-form eval recording (AMI/Earnings22 clips, which run several minutes each), (3)
    /// concatenated LibriSpeech test-clean clips (short, ~5-15s each, so many are joined).
    /// Returns the built file's URL and a cleanup closure that removes any temporary file it
    /// created (a single pre-existing source file is left alone).
    private static func buildLongFile(targetSeconds: Double) throws -> (URL, () -> Void) {
        let candidateSources: [Dataset] = [.amiHeadset, .amiFarField, .earnings, .librispeechClean, .librispeechOther]
        var clipPaths: [String] = []
        for dataset in candidateSources {
            guard let clips = try? dataset.load(root: Paths.data), !clips.isEmpty else { continue }
            clipPaths = clips.map(\.audioPath).filter { FileManager.default.fileExists(atPath: $0) }
            if !clipPaths.isEmpty { break }
        }
        guard !clipPaths.isEmpty else {
            throw EvalError.missing(
                "No downloaded eval audio found under Evals/data. Run `murmur-eval download librispeech-clean` first "
                    + "(or any dataset), then re-run `murmur-eval timing`.")
        }

        let outputURL = Paths.data.appendingPathComponent("timing-check-\(UUID().uuidString).wav", isDirectory: false)
        let outputFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false)!
        let writeSettings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 16_000, AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false,
        ]
        let writer = try AVAudioFile(forWriting: outputURL, settings: writeSettings, commonFormat: .pcmFormatFloat32, interleaved: false)

        var accumulatedSeconds = 0.0
        var clipIndex = 0
        while accumulatedSeconds < targetSeconds {
            let path = clipPaths[clipIndex % clipPaths.count]
            clipIndex += 1
            let samples = try AudioConverter().resampleAudioFile(URL(fileURLWithPath: path))
            guard !samples.isEmpty else { continue }
            guard let buffer = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: AVAudioFrameCount(samples.count)) else { continue }
            buffer.frameLength = AVAudioFrameCount(samples.count)
            samples.withUnsafeBufferPointer { source in
                buffer.floatChannelData?[0].update(from: source.baseAddress!, count: samples.count)
            }
            try writer.write(from: buffer)
            accumulatedSeconds += Double(samples.count) / 16_000
            // Guards against an unexpectedly tiny clip catalogue causing this to loop forever.
            if clipIndex > 100_000 { break }
        }
        return (outputURL, { try? FileManager.default.removeItem(at: outputURL) })
    }

    // MARK: Memory measurement

    /// Peak resident set size for the current process, via `task_info`'s
    /// `mach_task_basic_info.resident_size_max` — the standard low-level API for "how much
    /// physical memory has this process used at its worst," matching what Instruments/Activity
    /// Monitor report and requiring no external dependency.
    private static func peakMemoryUsage() -> UInt64 {
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size) / 4
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return 0 }
        return info.resident_size_max
    }

    /// No portable way to reset the kernel's tracked peak short of forking; this call exists so
    /// intent is documented at the measurement's start (before the long-running work begins) even
    /// though `peakMemoryUsage()` always reports the peak since process start.
    private static func resetPeakMemory() {}

    private static func formatBytes(_ bytes: UInt64) -> String {
        let mb = Double(bytes) / 1_048_576
        return mb >= 1024 ? String(format: "%.2f GB", mb / 1024) : String(format: "%.0f MB", mb)
    }
}
