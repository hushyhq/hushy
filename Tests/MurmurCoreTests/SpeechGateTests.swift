import Foundation
import Testing
@testable import MurmurCore

/// Synthetic signal generators shared by gate and normalizer tests, so both exercise the same
/// notion of "whisper", "room noise" and "tone" without duplicating drift-prone math.
enum SyntheticAudio {
    /// A single generator shared across calls in one test so successive bursts don't repeat
    /// identical "random" noise.
    static func lcg(seed: UInt64) -> () -> Float {
        var state = seed
        return {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            return Float(Int64(bitPattern: state >> 1) % 2_000_001) / 1_000_000 - 1
        }
    }

    /// White noise at a given peak amplitude, e.g. `noise(count:, amplitude: 0.0005)` for a
    /// quiet room.
    static func noise(count: Int, amplitude: Float, seed: UInt64 = 1) -> [Float] {
        let next = lcg(seed: seed)
        return (0..<count).map { _ in next() * amplitude }
    }

    /// A steady tone (simulating clean, non-whispered speech) at the given peak amplitude.
    static func tone(count: Int, amplitude: Float, frequency: Float = 220, sampleRate: Float = 16_000) -> [Float] {
        let step: Float = 2 * Float.pi * frequency / sampleRate
        return (0..<count).map { index -> Float in
            let phase: Float = step * Float(index)
            return amplitude * sin(phase)
        }
    }

    /// Band-limited-ish noise bursts standing in for whispered speech: quiet noise-like energy
    /// (whispers are aperiodic, not tonal) at a level well above the ambient floor but far
    /// below normal speech, separated by silence — like a few spoken words in a quiet room.
    static func whisperBursts(totalCount: Int, burstAmplitude: Float, floorAmplitude: Float, seed: UInt64 = 7) -> [Float] {
        let next = lcg(seed: seed)
        var samples = [Float](repeating: 0, count: totalCount)
        let burst = 1_600 // 100 ms at 16 kHz
        var index = 0
        var inBurst = true
        while index < totalCount {
            let amplitude = inBurst ? burstAmplitude : floorAmplitude
            let end = min(index + burst, totalCount)
            for i in index..<end { samples[i] = next() * amplitude }
            index = end
            inBurst.toggle()
        }
        return samples
    }
}

@Suite("SpeechGate")
struct SpeechGateTests {
    private let oneSecond = 16_000

    @Test("pure ambient room noise fails the gate")
    func roomNoiseFails() {
        let samples = SyntheticAudio.noise(count: oneSecond, amplitude: 0.0006)
        let decision = SpeechGate.evaluate(samples)
        #expect(!decision.hasSpeech)
    }

    @Test("digital silence (exact zeros) fails the gate")
    func digitalSilenceFails() {
        let samples = [Float](repeating: 0, count: oneSecond)
        let decision = SpeechGate.evaluate(samples)
        #expect(!decision.hasSpeech)
    }

    @Test("a clear tone passes the gate")
    func tonePasses() {
        let samples = SyntheticAudio.tone(count: oneSecond, amplitude: 0.2)
        let decision = SpeechGate.evaluate(samples)
        #expect(decision.hasSpeech)
    }

    @Test("whisper-level noise bursts above the floor pass the gate")
    func whisperBurstsPass() {
        // Bursts ~6x the ambient floor: representative of a whisper reaching the mic quietly
        // but still clearly above the room's own noise.
        let samples = SyntheticAudio.whisperBursts(totalCount: oneSecond * 2, burstAmplitude: 0.003, floorAmplitude: 0.0004)
        let decision = SpeechGate.evaluate(samples)
        #expect(decision.hasSpeech, "expected whisper bursts (floor \(decision.metrics.noiseFloor)) to clear threshold \(decision.threshold)")
    }

    @Test("very short buffers (below one frame) fail closed")
    func tooShortFailsClosed() {
        let samples = SyntheticAudio.tone(count: 10, amplitude: 0.5)
        let decision = SpeechGate.evaluate(samples)
        #expect(!decision.hasSpeech)
    }

    @Test("a handful of loud clicks in an otherwise silent take does not pass")
    func sparseClicksFail() {
        var samples = [Float](repeating: 0, count: oneSecond)
        // One 20 ms frame of a loud click among ~50 frames — well under the active-fraction bar.
        for i in 0..<320 { samples[i] = 0.5 }
        let decision = SpeechGate.evaluate(samples)
        #expect(!decision.hasSpeech)
    }

    @Test("noise floor scales with ambient level, so a noisier room needs a louder whisper")
    func thresholdTracksFloor() {
        let quietRoom = SpeechGate.evaluate(SyntheticAudio.whisperBursts(totalCount: oneSecond * 2, burstAmplitude: 0.002, floorAmplitude: 0.0002))
        let noisyRoom = SpeechGate.evaluate(SyntheticAudio.whisperBursts(totalCount: oneSecond * 2, burstAmplitude: 0.002, floorAmplitude: 0.001))
        #expect(quietRoom.threshold < noisyRoom.threshold)
    }
}

@Suite("AudioMetering")
struct AudioMeteringTests {
    @Test("empty input reports zero for every metric")
    func emptyInput() {
        let metrics = AudioMetering.measure([])
        #expect(metrics.peak == 0)
        #expect(metrics.rms == 0)
        #expect(metrics.noiseFloor == 0)
        #expect(metrics.frameCount == 0)
    }

    @Test("noise floor is lower than overall RMS when the signal has loud voiced parts")
    func floorBelowRMSForBurstySignal() {
        let samples = SyntheticAudio.whisperBursts(totalCount: 32_000, burstAmplitude: 0.05, floorAmplitude: 0.0005)
        let metrics = AudioMetering.measure(samples)
        #expect(metrics.noiseFloor < metrics.rms)
    }

    @Test("a flat tone has a noise floor close to its RMS")
    func floorMatchesRMSForSteadySignal() {
        let samples = SyntheticAudio.tone(count: 16_000, amplitude: 0.1)
        let metrics = AudioMetering.measure(samples)
        #expect(abs(metrics.noiseFloor - metrics.rms) < metrics.rms * 0.5)
    }

    @Test("a high-frequency tone reports a higher high-band ratio than a low-frequency tone")
    func highBandRatioDistinguishesFrequency() {
        // Whispers lose low-frequency voicing and rely on higher-frequency turbulent noise for
        // intelligibility (Chang et al. 2020, wTIMIT); this ratio is the diagnostic proxy for
        // that until we log real device data with voice processing on/off.
        let lowTone = SyntheticAudio.tone(count: 16_000, amplitude: 0.1, frequency: 150)
        let highTone = SyntheticAudio.tone(count: 16_000, amplitude: 0.1, frequency: 4_000)
        let lowMetrics = AudioMetering.measure(lowTone)
        let highMetrics = AudioMetering.measure(highTone)
        #expect(highMetrics.highBandRatio > lowMetrics.highBandRatio)
        #expect(highMetrics.highBandRatio > 0.5)
        #expect(lowMetrics.highBandRatio < 0.1)
    }

    @Test("high-band ratio is bounded between 0 and 1")
    func highBandRatioBounded() {
        let samples = SyntheticAudio.noise(count: 16_000, amplitude: 0.3)
        let metrics = AudioMetering.measure(samples)
        #expect(metrics.highBandRatio >= 0 && metrics.highBandRatio <= 1)
    }
}
