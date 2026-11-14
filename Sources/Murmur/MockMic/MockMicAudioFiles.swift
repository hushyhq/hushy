#if DEBUG
@preconcurrency import AVFoundation
import Foundation

struct MockMicAudioError: Error, CustomStringConvertible {
    let description: String
}

/// Plain WAV helpers for the clip pipeline (no sox, no afconvert): read any format as mono floats,
/// write 16-bit mono WAV, stitch per-turn clips into a meeting.
enum MockMicAudio {
    static let rate = 48_000.0

    /// Any WAV/AIFF/CAF the system can read, mixed down to mono at `rate`.
    static func readMono(_ url: URL, rate target: Double = rate) throws -> [Float] {
        let file = try AVAudioFile(forReading: url)
        let format = file.processingFormat
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(file.length)) else {
            throw MockMicAudioError(description: "cannot allocate a buffer for \(url.lastPathComponent)")
        }
        try file.read(into: buffer)
        let mono = mixDown(buffer)
        return format.sampleRate == target ? mono : try resample(mono, from: format.sampleRate, to: target)
    }

    static func duration(of url: URL) throws -> Double {
        let file = try AVAudioFile(forReading: url)
        return Double(file.length) / file.processingFormat.sampleRate
    }

    private static func mixDown(_ buffer: AVAudioPCMBuffer) -> [Float] {
        let frames = Int(buffer.frameLength)
        guard let channels = buffer.floatChannelData, frames > 0 else { return [] }
        let count = Int(buffer.format.channelCount)
        return (0..<frames).map { frame in
            var sum: Float = 0
            for channel in 0..<count { sum += channels[channel][frame] }
            return sum / Float(count)
        }
    }

    private static func resample(_ samples: [Float], from source: Double, to target: Double) throws -> [Float] {
        guard let inFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: source, channels: 1, interleaved: false),
              let outFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: target, channels: 1, interleaved: false),
              let converter = AVAudioConverter(from: inFormat, to: outFormat),
              let input = AVAudioPCMBuffer(pcmFormat: inFormat, frameCapacity: AVAudioFrameCount(samples.count)),
              let output = AVAudioPCMBuffer(pcmFormat: outFormat,
                                            frameCapacity: AVAudioFrameCount(Double(samples.count) * target / source) + 1024)
        else { throw MockMicAudioError(description: "cannot set up the resampler") }
        input.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { input.floatChannelData![0].update(from: $0.baseAddress!, count: samples.count) }
        nonisolated(unsafe) var supplied = false
        nonisolated(unsafe) let pending = input
        var failure: NSError?
        converter.convert(to: output, error: &failure) { _, status in
            if supplied { status.pointee = .endOfStream; return nil }
            supplied = true
            status.pointee = .haveData
            return pending
        }
        if let failure { throw failure }
        return Array(UnsafeBufferPointer(start: output.floatChannelData![0], count: Int(output.frameLength)))
    }

    /// 16-bit little-endian mono PCM WAV.
    static func writeWAV(_ samples: [Float], rate: Double = rate, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: rate, AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false,
        ]
        let file = try AVAudioFile(forWriting: url, settings: settings)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(samples.count)) else {
            throw MockMicAudioError(description: "cannot allocate a write buffer")
        }
        buffer.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { buffer.floatChannelData![0].update(from: $0.baseAddress!, count: samples.count) }
        try file.write(from: buffer)
    }

    /// Lead-in silence, then each part at its turn start (gaps filled with digital silence).
    static func assemble(parts: [[Float]], turns: [MockMicManifest.Turn], rate: Double = rate) -> [Float] {
        var out: [Float] = []
        for (part, turn) in zip(parts, turns) {
            let start = Int(turn.start * rate)
            if out.count < start { out += [Float](repeating: 0, count: start - out.count) }
            out += part
        }
        return out
    }

    /// Seconds from the start to the first 20 ms frame whose RMS is above `threshold` (nil when silent).
    static func onset(_ samples: [Float], rate: Double, threshold: Float = 0.01) -> Double? {
        let frame = max(Int(rate * 0.02), 1)
        var index = 0
        while index + frame <= samples.count {
            let energy = samples[index..<(index + frame)].reduce(Float(0)) { $0 + $1 * $1 } / Float(frame)
            if energy.squareRoot() > threshold { return Double(index) / rate }
            index += frame
        }
        return nil
    }
}
#endif
