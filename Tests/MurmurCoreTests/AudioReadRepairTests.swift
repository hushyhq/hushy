import Foundation
import Testing
@testable import MurmurCore

@Suite("Audio read repair: a few bad stretches silenced, the rest kept")
struct AudioReadRepairTests {
    static let rate: Float = 16_000
    /// One tap buffer of the Mac's microphone in the 2026-10-23 logs: 108160 / 65 and 124800 / 75.
    static let buffer = 1_664

    /// Invented speech: a voiced tone with harmonics, shaped into syllables of 0.25 s with a pause
    /// between words, peaking near `peak`, over a faint steady noise. Same output on every run.
    static func speech(seconds: Float = 6.76, peak: Float = 0.1) -> [Float] {
        var seed: UInt32 = 12_345
        return (0..<Int(seconds * rate)).map { index in
            let time = Float(index) / rate
            seed = seed &* 1_664_525 &+ 1_013_904_223
            let noise = (Float(seed >> 8) / Float(1 << 24) - 0.5) * 0.004
            let syllable = max(0, sin(2 * .pi * 4 * time))
            let word = time.truncatingRemainder(dividingBy: 1.2) < 0.9 ? Float(1) : 0.05
            let voice = sin(2 * .pi * 140 * time) + 0.5 * sin(2 * .pi * 420 * time) + 0.25 * sin(2 * .pi * 1_900 * time)
            return noise + peak * 0.6 * syllable * word * voice
        }
    }

    /// What a faulty tap buffer looked like: about one sample in nine beyond full scale, with the rest of the
    /// buffer ordinary. `height` is the largest.
    static func burst(_ samples: inout [Float], bufferIndex: Int, height: Float) {
        for offset in stride(from: 3, to: buffer, by: 9) {
            let index = bufferIndex * buffer + offset
            samples[index] = (offset / 9).isMultiple(of: 2) ? height : -height * 0.7
        }
    }

    static func identical(_ a: [Float], _ b: [Float], outside zone: ClosedRange<Int>) -> Bool {
        a.indices.allSatisfy { zone.contains($0) || a[$0] == b[$0] }
    }

    @Test("a clean recording is left alone, even with a clipped shout in it")
    func cleanIsUntouched() {
        var samples = Self.speech()
        #expect(AudioReadRepair.attempt(samples) == nil)
        samples[5_000] = 1.4
        #expect(AudioReadRepair.attempt(samples) == nil, "full scale and a little over it are not a fault")
    }

    @Test("2026-10-23, first case: two neighbouring buffers at 208 ms, peak 4.36, are silenced and the rest is identical")
    func firstCaseOfTheDay() throws {
        var samples = Array(Self.speech(seconds: 6.76).prefix(65 * Self.buffer))
        Self.burst(&samples, bufferIndex: 2, height: 4.3576)
        Self.burst(&samples, bufferIndex: 3, height: 4.3576)
        let repair = try #require(AudioReadRepair.attempt(samples))
        #expect(repair.samples.count == samples.count)
        #expect(AudioReadFault.find(in: repair.samples) == nil)
        #expect(repair.samples.allSatisfy { abs($0) <= 1 })
        #expect(repair.stretches == 1)
        #expect(repair.fault.overFullScale == 2 * ((Self.buffer - 3 + 8) / 9))
        // The two buffers are silent; the sound beyond the guard and the fade is exactly what was recorded.
        #expect(repair.samples[(2 * Self.buffer)..<(4 * Self.buffer)].allSatisfy { $0 == 0 })
        let guardFade = AudioReadRepair.guardSamples + AudioReadRepair.fadeSamples
        let zone = (2 * Self.buffer + 3 - guardFade)...(4 * Self.buffer - 1 + guardFade)
        #expect(Self.identical(repair.samples, samples, outside: zone))
        #expect(repair.logSummary.hasPrefix("silenced \(repair.silenced) of 108160 samples in 1 stretch · was peak 4.3576"))
    }

    @Test("2026-10-23, second case: three buffers, the first at 0 ms and the last at 624 ms, peak 6.67")
    func secondCaseOfTheDay() throws {
        var samples = Array(Self.speech(seconds: 8).prefix(75 * Self.buffer))
        for index in [0, 2, 6] { Self.burst(&samples, bufferIndex: index, height: 6.6684) }
        let repair = try #require(AudioReadRepair.attempt(samples))
        #expect(repair.samples.allSatisfy { abs($0) <= 1 })
        #expect(AudioReadFault.find(in: repair.samples) == nil)
        #expect(repair.stretches >= 1)
        #expect(Double(repair.silenced) / Double(samples.count) < 0.15, "a small part of the recording is given up")
        let tail = (8 * Self.buffer)...(samples.count - 1)
        #expect(Self.identical(repair.samples, samples, outside: 0...(tail.lowerBound - 1)) && repair.samples[tail] == samples[tail])
    }

