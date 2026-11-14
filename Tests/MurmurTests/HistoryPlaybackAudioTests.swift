import AVFoundation
import Foundation
import MurmurCore
import Testing
@testable import Murmur

/// History plays a dictation back at the same lifted level the recogniser heard
/// (`LoudnessNormalizer`), while the saved file stays the raw microphone recording. All audio
/// here is synthetic (sine bursts over a near-silent floor); no real recording is touched.
@Suite("HistoryPlaybackAudio")
struct HistoryPlaybackAudioTests {
    private let rate = 16_000

    /// 100 ms sine bursts at `amplitude` separated by 100 ms of a very quiet floor: speech-like
    /// contrast without a real recording.
    private func bursts(seconds: Int, amplitude: Float, floor: Float = 0.000_05) -> [Float] {
        (0..<(seconds * rate)).map { index in
            let inBurst = (index / 1_600) % 2 == 0
            let tone = sin(2 * Float.pi * 220 * Float(index) / Float(rate))
            return tone * (inBurst ? amplitude : floor)
        }
    }

    /// RMS of the loudest 30% of 20 ms frames, the same voiced-level view the normaliser uses.
    private func voicedLevel(_ samples: [Float]) -> Float {
        let frame = 320
        var energies: [Float] = []
        var start = 0
        while start + frame <= samples.count {
            let sum = samples[start..<(start + frame)].reduce(Float(0)) { $0 + $1 * $1 }
            energies.append((sum / Float(frame)).squareRoot())
            start += frame
        }
        let top = energies.sorted(by: >).prefix(max(1, energies.count * 3 / 10))
        return top.reduce(0, +) / Float(top.count)
    }

    private func decode(_ wav: Data) -> [Float] {
        let body = [UInt8](wav.dropFirst(HistoryPlaybackAudio.headerByteCount))
        return stride(from: 0, to: body.count - 1, by: 2).map { offset in
            let raw = UInt16(body[offset]) | (UInt16(body[offset + 1]) << 8)
            return Float(Int16(bitPattern: raw)) / 32_768
        }
    }

    @Test("a quiet take plays back near the recogniser's target level")
    func quietTakeIsLifted() {
        let quiet = bursts(seconds: 3, amplitude: 0.004)
        let played = decode(HistoryPlaybackAudio.wavData(for: quiet))
        #expect(played.count == quiet.count)
        let level = voicedLevel(played)
        #expect(abs(level - LoudnessNormalizer.targetRMS) < 0.02, "level \(level)")
        #expect(level > voicedLevel(quiet) * 10)
    }

    @Test("a loud take is left alone")
    func loudTakeUnchanged() {
        let loud = bursts(seconds: 2, amplitude: 0.4)
        let played = decode(HistoryPlaybackAudio.wavData(for: loud))
        #expect(played.count == loud.count)
        #expect(zip(played, loud).allSatisfy { abs($0 - $1) < 1.0 / 16_384 })
    }

    @Test("silence is not amplified into noise")
    func silenceStaysSilent() {
        let silence = [Float](repeating: 0, count: 2 * rate)
        let hiss = (0..<(2 * rate)).map { Float($0 % 2 == 0 ? 1 : -1) * 0.000_1 }
        #expect(decode(HistoryPlaybackAudio.wavData(for: silence)).allSatisfy { $0 == 0 })
        #expect((decode(HistoryPlaybackAudio.wavData(for: hiss)).map(abs).max() ?? 0) < 0.001)
    }

    @Test("lifted audio never clips")
    func neverClips() {
        let played = decode(HistoryPlaybackAudio.wavData(for: bursts(seconds: 2, amplitude: 0.003)))
        #expect((played.map(abs).max() ?? 0) <= 1.0)
    }

    @Test("the output is a 16 kHz mono 16-bit WAV that AVAudioPlayer accepts")
    func isPlayableWAV() throws {
        let data = HistoryPlaybackAudio.wavData(for: bursts(seconds: 1, amplitude: 0.01))
        let player = try AVAudioPlayer(data: data)
        #expect(abs(player.duration - 1.0) < 0.01)
        #expect(player.format.channelCount == 1)
        #expect(player.format.sampleRate == 16_000)
    }

    @Test("preparing a saved file lifts the playback copy and leaves the file untouched")
    func fileOnDiskStaysRaw() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("take.wav")
        try WAVWriter.write(bursts(seconds: 2, amplitude: 0.004), to: url)
        let before = try Data(contentsOf: url)

        let data = try HistoryPlaybackAudio.prepare(path: url.path, key: nil)

        #expect(voicedLevel(decode(data)) > 0.05)
        #expect(try Data(contentsOf: url) == before)
    }

    @Test("a missing file throws so the caller can fall back")
    func missingFileThrows() {
        #expect(throws: (any Error).self) {
            try HistoryPlaybackAudio.prepare(path: "/nonexistent/take.wav", key: nil)
        }
    }
}
