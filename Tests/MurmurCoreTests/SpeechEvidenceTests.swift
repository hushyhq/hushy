import Foundation
import Testing
@testable import MurmurCore

/// A long hands-free recording with nothing said must not reach the recogniser (build 2835: 20 s, 31 invented
/// words pasted), a word said once in a long recording must, and words the recogniser puts in the quiet stretches
/// are dropped. Invented signals from a fixed sequence; the thresholds were measured with
/// `murmur-eval empty-triage` on 222 speech clips and 600 more from public dev sets.
@Suite("Speech evidence")
struct SpeechEvidenceTests {
    private let rate = 16_000

    private struct Noise {
        var state: UInt64
        mutating func next() -> Float {
            state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return Float(state >> 40) / Float(1 << 24) * 2 - 1
        }
    }

    private func room(_ seconds: Double, level: Float, seed: UInt64 = 5) -> [Float] {
        var noise = Noise(state: seed)
        return (0..<Int(seconds * Double(rate))).map { _ in noise.next() * level }
    }

    private func taps(_ base: [Float], every: Double, amplitude: Float = 0.06) -> [Float] {
        var out = base
        var noise = Noise(state: 9)
        var t = 1.0
        while t < Double(base.count) / Double(rate) - 0.1 {
            for i in 0..<480 where Int(t * Double(rate)) + i < out.count {
                out[Int(t * Double(rate)) + i] += amplitude * Float(exp(-Double(i) / 90)) * noise.next()
            }
            t += every
        }
        return out
    }

    private func breaths(_ base: [Float], every: Double) -> [Float] {
        var out = base
        var noise = Noise(state: 21)
        var t = 1.0
        while t < Double(base.count) / Double(rate) - 0.5 {
            let length = Int(0.3 * Double(rate))
            for i in 0..<length where Int(t * Double(rate)) + i < out.count {
                out[Int(t * Double(rate)) + i] += noise.next() * 0.008 * Float(sin(Double(i) / Double(length) * .pi))
            }
            t += every
        }
        return out
    }

    /// A voiced word: a 150 Hz tone with a formant, in two syllable-length bursts.
    private func word(_ seconds: Double = 0.5, level: Float = 0.08) -> [Float] {
        (0..<Int(seconds * Double(rate))).map { index in
            let t = Double(index) / Double(rate)
            let syllable = max(0, sin(t * .pi * 4))
            return Float(Double(level) * syllable * (sin(2 * .pi * 150 * t) + 0.4 * sin(2 * .pi * 750 * t)))
        }
    }

    private func place(_ clip: [Float], in base: [Float], at second: Double) -> [Float] {
        var out = base
        let start = Int(second * Double(rate))
        for (i, sample) in clip.enumerated() where start + i < out.count { out[start + i] += sample }
        return out
    }

    private func evidence(_ samples: [Float]) -> (SpeechEvidence, SpeechGate.Decision) {
        let gate = SpeechGate.evaluate(samples)
        return (SpeechEvidence(gate: gate, samples: samples, duration: Double(samples.count) / Double(rate)), gate)
    }

    @Test("runs: scattered clicks are nothing, a word is a run, a short gap stays inside it and a long one splits it")
    func runs() {
        func frames(_ pattern: [(Int, Int)], total: Int = 200) -> [Bool] {
            var out = [Bool](repeating: false, count: total)
            for (start, length) in pattern { for i in start..<(start + length) { out[i] = true } }
            return out
        }
        #expect(SpeechEvidence(frames: frames([(10, 1), (40, 2), (80, 1), (120, 2)]), duration: 4).runs.isEmpty)
        let word = SpeechEvidence(frames: frames([(50, 20)]), duration: 4)
        #expect(word.runs.count == 1)
        #expect(abs(word.speechSeconds - 0.4) < 0.001)
        #expect(SpeechEvidence(frames: frames([(50, 10), (63, 10)]), duration: 4).runs.count == 1)   // 60 ms gap bridged
        #expect(SpeechEvidence(frames: frames([(50, 10), (70, 10)]), duration: 4).runs.count == 2)   // 200 ms gap splits
    }

    @Test("twenty seconds with nothing said never reaches the recogniser, whatever the room does")
    func nothingSaid() {
        let quiet = room(20, level: 0.0003)
        let office = room(20, level: 0.002)
        let rooms: [(String, [Float])] = [
            ("silence", [Float](repeating: 0, count: 20 * rate)), ("quiet room", quiet), ("office", office),
            ("typing", taps(quiet, every: 0.18)), ("typing, office", taps(office, every: 0.15, amplitude: 0.08)),
            ("breaths and a chair", breaths(quiet, every: 2.5)), ("everything", breaths(taps(office, every: 0.2), every: 2)),
        ]
        for (name, samples) in rooms {
            let (evidence, gate) = evidence(samples)
            #expect(!evidence.accepts(gatePassed: gate.hasSpeech), "\(name): \(evidence.speechSeconds) s, voiced \(evidence.voicedSeconds) s")
        }
    }

    @Test("the old gate let a long room through on scattered frames; the evidence does not")
    func theBugItFixes() {
        let samples = breaths(taps(room(20, level: 0.002), every: 0.2), every: 2)
        let (evidence, gate) = evidence(samples)
        #expect(gate.hasSpeech, "the repro: the frame-count rule passed it")
        #expect(!evidence.accepts(gatePassed: gate.hasSpeech))
    }

