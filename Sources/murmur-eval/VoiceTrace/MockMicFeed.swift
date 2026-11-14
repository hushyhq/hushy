@preconcurrency import AVFoundation
import Foundation
import MurmurCore

/// Mock-microphone seam (eval only): feeds a clip file through the REAL capture-side
/// conversion — native-rate PCM buffers in mic-sized frames through `StreamingResampler` —
/// i.e. injects samples where `AudioCapture` would deliver them, not a shortcut around the
/// pipeline. No behavior change to the live path: this type is only constructed by
/// `murmur-eval voice-trace`. See `Sources/murmur-eval/VoiceTrace/VoiceTraceRunner.swift`.
enum MockMicFeed {
    /// Frames per injected buffer, matching live capture's tap callback size (see
    /// `Runners.notes`, which feeds 48 kHz audio in 1,024-frame buffers).
    static let bufferFrames = 1_024

    /// Drains `url` the way the mic would deliver it: decoded at its native sample rate,
    /// pushed through `StreamingResampler` in `bufferFrames` chunks, returned as 16 kHz mono
    /// samples ready for `DictationPipeline` (which is what `AudioCapture` hands
    /// `DictationController`, post-resample).
    static func drain(file url: URL, bufferFrames: Int = bufferFrames) throws -> [Float] {
        let file = try AVAudioFile(forReading: url)
        let native = file.processingFormat
        guard let resampler = StreamingResampler(from: native) else {
            throw EvalError.missing("voice-trace: cannot resample from \(native)")
        }
        var captured: [Float] = []
        // NB: past EOF, `read(into:)` throws a generic nil error instead of returning an
        // empty buffer, so the loop is bounded by `framePosition < length` up front.
        while file.framePosition < file.length {
            guard let buffer = AVAudioPCMBuffer(
                pcmFormat: native, frameCapacity: AVAudioFrameCount(bufferFrames)) else { break }
            try file.read(into: buffer)
            if buffer.frameLength == 0 { break }
            captured += resampler.convert(buffer)
        }
        return captured
    }

    /// A synthetic tone clip for seam unit tests — no audio hardware, no network, no models.
    static func sine(
        hertz: Double, seconds: Double, sampleRate: Double = 16_000, amplitude: Float = 0.5
    ) -> [Float] {
        let count = Int(seconds * sampleRate)
        return (0..<count).map { index in
            amplitude * sin(Float(2 * Double.pi * hertz * Double(index) / sampleRate))
        }
    }
}
