import Foundation
import Testing
@testable import MurmurCore

/// The rules for a dictation with no text, on invented signals. The thresholds themselves were
/// measured with `murmur-eval empty-triage` on speech clips (see `EmptyDictationTriage`).
@Suite("Empty dictation triage")
struct EmptyDictationTriageTests {
    private let rate = 16_000.0

    private func outcome(_ samples: [Float]) -> EmptyDictationTriage.Outcome {
        let seconds = Double(samples.count) / rate
        let gate = SpeechGate.evaluate(samples)
        return EmptyDictationTriage.outcome(
            duration: seconds, speechSeconds: EmptyDictationTriage.speechSeconds(gate, duration: seconds),
            hearing: InputHearing.measure(samples))
    }

    /// Low broadband room noise, from a fixed sequence so the test is the same every run.
    private func room(_ seconds: Double, level: Float) -> [Float] {
        var state: UInt64 = 11
        return (0..<Int(seconds * rate)).map { _ in
            state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return (Float(state >> 40) / Float(1 << 24) * 2 - 1) * level
        }
    }

    /// A key's press and release, as two short decaying clicks.
    private func clicks(_ base: [Float]) -> [Float] {
        var out = base
        for start in [480, max(0, base.count - 800)] {
            for i in 0..<96 where start + i < out.count { out[start + i] += 0.08 * Float(exp(-Double(i) / 18)) * (i % 2 == 0 ? 1 : -1) }
        }
        return out
    }

    /// Something shaped like a short word: a voiced tone in three syllable-length bursts.
    private func word(_ seconds: Double) -> [Float] {
        var out = room(seconds, level: 0.001)
        for (index, value) in out.enumerated() {
            let t = Double(index) / rate
            let syllable = max(0, sin(t * .pi * 5))
            out[index] = value + Float(0.08 * syllable * sin(2 * .pi * 180 * t) + 0.03 * syllable * sin(2 * .pi * 900 * t))
        }
        return out
    }

    @Test("a short press with no speech energy is dismissed: silence, room noise, key clicks")
    func accidentalTaps() {
        #expect(outcome([Float](repeating: 0, count: 8_000)) == .dismiss)
        #expect(outcome(room(0.5, level: 0.002)) == .dismiss)
        #expect(outcome(clicks(room(0.4, level: 0.0003))) == .dismiss)
        #expect(outcome(clicks(room(0.9, level: 0.002))) == .dismiss)
    }

    @Test("a short word the recogniser missed gets the brief line, never silence")
    func shortSpeech() {
        #expect(outcome(word(0.5)) == .brief)
        #expect(outcome(word(0.8)) == .brief)
    }

    @Test("a real hold with no signal at all keeps the hint")
    func deadMicrophone() {
        #expect(outcome([Float](repeating: 0, count: 24_000)) == .hint)
        #expect(outcome(room(2, level: 0.0001)) == .hint, "under the audible floor: nothing came in")
    }

    @Test("a real hold the microphone heard, with no words, is brief: the microphone works")
    func workingMicrophone() {
        #expect(outcome(room(2, level: 0.002)) == .brief)
        #expect(outcome(word(1.5)) == .brief)
    }

    @Test("the thresholds are the measured ones")
    func thresholds() {
        #expect(EmptyDictationTriage.accidentalPressSeconds == 1.0)
        #expect(EmptyDictationTriage.speechEnergySeconds == 0.23)
        #expect(EmptyDictationTriage.briefLifetime == .seconds(2))
    }
}
