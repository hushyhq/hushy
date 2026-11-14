import Foundation
import Testing

@testable import murmur_eval
@testable import MurmurCore

/// The simulated microphone conditions behind `murmur-eval mics`, on invented signals: each
/// transform does what its name says, so a number in the report means what the row says.
@Suite("Simulated microphone conditions")
struct MicSimulationTests {
    /// One second of a 440 Hz tone at the given peak.
    private func tone(_ peak: Float, seconds: Double = 1) -> [Float] {
        (0..<Int(seconds * 16_000)).map { peak * sin(2 * Float.pi * 440 * Float($0) / 16_000) }
    }

    private func rms(_ samples: [Float]) -> Float { StreamingResampler.rms(samples) }

    @Test("a level change is the stated number of decibels")
    func gain() {
        let quiet = MicSimulation.gain(tone(0.5), dB: -20)
        #expect(abs(rms(quiet) / rms(tone(0.5)) - 0.1) < 0.001)
        #expect(abs(rms(MicSimulation.gain(tone(0.5), dB: -30)) / rms(tone(0.5)) - 0.031_6) < 0.001)
    }

    @Test("a lost start is exact zeros for that long, the same length, and the rest untouched")
    func loseStart() {
        let original = tone(0.5, seconds: 2)
        let lost = MicSimulation.loseStart(original, seconds: 0.5)
        #expect(lost.count == original.count)
        #expect(lost[..<8_000].allSatisfy { $0 == 0 })
        #expect(Array(lost[8_000...]) == Array(original[8_000...]))
        #expect(MicSimulation.loseStart(original, seconds: 10).allSatisfy { $0 == 0 }, "longer than the clip: all of it")
    }

    @Test("a lead-in adds zeros before the speech and loses nothing")
    func leadIn() {
        let original = tone(0.5)
        let led = MicSimulation.leadIn(original, seconds: 1)
        #expect(led.count == original.count + 16_000)
        #expect(led[..<16_000].allSatisfy { $0 == 0 })
        #expect(Array(led[16_000...]) == original)
    }

    @Test("the noise gate passes sound over its threshold and mutes sound under it to exact zeros")
    func noiseGate() {
        let loud = tone(0.1)            // RMS 0.07, about -23 dBFS
        let faint = tone(0.002)         // RMS 0.0014, about -57 dBFS
        #expect(MicSimulation.noiseGate(loud, thresholdDBFS: -45) == loud)
        #expect(MicSimulation.noiseGate(faint, thresholdDBFS: -45).allSatisfy { $0 == 0 })
        #expect(MicSimulation.noiseGate(faint, thresholdDBFS: -65) == faint)
    }

    @Test("the gate holds open for a moment after the sound drops, then closes")
    func noiseGateHold() {
        let samples = tone(0.1, seconds: 0.5) + tone(0.002, seconds: 1)
        let gated = MicSimulation.noiseGate(samples, thresholdDBFS: -45, holdSeconds: 0.15)
        #expect(Array(gated[..<8_000]) == Array(samples[..<8_000]), "the loud half second passes")
        #expect(Array(gated[8_000..<10_400]) == Array(samples[8_000..<10_400]), "0.15 s of hold")
        #expect(gated[10_560...].allSatisfy { $0 == 0 }, "then muted")
    }

    @Test("a gate that never opened mutes from the first sample: a faint onset is cut")
    func noiseGateOnset() {
        let samples = tone(0.002, seconds: 0.5) + tone(0.1, seconds: 0.5)
        let gated = MicSimulation.noiseGate(samples, thresholdDBFS: -45)
        #expect(gated[..<8_000].allSatisfy { $0 == 0 })
        #expect(Array(gated[8_000...]) == Array(samples[8_000...]))
    }

    @Test("overdrive clips at full scale, and more overdrive flattens more of the wave")
    func overdrive() {
        let mild = MicSimulation.overdrive(tone(0.3), dBOverFullScale: 6)
        let hard = MicSimulation.overdrive(tone(0.3), dBOverFullScale: 20)
        #expect(mild.allSatisfy { abs($0) <= 1 })
        #expect(mild.contains { abs($0) == 1 })
        let flat = { (samples: [Float]) in Double(samples.filter { abs($0) == 1 }.count) / Double(samples.count) }
        #expect(flat(hard) > flat(mild))
        #expect(flat(mild) > 0.5 && flat(mild) < 0.8, "6 dB over: about two thirds of a sine is clipped, got \(flat(mild))")
        #expect(MicSimulation.overdrive([0, 0, 0], dBOverFullScale: 12) == [0, 0, 0], "silence stays silence")
    }

