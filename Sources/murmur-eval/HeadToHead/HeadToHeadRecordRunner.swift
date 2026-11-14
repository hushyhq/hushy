import AVFoundation
import Foundation

/// `murmur-eval head-to-head record` — records the founder's 100 paragraphs once, as 16 kHz
/// mono WAVs (`p-NNN.wav`), so the same audio can be played into both Hushy and Wispr Flow via
/// `head-to-head play` instead of the founder speaking every paragraph twice. This is the
/// "record subcommand that saves 16 kHz WAVs per case with levels checked" alternative to using
/// Hushy's own recording mode (Notes / Voice Lab) mentioned in
/// `docs/guide/HEAD-TO-HEAD-VIRTUAL-MIC.md`.
///
/// Deliberately standalone from `Sources/Murmur/Audio/AudioCapture.swift`: that type lives in
/// the `Murmur` executable target, which `murmur-eval` cannot import (Swift executables aren't
/// importable as libraries). This uses the system default input via `AVAudioEngine` directly —
/// fine here because recording (unlike playback) is never routed through the virtual device.
enum HeadToHeadRecordRunner {
    /// Below this peak amplitude (of 1.0 full scale) a take is flagged as too quiet to trust,
    /// mirroring the app's own "Very quiet" warning in Voice Lab
    /// (`Sources/Murmur/VoiceLab/VoiceLabModel.swift`).
    static let quietPeakThreshold: Float = 0.02

    static func run(_ args: Arguments) async throws {
        guard let out = args.string("out") else { throw EvalError.missing("--out <directory> is required") }
        let count = args.int("count") ?? HeadToHeadTemplate.defaultCount
        let slots = HeadToHeadTemplate.plan(count: count)
        let directory = URL(fileURLWithPath: out, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        print("Recording \(slots.count) cases to \(directory.path).")
        print("For each case: read the cue, press Return to start, speak, press Return to stop.")
        print("Ctrl-C at any point keeps everything recorded so far; re-run to resume (existing files are skipped unless --overwrite).")

        let overwrite = args.flag("overwrite")
        let recorder = try MicRecorder()
        var quiet: [String] = []
        for (index, slot) in slots.enumerated() {
            let url = directory.appendingPathComponent("\(slot.id).wav")
            if FileManager.default.fileExists(atPath: url.path), !overwrite {
                print("[\(index + 1)/\(slots.count)] \(slot.id) — already recorded, skipping")
                continue
            }
            print("\n[\(index + 1)/\(slots.count)] \(slot.id) · \(slot.style.rawValue) · \(slot.isLong ? "LONG (over 60 s)" : "short (10–40 s)")")
            print("  \(slot.style.cue)")
            print("  Press Return to start recording…", terminator: "")
            _ = readLine()
            print("  Recording — press Return to stop…", terminator: "")
            recorder.start()
            _ = readLine()
            let samples = recorder.stop()
            let peak = samples.reduce(Float(0)) { max($0, abs($1)) }
            let seconds = Double(samples.count) / MicRecorder.sampleRate
            try EvalWAV.write(samples, to: url)
            let quietFlag = peak < quietPeakThreshold
            if quietFlag { quiet.append(slot.id) }
            print("  saved \(String(format: "%.1f", seconds))s, peak \(String(format: "%.3f", peak))\(quietFlag ? " — VERY QUIET, consider re-recording" : "")")
        }
        print("\nDone. \(slots.count) case(s) planned in \(directory.path).")
        if !quiet.isEmpty {
            print("Quiet takes to review: \(quiet.joined(separator: ", "))")
        }
    }
}

/// Records the system default microphone to 16 kHz mono Float samples between `start()` and
/// `stop()`. No device selection (recording is always the founder's real mic — the whole point
/// of gate 12 is a real recording session; only *playback* later goes through the virtual
/// device), no level callback during capture (this is a blocking CLI prompt, not a live UI) —
/// just start, buffer, stop, matching the minimal surface `head-to-head record` needs.
private final class MicRecorder {
    static let sampleRate: Double = 16_000

    private let engine = AVAudioEngine()
    private var samples: [Float] = []
    private let lock = NSLock()

    init() throws {}

    func start() {
        lock.lock(); samples = []; lock.unlock()
        let input = engine.inputNode
        let inputFormat = input.outputFormat(forBus: 0)
        let targetFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: Self.sampleRate, channels: 1, interleaved: false)!
        let converter = AVAudioConverter(from: inputFormat, to: targetFormat)
        input.installTap(onBus: 0, bufferSize: 2048, format: inputFormat) { [weak self] buffer, _ in
            guard let self else { return }
            guard let converter else {
                self.append(buffer)
                return
            }
            let ratio = Self.sampleRate / inputFormat.sampleRate
            let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 16
            guard let converted = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: capacity) else { return }
            var error: NSError?
            converter.convert(to: converted, error: &error) { _, status in
                status.pointee = .haveData
                return buffer
            }
            if error == nil { self.append(converted) }
        }
        try? engine.start()
    }

    func stop() -> [Float] {
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        lock.lock(); defer { lock.unlock() }
        return samples
    }

    private func append(_ buffer: AVAudioPCMBuffer) {
        guard let channel = buffer.floatChannelData?[0] else { return }
        let chunk = Array(UnsafeBufferPointer(start: channel, count: Int(buffer.frameLength)))
        lock.lock(); samples.append(contentsOf: chunk); lock.unlock()
    }
}
