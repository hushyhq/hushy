import Foundation

/// A recording whose samples cannot be what a microphone heard: values far above full scale, or
/// values that are not numbers. It is a fault in reading the device, never something a person
/// said, and such a recording must not reach the recogniser: it answers noise with words.
///
/// Seen 2026-10-14 (build 2295): recordings from the Mac's own microphone peaking at 3.8 and
/// 11.7 times full scale, against 0.04 to 0.13 for speech, and a twelve-word sentence came back
/// as one word.
public struct AudioReadFault: Equatable, Sendable {
    /// The largest magnitude among the samples that are numbers.
    public var peak: Float
    /// Samples beyond full scale (magnitude above 1).
    public var overFullScale: Int
    /// Samples that are not numbers (NaN or infinite).
    public var nonFinite: Int
    public var samples: Int

    /// A recording is faulty past this many times full scale. Full scale itself is ordinary
    /// (a clipped shout), and a device that delivers floats can pass it a little; nothing a
    /// microphone hears is twice it.
    public static let fullScaleMargin: Float = 2

    /// Nil for a recording that could be sound.
    public static func find(in samples: [Float]) -> AudioReadFault? {
        var peak: Float = 0
        var over = 0
        var nonFinite = 0
        for sample in samples {
            guard sample.isFinite else { nonFinite += 1; continue }
            let size = abs(sample)
            if size > 1 { over += 1 }
            if size > peak { peak = size }
        }
        guard nonFinite > 0 || peak > fullScaleMargin else { return nil }
        return AudioReadFault(peak: peak, overFullScale: over, nonFinite: nonFinite, samples: samples.count)
    }

    /// "peak 11.7033 · over full scale 412 of 106704 · not numbers 0".
    public var logSummary: String {
        "peak \(String(format: "%.4f", peak)) · over full scale \(overFullScale) of \(samples) · not numbers \(nonFinite)"
    }
}