    @Test("pink noise has more energy low than high; white noise does not")
    func pinkNoise() {
        var generator = SeededNoise(seed: 7)
        let white = generator.noise(count: 32_000)
        let pink = MicSimulation.pink(white)
        // Energy left after a 2 kHz high-pass, as a share of the whole.
        func highShare(_ samples: [Float]) -> Float {
            var filter = BiquadHighPass(cutoffHz: 2_000, sampleRate: 16_000)
            let high = filter.process(samples)
            return rms(high) * rms(high) / (rms(samples) * rms(samples))
        }
        #expect(highShare(white) > 0.6)
        #expect(highShare(pink) < 0.35, "got \(highShare(pink))")
    }

    @Test("babble mixes every voice at equal level, whatever level each was recorded at")
    func babble() {
        let loud = tone(0.5), faint = tone(0.01)
        let both = MicSimulation.babble([loud, faint], count: 16_000)
        let one = MicSimulation.babble([loud], count: 16_000)
        #expect(abs(rms(one) - 1) < 0.01, "one voice at unit level")
        #expect(rms(both) > 0.5, "two voices sum, neither vanishes")
        #expect(MicSimulation.babble([[], loud], count: 8_000).count == 8_000, "an empty voice is skipped")
        #expect(MicSimulation.babble([], count: 10) == [Float](repeating: 0, count: 10))
    }

    @Test("the conditions without ffmpeg still cover level, lost starts, the gate, noise and clipping, and say what was skipped")
    func conditionsWithoutFFmpeg() {
        let (conditions, skipped) = MicCondition.all(codec: nil, encoders: [])
        #expect(conditions.first?.name == MicCondition.cleanName)
        #expect(Set(conditions.map(\.group)) == ["level", "bluetooth", "noise gate", "noise", "clipping"])
        #expect(!conditions.contains { $0.name.contains("mSBC") || $0.name.contains("8 kHz") })
        #expect(skipped.contains { $0.contains("no ffmpeg") })
        #expect(skipped.contains { $0.contains("CVSD") }, "the codec nothing here can run is named")
        #expect(Set(conditions.map(\.name)).count == conditions.count, "every row has its own name")
    }

    @Test("a condition gives the same audio on every run")
    func deterministic() throws {
        let (conditions, _) = MicCondition.all(codec: nil, encoders: [])
        let speech = tone(0.2)
        for condition in conditions {
            var first = MicCondition.Input(index: 3, samples: speech, otherVoices: [tone(0.1), tone(0.3)], noise: SeededNoise(seed: 9))
            var second = first
            #expect(try condition.apply(&first) == condition.apply(&second), "\(condition.name)")
        }
    }

    @Test("sealed sets and a person's own recordings are refused by name; public sets are not")
    func refusals() {
        for name in ["heldout-v2", "actions-heldout", "voicelab-raw", "voicelab-raw-whisper", "ab-on-whisper", "AB-off-normal"] {
            #expect(MicConditionsRunner.refusal(for: name) != nil, "\(name)")
        }
        for name in MicConditionsRunner.defaultDatasets + ["librispeech-other", "earnings22", "peoples-speech"] {
            #expect(MicConditionsRunner.refusal(for: name) == nil, "\(name)")
        }
    }

    @Test("the report is one table row per condition, grouped, with what was not run")
    func report() {
        let report = MicConditionsRunner.Report(
            model: "ultra+guard", datasets: ["librispeech-clean"], clipsPerDataset: ["librispeech-clean": 2], audioSeconds: 120,
            results: [
                .init(condition: "clean, as recorded", group: "level", clips: 2, wer: 0.02, werWhereText: 0.02,
                      gateRejected: 0, empty: 0, heardLittle: 0),
                .init(condition: "first 1.0 s lost (zeros)", group: "bluetooth", clips: 2, wer: 0.5, werWhereText: 0.1,
                      gateRejected: 1, empty: 0, heardLittle: 1),
            ],
            skipped: ["CVSD itself"])
        let text = MicConditionsRunner.markdown(report)
        #expect(text.contains("### Microphone conditions · ultra+guard · 2 clips (librispeech-clean 2) · 2 min of audio"))
        #expect(text.contains("| clean, as recorded | 2.0% | 0.0% (0) | 0.0% (0) | 2.0% |"))
        #expect(text.contains("| **bluetooth** | | | | |"))
        #expect(text.contains("| first 1.0 s lost (zeros) | 50.0% | 50.0% (1) | 0.0% (0) | 10.0% |"))
        #expect(text.contains("Not run: CVSD itself."))
    }
}
