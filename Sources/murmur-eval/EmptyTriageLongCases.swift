import Foundation
import MurmurCore

/// Long hands-free recordings for `murmur-eval empty-triage`: nothing said, 20 seconds, in the rooms a person
/// really sits in, and a few that are not silence (a video playing, a word said once). Synthetic, seeded, the
/// same on every run. The wanted result: every "nothing said" case holds no real speech (`SpeechEvidence`),
/// while a word said once in 20 s of room still does.
enum EmptyTriageLongCases {
    static let rate = 16_000

    private static func noise(_ count: Int, level: Float, _ generator: inout EmptyTriageRunner.SeededNoise) -> [Float] {
        (0..<count).map { _ in generator.next() * level }
    }

    /// A key's tap: a short decaying burst of noise.
    private static func tap(into out: inout [Float], at start: Int, amplitude: Float, _ generator: inout EmptyTriageRunner.SeededNoise) {
        for i in 0..<480 where start + i < out.count {
            out[start + i] += amplitude * Float(exp(-Double(i) / 90)) * generator.next()
        }
    }

    /// `rate` taps a second for `seconds`, starting at `from` seconds.
    private static func typing(_ base: [Float], from: Double, seconds: Double, rate taps: Double, amplitude: Float,
                               _ generator: inout EmptyTriageRunner.SeededNoise) -> [Float] {
        var out = base
        var t = from
        while t < from + seconds {
            tap(into: &out, at: Int(t * Double(rate)), amplitude: amplitude, &generator)
            t += (0.5 + Double(abs(generator.next())) * 1.5) / taps
        }
        return out
    }

    /// A fan: low hum with its harmonics, broadband noise, and a slow drift in loudness.
    private static func fan(_ count: Int, level: Float, _ generator: inout EmptyTriageRunner.SeededNoise) -> [Float] {
        (0..<count).map { i in
            let t = Double(i) / Double(rate)
            let drift = Float(1 + 0.3 * sin(2 * .pi * 0.3 * t))
            let hum = Float(sin(2 * .pi * 100 * t) + 0.5 * sin(2 * .pi * 200 * t) + 0.3 * sin(2 * .pi * 300 * t))
            return drift * (hum * level * 0.6 + generator.next() * level)
        }
    }

    /// Breaths, a cough and a chair: soft noise bursts of 150 to 400 ms, a few seconds apart.
    private static func movement(_ base: [Float], level: Float, every: Double, _ generator: inout EmptyTriageRunner.SeededNoise) -> [Float] {
        var out = base
        var t = 1.0
        while t < Double(base.count) / Double(rate) - 0.5 {
            let length = Int((0.15 + Double(abs(generator.next())) * 0.25) * Double(rate))
            let start = Int(t * Double(rate))
            for i in 0..<length where start + i < out.count {
                out[start + i] += generator.next() * level * Float(sin(Double(i) / Double(length) * .pi))
            }
            t += every * (0.6 + Double(abs(generator.next())))
        }
        return out
    }

    private static func mixed(_ speech: [Float], into base: [Float], rms target: Float, at start: Int) -> [Float] {
        let level = (speech.reduce(0) { $0 + $1 * $1 } / Float(max(1, speech.count))).squareRoot()
        let gain = level > 0 ? target / level : 0
        var out = base
        for (i, sample) in speech.enumerated() where start + i < out.count { out[start + i] += sample * gain }
        return out
    }

    /// 20 s recordings. `speech` are real clips (used for the background video and the single word).
    static func make(speech: [[Float]]) -> [(name: String, samples: [Float], hasSpeech: Bool)] {
        var g = EmptyTriageRunner.SeededNoise(seed: 11)
        let n = 20 * rate
        var cases: [(String, [Float], Bool)] = []
        cases.append(("silence", [Float](repeating: 0, count: n), false))
        let quiet = noise(n, level: 0.0003, &g)
        let office = noise(n, level: 0.002, &g)
        cases.append(("room tone, quiet", quiet, false))
        cases.append(("room tone, office", office, false))
        cases.append(("fan", fan(n, level: 0.004, &g), false))
        cases.append(("fan, loud", fan(n, level: 0.012, &g), false))
        cases.append(("typing, quiet room", typing(quiet, from: 2, seconds: 16, rate: 5, amplitude: 0.05, &g), false))
        cases.append(("typing, office", typing(office, from: 2, seconds: 16, rate: 6, amplitude: 0.08, &g), false))
        cases.append(("typing in bursts, office", typing(typing(office, from: 1, seconds: 4, rate: 7, amplitude: 0.08, &g), from: 11, seconds: 5, rate: 7, amplitude: 0.08, &g), false))
        cases.append(("breaths and chair, quiet room", movement(quiet, level: 0.006, every: 3, &g), false))
        cases.append(("breaths and chair, office", movement(office, level: 0.01, every: 2, &g), false))
        cases.append(("fan + typing + breaths", movement(typing(fan(n, level: 0.004, &g), from: 3, seconds: 14, rate: 5, amplitude: 0.06, &g), level: 0.01, every: 2.5, &g), false))
        if let clip = speech.first(where: { $0.count > 3 * rate }) {
            // A video playing quietly in the room: speech, at the level a laptop speaker puts into its own mic.
            let loop = Array((clip + clip + clip + clip + clip + clip + clip).prefix(n))
            for (label, level) in [("very quiet", Float(0.0006)), ("quiet", Float(0.0015)), ("low", Float(0.004))] {
                cases.append(("video in the background, \(label)", mixed(loop, into: office, rms: level, at: 0), false))
            }
        }
        if let word = speech.first(where: { $0.count < Int(0.9 * Double(rate)) && $0.count > Int(0.25 * Double(rate)) }) {
            cases.append(("one word in 20 s of quiet room", mixed(word, into: quiet, rms: 0.05, at: 8 * rate), true))
            cases.append(("one word in 20 s of office", mixed(word, into: office, rms: 0.05, at: 8 * rate), true))
            cases.append(("one whispered word in 20 s of quiet room", mixed(word, into: quiet, rms: 0.004, at: 8 * rate), true))
            cases.append(("one word and typing, office", mixed(word, into: typing(office, from: 2, seconds: 16, rate: 5, amplitude: 0.08, &g), rms: 0.05, at: 8 * rate), true))
        }
        return cases.map { (name: $0.0, samples: $0.1, hasSpeech: $0.2) }
    }
}
