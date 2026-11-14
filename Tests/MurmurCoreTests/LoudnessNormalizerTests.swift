import Testing
@testable import MurmurCore

@Suite("LoudnessNormalizer")
struct LoudnessNormalizerTests {
    @Test("a whisper-level tone is brought up toward the target RMS")
    func whisperIsAmplified() {
        // ~34 dB down from targetRMS, similar to the whisper eval's -25/-30 dB clips.
        let samples = SyntheticAudio.tone(count: 16_000, amplitude: 0.0015)
        let normalized = LoudnessNormalizer.normalize(samples)
        let before = AudioMetering.measure(samples).rms
        let after = AudioMetering.measure(normalized).rms
        #expect(after > before * 5, "expected substantial amplification, got \(before) -> \(after)")
    }

    @Test("already-loud audio is left alone")
    func loudAudioUnchanged() {
        let samples = SyntheticAudio.tone(count: 16_000, amplitude: 0.3)
        let normalized = LoudnessNormalizer.normalize(samples)
        #expect(normalized == samples)
    }

    @Test("digital silence is left alone")
    func silenceUnchanged() {
        let samples = [Float](repeating: 0, count: 16_000)
        let normalized = LoudnessNormalizer.normalize(samples)
        #expect(normalized == samples)
    }

    @Test("normalized output never exceeds full scale")
    func neverClips() {
        let samples = SyntheticAudio.whisperBursts(totalCount: 32_000, burstAmplitude: 0.002, floorAmplitude: 0.0003)
        let normalized = LoudnessNormalizer.normalize(samples)
        #expect(normalized.allSatisfy { abs($0) <= 1.0 })
    }

    @Test("a noisy whisper does not have its noise floor amplified past the safety limit")
    func noiseFloorCapped() {
        // Whisper bursts sitting on a relatively noisy floor (already 0.004, vs a clean
        // room's ~0.0003): amplifying by the full whisper gain would blast the hiss up too.
        let samples = SyntheticAudio.whisperBursts(totalCount: 32_000, burstAmplitude: 0.006, floorAmplitude: 0.004)
        let normalized = LoudnessNormalizer.normalize(samples)
        let floorAfter = AudioMetering.measure(normalized).noiseFloor
        #expect(floorAfter <= LoudnessNormalizer.maxNoiseFloorAfterGain * 1.05)
    }

    @Test("a clean whisper (low floor between bursts) reaches a higher gain than the old 30x cap allowed")
    func gainExceedsOldCap() {
        // Bursts far above a very clean floor: the noise-floor cap only bites when the floor
        // itself is non-trivial, so a genuinely clean whisper should get the full whisper-level
        // gain the higher `maxGain` now allows.
        let samples = SyntheticAudio.whisperBursts(totalCount: 32_000, burstAmplitude: 0.001, floorAmplitude: 0.00005)
        let normalized = LoudnessNormalizer.normalize(samples)
        let before = AudioMetering.measure(samples).rms
        let after = AudioMetering.measure(normalized).rms
        let effectiveGain = after / before
        #expect(effectiveGain > 30, "expected gain above the old 30x cap, got \(effectiveGain)x")
    }

    @Test("shared raw metrics preserve gate and normalized samples bit for bit")
    func sharedMetricsAreBitExact() {
        let recordings = [
            [Float](),
            [Float](repeating: 0, count: 16_000),
            SyntheticAudio.tone(count: 16_000, amplitude: 0.2),
            SyntheticAudio.whisperBursts(totalCount: 32_000, burstAmplitude: 0.002,
                                         floorAmplitude: 0.0003),
        ]
        for samples in recordings {
            let metrics = AudioMetering.measure(samples)
            #expect(SpeechGate.evaluate(samples, metrics: metrics) == SpeechGate.evaluate(samples))
            let reused = LoudnessNormalizer.normalize(samples, metrics: metrics)
            let direct = LoudnessNormalizer.normalize(samples)
            #expect(reused.map(\.bitPattern) == direct.map(\.bitPattern))
        }
    }
}
