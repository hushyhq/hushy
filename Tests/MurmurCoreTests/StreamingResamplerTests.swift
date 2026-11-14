@preconcurrency import AVFoundation
import Testing
@testable import MurmurCore

@Suite("StreamingResampler")
struct StreamingResamplerTests {
    /// A 48 kHz buffer with a 440 Hz tone on every channel, laid out like the built-in mic
    /// array (discrete channels, no speaker positions).
    private func toneBuffer(channels: UInt32, frames: AVAudioFrameCount = 4_800) -> AVAudioPCMBuffer {
        let layout = AVAudioChannelLayout(layoutTag: kAudioChannelLayoutTag_DiscreteInOrder | channels)!
        let format = AVAudioFormat(standardFormatWithSampleRate: 48_000, channelLayout: layout)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
        buffer.frameLength = frames
        for channel in 0..<Int(channels) {
            let samples = buffer.floatChannelData![channel]
            for i in 0..<Int(frames) { samples[i] = 0.3 * sin(2 * .pi * 440 * Float(i) / 48_000) }
        }
        return buffer
    }

    @Test("multichannel discrete mic input keeps its signal", arguments: [1, 3, 9] as [UInt32])
    func keepsSignal(channels: UInt32) throws {
        let buffer = toneBuffer(channels: channels)
        let resampler = try #require(StreamingResampler(from: buffer.format))
        var output: [Float] = []
        for _ in 0..<4 { output += resampler.convert(buffer) }
        #expect(output.count > 4_000)
        #expect(StreamingResampler.rms(output) > 0.1, "converted audio must not be silent")
    }
}
