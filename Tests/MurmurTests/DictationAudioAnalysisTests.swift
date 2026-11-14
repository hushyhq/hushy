import Foundation
import Testing
@testable import Murmur

/// What the dictation controller asks of a finished recording before the recogniser sees it:
/// a long hands-free recording of a room with nothing said goes no further.
@Suite("Dictation audio analysis", .timeLimit(.minutes(1)))
struct DictationAudioAnalysisTests {
    private let rate = 16_000

    private func room(seconds: Int) -> [Float] {
        var state: UInt64 = 3
        return (0..<seconds * rate).map { _ in
            state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return (Float(state >> 40) / Float(1 << 24) * 2 - 1) * 0.002
        }
    }

    private func addNoises(_ base: [Float]) -> [Float] {
        var out = base
        var state: UInt64 = 8
        func next() -> Float { state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407; return Float(state >> 40) / Float(1 << 24) * 2 - 1 }
        var t = 1.0
        while t < Double(base.count) / Double(rate) - 0.6 {
            let start = Int(t * Double(rate))
            for i in 0..<480 { out[start + i] += 0.07 * Float(exp(-Double(i) / 90)) * next() }          // a key
            for i in 0..<4_800 where (start + 1_600 + i) < out.count {                                      // a breath
                out[start + 1_600 + i] += next() * 0.008 * Float(sin(Double(i) / 4_800 * .pi))
            }
            t += 0.7
        }
        return out
    }

    private func word(at second: Double, in base: [Float]) -> [Float] {
        var out = base
        let start = Int(second * Double(rate))
        for i in 0..<8_000 where start + i < out.count {
            let t = Double(i) / Double(rate)
            out[start + i] += Float(0.08 * max(0, sin(t * .pi * 4)) * (sin(2 * .pi * 150 * t) + 0.4 * sin(2 * .pi * 750 * t)))
        }
        return out
    }

    @Test("20 s of a room with key taps and breaths passed the gate, and no longer goes to the recogniser")
    func longRoomIsNotSpeech() {
        let analysis = DictationAudioAnalysis.analyze(addNoises(room(seconds: 20)))
        #expect(analysis.gate.hasSpeech, "the frame-count rule alone would have passed it")
        #expect(!analysis.hasSpeech)
    }

    @Test("a word in the same room does")
    func wordInTheRoom() {
        let analysis = DictationAudioAnalysis.analyze(word(at: 9, in: addNoises(room(seconds: 20))))
        #expect(analysis.hasSpeech)
        #expect(analysis.evidence.runs.contains { $0.start > 8.5 && $0.end < 10.5 })
    }

    @Test("silence is no speech, and a short blip of sound keeps the gate's call")
    func silenceAndShort() {
        #expect(!DictationAudioAnalysis.analyze([Float](repeating: 0, count: 20 * rate)).hasSpeech)
        #expect(DictationAudioAnalysis.analyze(word(at: 0, in: room(seconds: 1).prefix(rate / 2).map { $0 })).hasSpeech)
    }
}
