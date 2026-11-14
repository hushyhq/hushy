import Foundation

/// A recording with a few stretches no microphone could have heard (`AudioReadFault`), made
/// usable by silencing those stretches. The rest of the recording is untouched.
///
/// Why repair and not reject: on 2026-10-23 the Mac's own microphone delivered a few buffers far
/// above full scale in the first 0.6 s of two dictations (peaks 4.4 and 6.7, 366 of 108160 and
/// 618 of 124800 samples over, in 2 of 65 and 3 of 75 buffers), and the other 95% was ordinary
/// speech. Rejecting threw away what the person said.
///
/// Why silence and not clamp: `LoudnessNormalizer` takes the speech level from the loudest 30% of
/// 20 ms frames, so frames holding a spike count as the loudest and the level it sees is far above
/// the speech. Its gain then falls under the 1.2 it needs to act, and quiet speech is not lifted
/// (measured on invented speech at rms 0.009: lifted 4.6 times when clean, not lifted with two
/// spiked buffers). The recogniser's own scaling of a spike at 12 times full scale is not measured
/// here. A spike clamped to full scale still makes those frames the loudest and still reaches the
/// recogniser as a click; silence removes both. The length is kept, so every later sample stays
/// where it was.
public struct AudioReadRepair: Equatable, Sendable {
    /// The recording with every stretch around a bad sample silenced, ends faded.
    public var samples: [Float]
    /// What was wrong with the recording before the repair.
    public var fault: AudioReadFault
    /// Samples set to zero (the fades at either end are not counted).
    public var silenced: Int
    /// Separate stretches silenced.
    public var stretches: Int

    /// Silence this far (50 ms at 16 kHz) around each bad sample. The bad samples of a faulty
    /// buffer were about one in nine and spread across it (366 of two 1664-sample buffers), so the
    /// stretch from the first bad sample to the last covers the buffer; this covers the part of a
    /// buffer between them and the next sample that is sound, and the resampler's own ringing.
    public static let guardSamples = 800

    /// A cosine fade of this many samples (5 ms) leaves the sound next to a silenced stretch, so
    /// the edge is not a click.
    public static let fadeSamples = 80

    /// A recording is repaired only if the silenced part is at most this share of it. The two
    /// cases of 2026-10-23 come to about 3% and 5% with the guard; a quarter leaves room for a
    /// worse burst. Past it, most of what was heard came from a device that could not be read, and
    /// the rest cannot be trusted to be words: the recording is a fault, as before.
    public static let maxSilencedShare = 0.25

    /// The repaired recording, or nil when there is nothing to repair (the recording is sound) or
    /// it cannot be repaired (too much of it is bad). In the second case `AudioReadFault.find`
    /// still finds the fault in the original samples, and the dictation fails as it did before.
    public static func attempt(_ samples: [Float]) -> AudioReadRepair? {
        guard let fault = AudioReadFault.find(in: samples) else { return nil }
        let budget = Int(Double(samples.count) * maxSilencedShare)
        guard let stretches = stretches(around: samples, budget: budget) else { return nil }
        var repaired = samples
        for stretch in stretches { fade(&repaired, around: stretch) }
        for stretch in stretches { repaired.replaceSubrange(stretch, with: repeatElement(0, count: stretch.count)) }
        return AudioReadRepair(samples: repaired, fault: fault, silenced: stretches.reduce(0) { $0 + $1.count },
                               stretches: stretches.count)
    }

    /// "silenced 3200 of 108160 samples in 1 stretch · was peak 4.3576 · over full scale 366 · not numbers 0".
    public var logSummary: String {
        "silenced \(silenced) of \(samples.count) samples in \(stretches) \(stretches == 1 ? "stretch" : "stretches")"
            + " · was peak \(String(format: "%.4f", fault.peak)) · over full scale \(fault.overFullScale)"
            + " · not numbers \(fault.nonFinite)"
    }

    /// The stretches to silence, in order and not touching: `guardSamples` either side of every
    /// sample beyond full scale or not a number. Nil as soon as they would pass `budget` samples.
    private static func stretches(around samples: [Float], budget: Int) -> [Range<Int>]? {
        var found: [Range<Int>] = []
        var total = 0
        for (index, sample) in samples.enumerated() where !(abs(sample) <= 1) {   // also true for NaN
            let start = max(0, index - guardSamples)
            let end = min(samples.count, index + guardSamples + 1)
            if let last = found.last, start <= last.upperBound {
                total += max(0, end - last.upperBound)
                found[found.count - 1] = last.lowerBound..<max(end, last.upperBound)
            } else {
                total += end - start
                found.append(start..<end)
            }
            if total > budget { return nil }
        }
        return found
    }

    /// Brings the samples either side of `stretch` down towards it, so it is entered and left
    /// without a step. Only multiplies, so it never raises a sample.
    private static func fade(_ samples: inout [Float], around stretch: Range<Int>) {
        for step in 0..<fadeSamples {
            let gain = 0.5 - 0.5 * cos(Float.pi * Float(step + 1) / Float(fadeSamples + 1))   // 0 at the stretch
            let before = stretch.lowerBound - 1 - step
            let after = stretch.upperBound + step
            if before >= 0 { samples[before] *= gain }
            if after < samples.count { samples[after] *= gain }
        }
    }
}
