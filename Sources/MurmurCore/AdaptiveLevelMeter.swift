import Foundation

/// Maps raw microphone RMS to a 0...1 display level for the pill's waveform, adapting to the
/// room's noise floor and the user's speaking volume instead of using a fixed dB range.
///
/// Apple's voice processing is off by default (see docs/research), so a whisper reaches the
/// mic at roughly -54 dBFS (RMS ~0.002) while normal speech sits around -38 dBFS (RMS ~0.013).
/// A fixed -55...-10 dB mapping barely moves for whispers. Instead this tracks:
/// - a noise floor: a slow-rising minimum, so silence settles near 0 without ever fully
///   collapsing the range (a sudden long silence shouldn't make the next whisper read as loud).
/// - a recent speech peak: a fast-attack, slow-decay maximum, so loud speech doesn't need to
///   stay loud forever for later quiet speech to still register.
///
/// The floor and peak must stay at least `minimumSpanDB` apart, so a mostly-silent room doesn't
/// amplify its own hiss into full-scale bars.
///
/// The range adapts, but both ends are held to absolute levels, so the bars cannot show sound
/// that is not there (2026-10-12: a headset that delivered zeros, then hiss at -78 dBFS, drew
/// bars at more than half height because the floor had followed the zeros down):
/// - the floor never goes below `audibleFloorDB`, the level the speech gate itself counts as
///   silence. A reading at or under it draws nothing and teaches the meter nothing lower.
/// - the top never comes below `minimumPeakDB`, 6 dB over a whisper. A whisper can fill three
///   quarters of a bar; an input 12 dB under a whisper cannot fill more than a quarter.
/// Nothing changes for an input whose quiet moments sit above the audible floor, which is every
/// ordinary room: whispered and normal speech draw exactly as before.
public struct AdaptiveLevelMeter {
    /// Minimum distance (in dB) enforced between the tracked floor and peak.
    public static let minimumSpanDB: Double = 18
    /// The lowest the tracked floor can go: `SpeechGate.absoluteFloor` (RMS 0.00025) in dBFS,
    /// about -72. Sound under it is nothing to the speech gate, so it is nothing on the bars.
    public static let audibleFloorDB: Double = 20 * log10(Double(SpeechGate.absoluteFloor))
    /// The lowest the top of the range can come: -48 dBFS (RMS 0.004), twice a whisper's level.
    public static let minimumPeakDB: Double = -48

    private var floorDB: Double
    private var peakDB: Double

    /// - Parameters:
    ///   - initialFloorDB: starting noise floor, in dBFS. Defaults to a quiet-room estimate.
    ///   - initialPeakDB: starting speech peak, in dBFS. Defaults to normal speech loudness.
    public init(initialFloorDB: Double = -60, initialPeakDB: Double = -32) {
        floorDB = max(initialFloorDB, Self.audibleFloorDB)
        peakDB = max(initialPeakDB, floorDB + Self.minimumSpanDB, Self.minimumPeakDB)
    }

    /// Feeds one RMS reading and returns the adapted 0...1 level plus the smoothed dB value,
    /// for callers that want to inspect the tracked range (e.g. tests, debugging UI).
    @discardableResult
    public mutating func push(rms: Float) -> Double {
        // Anything under the audible floor reads as the audible floor: digital zeros and
        // inaudible hiss draw as zero and cannot pull the floor down after them.
        let db = max(20 * log10(Double(max(rms, 0.000_01))), Self.audibleFloorDB)

        // Noise floor: rises slowly toward quiet readings, falls slowly too, so a single loud
        // moment can't drag it up and a single dropout can't drag it to -infinity.
        if db < floorDB {
            floorDB += (db - floorDB) * 0.02
        } else {
            floorDB += (db - floorDB) * 0.005
        }

        // Speech peak: jumps up fast on loud input, decays slowly, so the bar range reflects
        // "how loud has this person been talking recently" rather than an instant reading.
        if db > peakDB {
            peakDB += (db - peakDB) * 0.3
        } else {
            peakDB += (db - peakDB) * 0.01
        }
        peakDB = max(peakDB, floorDB + Self.minimumSpanDB, Self.minimumPeakDB)

        let span = max(peakDB - floorDB, Self.minimumSpanDB)
        return min(max((db - floorDB) / span, 0), 1)
    }

    /// Resets tracking to fresh defaults, e.g. when a new recording session starts.
    public mutating func reset() {
        self = AdaptiveLevelMeter()
    }
}
