import Foundation

/// How much of a recording held any sound at all, measured after a dictation produced no text.
///
/// The recording's overall level cannot tell a microphone problem from a quiet voice. A whisper
/// into the Mac's own microphone has an RMS near 0.002 and is recognised; a Bluetooth headset
/// whose call link came up late gave recordings with an RMS of 0.008 and 0.011 that held a fifth
/// to a third of a second of sound each (2026-10-12). What separates them is time: how long the
/// microphone delivered anything. So this counts 20 ms frames, in seconds:
/// - `soundSeconds`: frames at or above `audibleFloor`, the level the speech gate counts as
///   silence. A working microphone in a room sits above it even between words.
/// - `deadSeconds`: frames of exact zeros. No microphone's own noise is exactly zero, so these
///   are a device that sent nothing: a link not yet up, a muted input, an idle virtual device.
/// - `quietLeadSeconds`: how long the recording ran before its first frame with sound.
///
/// Numbers only. It never says what was said, and it does not decide whether there was speech:
/// that is `SpeechGate`, which this does not change.
public struct InputHearing: Sendable, Equatable {
    public let seconds: Double
    public let soundSeconds: Double
    public let deadSeconds: Double
    public let quietLeadSeconds: Double

    public init(seconds: Double, soundSeconds: Double, deadSeconds: Double, quietLeadSeconds: Double) {
        self.seconds = seconds
        self.soundSeconds = soundSeconds
        self.deadSeconds = deadSeconds
        self.quietLeadSeconds = quietLeadSeconds
    }

    /// A frame under this RMS holds no sound: the speech gate's own floor (0.00025, about -72 dBFS).
    public static let audibleFloor: Float = SpeechGate.absoluteFloor
    /// Less sound than this in the whole recording is hardly any: one short word takes about
    /// this long to say.
    public static let littleSoundSeconds: Double = 0.5

    public static func measure(_ samples: [Float], sampleRate: Double = 16_000) -> InputHearing {
        let frame = AudioMetering.frameSamples16k
        let frameSeconds = Double(frame) / sampleRate
        let seconds = Double(samples.count) / sampleRate
        var soundFrames = 0
        var deadFrames = 0
        var firstSoundFrame: Int?
        var index = 0
        var start = 0
        while start + frame <= samples.count {
            var sum: Float = 0
            var isDead = true
            for sample in samples[start..<(start + frame)] {
                sum += sample * sample
                if sample != 0 { isDead = false }
            }
            if isDead {
                deadFrames += 1
            } else if (sum / Float(frame)).squareRoot() >= audibleFloor {
                soundFrames += 1
                if firstSoundFrame == nil { firstSoundFrame = index }
            }
            index += 1
            start += frame
        }
        return InputHearing(
            seconds: seconds,
            soundSeconds: Double(soundFrames) * frameSeconds,
            deadSeconds: Double(deadFrames) * frameSeconds,
            quietLeadSeconds: firstSoundFrame.map { Double($0) * frameSeconds } ?? seconds)
    }

    /// The microphone delivered no sound at all.
    public var heardNothing: Bool { soundSeconds == 0 }

    /// The microphone delivered hardly any sound: under half a second of it in all (under half the
    /// recording, for one shorter than a second). Only meaningful for a dictation that produced no
    /// text; it is a reason to name the microphone, not a verdict on a recording that worked.
    ///
    /// `deadSeconds` is logged and not part of the rule: a recording that is half zeros and half
    /// speech was heard, whatever went wrong with it afterwards.
    public var heardLittle: Bool {
        soundSeconds < min(Self.littleSoundSeconds, seconds / 2) || seconds == 0
    }

    /// For the log: "sound 0.22 s of 2.10 s · zeros 1.80 s · first sound at 1.80 s".
    public var logSummary: String {
        let first = heardNothing ? "no sound" : String(format: "first sound at %.2f s", quietLeadSeconds)
        return String(format: "sound %.2f s of %.2f s · zeros %.2f s · ", soundSeconds, seconds, deadSeconds) + first
    }
}