    @Test("a word said once in a long recording goes through, even though it is 2 percent of it")
    func oneWordInSilence() {
        let samples = place(word(), in: room(20, level: 0.0003), at: 8)
        let (evidence, gate) = evidence(samples)
        #expect(!gate.hasSpeech, "the frame-count rule threw this away")
        #expect(evidence.accepts(gatePassed: gate.hasSpeech))
        #expect(evidence.voicedSeconds >= SpeechEvidence.minimumVoicedSeconds)
        let typing = place(word(), in: taps(room(20, level: 0.002), every: 0.2), at: 8)
        #expect(self.evidence(typing).0.accepts(gatePassed: true))
    }

    @Test("a short recording keeps the gate's call: a far-away yeah is not turned away")
    func shortRecordings() {
        let evidence = SpeechEvidence(frames: [Bool](repeating: false, count: 25), duration: 0.5)
        #expect(!evidence.isSpeech)
        #expect(evidence.accepts(gatePassed: true))
        #expect(!evidence.accepts(gatePassed: false))
        let long = SpeechEvidence(frames: [Bool](repeating: false, count: 100), duration: 2)
        #expect(!long.accepts(gatePassed: true))
    }

    @Test("whisper has no voiced frames, so it passes only when it is most of the recording")
    func whisper() {
        let hiss = room(1.0, level: 0.004, seed: 31)
        var noise = Noise(state: 77)
        let breath = (0..<Int(0.8 * Double(rate))).map { _ in noise.next() * 0.03 }
        let whole = hiss + breath + hiss
        let samples = Array(whole.prefix(Int(2.8 * Double(rate))))
        let (evidence, _) = evidence(samples)
        #expect(evidence.voicedSeconds < SpeechEvidence.minimumVoicedSeconds)
        #expect(evidence.isSpeech == (evidence.share >= SpeechEvidence.unvoicedShare && evidence.speechSeconds >= SpeechEvidence.minimumSpeechSeconds))
        let mostly = Array(breath.prefix(Int(0.8 * Double(rate))))
        #expect(self.evidence(mostly).0.share > 0.9)
    }

    @Test("voicing: a vowel repeats at a pitch period, noise and a click do not")
    func voicing() {
        let voiced = VoicingFrames.measure(word(), active: [Bool](repeating: true, count: 25))
        #expect(voiced.filter { $0 }.count >= 8)
        #expect(VoicingFrames.measure(room(0.5, level: 0.05), active: [Bool](repeating: true, count: 25)).filter { $0 }.count <= 1)
        #expect(VoicingFrames.measure(word(), active: [Bool](repeating: false, count: 25)).allSatisfy { !$0 })
    }

    // MARK: words outside speech

    private func timings(_ spec: [(String, Double, Double)]) -> [WordTiming] { spec.map { WordTiming(word: $0.0, start: $0.1, end: $0.2) } }

    private var evidenceNear4s: SpeechEvidence {
        // Speech from 4.0 s to 5.0 s in a 20 s recording.
        var frames = [Bool](repeating: false, count: 1_000)
        for i in 200..<250 { frames[i] = true }
        return SpeechEvidence(frames: frames, duration: 20)
    }

    @Test("words in the quiet stretches go; words in speech stay")
    func dropsInventedWords() {
        let heard = timings([("Thank", 0.4, 0.7), ("you", 0.8, 1.0), ("send", 4.1, 4.4), ("it", 4.5, 4.7), ("now", 4.8, 5.0), ("Bye", 15.0, 15.3)])
        let text = "Thank you send it now Bye"
        let result = NonSpeechWordFilter.apply(text: text, timings: heard, evidence: evidenceNear4s)
        #expect(result.text == "send it now")
        #expect(result.dropped == 3 && result.checked == 6)
    }

    @Test("every word outside speech leaves nothing, which the app then reports as no words")
    func dropsEverything() {
        let words = (0..<31).map { index in ("word\(index)", 0.5 + Double(index) * 0.1, 0.55 + Double(index) * 0.1) }
        let result = NonSpeechWordFilter.apply(
            text: words.map(\.0).joined(separator: " "), timings: timings(words), evidence: SpeechEvidence(frames: [Bool](repeating: false, count: 1_000), duration: 20))
        #expect(result.text.isEmpty)
        #expect(result.dropped == 31)
    }

    @Test("timings that do not line up with the text change nothing; a boosted text is only emptied as a whole")
    func mismatchesAreLeftAlone() {
        let heard = timings([("send", 4.1, 4.4), ("it", 4.5, 4.7)])
        #expect(NonSpeechWordFilter.apply(text: "send it now", timings: heard, evidence: evidenceNear4s).dropped == 0)
        #expect(NonSpeechWordFilter.apply(text: "send it", timings: nil, evidence: evidenceNear4s).text == "send it")
        let boosted = NonSpeechWordFilter.apply(text: "Send It", unboosted: "send it", timings: heard, evidence: evidenceNear4s)
        #expect(boosted.text == "Send It" && boosted.dropped == 0)
        let far = timings([("send", 12.0, 12.2), ("it", 12.3, 12.5)])
        #expect(NonSpeechWordFilter.apply(text: "Send It", unboosted: "send it", timings: far, evidence: evidenceNear4s).text.isEmpty)
    }
}
