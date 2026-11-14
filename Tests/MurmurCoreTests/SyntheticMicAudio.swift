import Foundation

/// Invented microphone audio for the capture tests: seeded noise, noise shaped into syllables,
/// and exact zeros, at 16 kHz. Nothing here was recorded from anyone; each signal is built from
/// a level in the test that uses it, so the numbers in a test are the numbers in the audio.
enum SyntheticMicAudio {
    static let sampleRate = 16_000

    /// A small linear congruential generator: the same seed gives the same samples on every run.
    private struct Generator {
        var state: UInt64
        mutating func next() -> Float {
            state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return Float(Int32(truncatingIfNeeded: state >> 33)) / Float(Int32.max)
        }
    }

    static func zeros(_ seconds: Double) -> [Float] {
        [Float](repeating: 0, count: Int(seconds * Double(sampleRate)))
    }

    /// Steady hiss at the given RMS (room tone, a codec's idle noise).
    static func hiss(_ seconds: Double, rms: Float, seed: UInt64) -> [Float] {
        var generator = Generator(state: seed)
        // Uniform noise in -1...1 has an RMS of 1/sqrt(3).
        let scale = rms * Float(3).squareRoot()
        return (0..<Int(seconds * Double(sampleRate))).map { _ in generator.next() * scale }
    }

    /// Noise shaped like speech: four syllables a second, each a raised cosine, with a gap after
    /// each. `rms` is the level of the whole stretch, gaps included.
    static func syllables(_ seconds: Double, rms: Float, seed: UInt64) -> [Float] {
        var generator = Generator(state: seed)
        let count = Int(seconds * Double(sampleRate))
        var shaped = [Float](repeating: 0, count: count)
        var sumSquares: Float = 0
        for index in 0..<count {
            let phase = (Double(index) / Double(sampleRate) * 4).truncatingRemainder(dividingBy: 1)
            let envelope = phase < 0.7 ? Float(0.5 - 0.5 * cos(2 * Double.pi * phase / 0.7)) : 0
            shaped[index] = generator.next() * envelope
            sumSquares += shaped[index] * shaped[index]
        }
        let actual = (sumSquares / Float(max(count, 1))).squareRoot()
        guard actual > 0 else { return shaped }
        return shaped.map { $0 * rms / actual }
    }

    static func mix(_ first: [Float], _ second: [Float]) -> [Float] {
        zip(first, second).map { $0 + $1 }
    }

    /// The level readings the pill's meter is fed: the RMS of each buffer of `size` samples
    /// (1,024 is one tap buffer from a 16 kHz headset; 341 is one from a 48 kHz microphone
    /// after resampling).
    static func readings(_ samples: [Float], buffer size: Int) -> [Float] {
        stride(from: 0, to: samples.count - size + 1, by: size).map { start in
            var sumSquares: Float = 0
            for sample in samples[start..<(start + size)] { sumSquares += sample * sample }
            return (sumSquares / Float(size)).squareRoot()
        }
    }

    static func rms(_ samples: [Float]) -> Float {
        guard !samples.isEmpty else { return 0 }
        return (samples.reduce(0) { $0 + $1 * $1 } / Float(samples.count)).squareRoot()
    }
}