    @Test("2026-10-14: two bursts at 3.8 and 11.7 times full scale in a 6.7 s recording are repaired")
    func theEarlierCase() throws {
        var samples = Array(Self.speech(seconds: 6.67).prefix(64 * Self.buffer))
        Self.burst(&samples, bufferIndex: 10, height: 3.8409)
        Self.burst(&samples, bufferIndex: 11, height: 3.8409)
        Self.burst(&samples, bufferIndex: 40, height: 11.7033)
        Self.burst(&samples, bufferIndex: 41, height: 11.7033)
        let repair = try #require(AudioReadRepair.attempt(samples))
        #expect(repair.stretches == 2)
        #expect(repair.samples.allSatisfy { abs($0) <= 1 })
        #expect(AudioReadFault.find(in: samples)?.peak == 11.7033)
    }

    @Test("the spikes withhold the normaliser's boost from quiet speech; repaired, the speech is lifted as if they were never there")
    func gainFollowsTheSpeech() throws {
        let clean = Self.speech(peak: 0.04)   // a quiet speaker: the normaliser lifts this by about 4.6
        var spiked = clean
        for index in [2, 3] { Self.burst(&spiked, bufferIndex: index, height: 11.7) }
        let repair = try #require(AudioReadRepair.attempt(spiked))
        // The level of the last three seconds, far from the spikes, after the normaliser each recording goes through.
        let heard = { (samples: [Float]) in AudioMetering.measure(Array(LoudnessNormalizer.normalize(samples).suffix(48_000))).rms }
        let before = AudioMetering.measure(Array(clean.suffix(48_000))).rms
        #expect(heard(clean) > 3 * before)
        #expect(heard(spiked) == before, "the spike frames hold the speech level up, so no boost is applied")
        #expect(abs(heard(repair.samples) - heard(clean)) < 0.05 * heard(clean))
    }

    @Test("spikes through most of the recording stay a fault", arguments: [4_000, 2_000, 1_000])
    func widespreadStaysAFault(every step: Int) {
        var samples = Self.speech()
        for index in stride(from: 100, to: samples.count, by: step) { samples[index] = 6 }
        #expect(AudioReadRepair.attempt(samples) == nil)
        #expect(AudioReadFault.find(in: samples) != nil, "and the dictation fails as before")
    }

    @Test("a recording that is mostly over full scale stays a fault")
    func mostlyOverStaysAFault() {
        var samples = Self.speech()
        for index in 0..<(samples.count * 3 / 5) { samples[index] *= 60 }
        #expect(AudioReadRepair.attempt(samples) == nil)
    }

    @Test("the share of the recording given up is bounded: just under repairs, just over does not")
    func shareBound() {
        let samples = Self.speech(seconds: 10)
        let silenced = 2 * AudioReadRepair.guardSamples + 1
        func spiked(stretches: Int) -> [Float] {
            var copy = samples
            for number in 0..<stretches { copy[2_000 + number * 5_000] = 9 }
            return copy
        }
        let fits = Int(AudioReadRepair.maxSilencedShare * Double(samples.count)) / silenced
        #expect(AudioReadRepair.attempt(spiked(stretches: fits))?.stretches == fits)
        #expect(AudioReadRepair.attempt(spiked(stretches: fits + 1)) == nil)
    }

    @Test("a few values that are not numbers are silenced, and many are a fault")
    func notNumbers() throws {
        var few = Self.speech()
        few[9_000] = .nan
        few[9_050] = .infinity
        let repair = try #require(AudioReadRepair.attempt(few))
        #expect(repair.samples.allSatisfy { $0.isFinite })
        #expect(repair.fault.nonFinite == 2)
        var many = Self.speech()
        for index in stride(from: 50, to: many.count, by: 700) { many[index] = .nan }
        #expect(AudioReadRepair.attempt(many) == nil)
        #expect(AudioReadFault.find(in: many)?.nonFinite ?? 0 > 100)
    }

    @Test("a stretch at either end of the recording is cut to the recording")
    func edges() throws {
        var samples = Self.speech(seconds: 3)
        samples[10] = 8
        samples[samples.count - 10] = -8
        let repair = try #require(AudioReadRepair.attempt(samples))
        #expect(repair.samples.count == samples.count)
        #expect(repair.samples.prefix(11).allSatisfy { $0 == 0 })
        #expect(repair.samples.suffix(11).allSatisfy { $0 == 0 })
        #expect(repair.stretches == 2)
    }
}
