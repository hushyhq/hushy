import Foundation

/// Whether a finished recording is only the tail of a headset's link coming up, and so is not
/// worth sending to the recogniser.
///
/// A Bluetooth headset delivers exact zeros from the moment its microphone is opened until its
/// call link is live, about a second. A key released before then, or a moment after, holds no
/// sound or a fragment of a word: recognising it gives wrong words, and the cleanup model then
/// writes a sentence around them. The honest answer is that nothing was heard yet.
///
/// The rule reads how the recording went, never what was said.
public enum HeadsetLinkHold {
    /// Sound for less than this after the link came up is a fragment, not a dictation.
    public static let fragment: Duration = .milliseconds(300)
    /// A link that delivered silence for at least this long was really coming up. Below it the
    /// headset was already live (a call, or another app holding its microphone) and a short
    /// recording is just a short recording.
    public static let linkWasComingUp: Duration = .milliseconds(200)
    /// A recording of nothing but zeros reads as "still connecting" only up to this length: half
    /// as long again as the 1.1 to 1.3 s a link took on the headsets measured. A link that has
    /// delivered nothing for longer is not coming up: that is a microphone that sends no audio,
    /// and the row for that says so and offers another microphone.
    public static let longestConnect: Duration = .milliseconds(1_800)

    /// - Parameters:
    ///   - transport: how the microphone the recording used is connected.
    ///   - recorded: the length of everything the capture delivered, the leading zeros included.
    ///   - silenceBeforeSound: how much of that came before the first sound; nil when every
    ///     sample was zero.
    public static func linkWasStillConnecting(transport: InputTransport?, recorded: Duration,
                                              silenceBeforeSound: Duration?) -> Bool {
        guard transport == .bluetooth else { return false }
        guard let silenceBeforeSound else { return recorded <= longestConnect }
        guard silenceBeforeSound >= linkWasComingUp else { return false }
        return recorded - silenceBeforeSound < fragment
    }
}
