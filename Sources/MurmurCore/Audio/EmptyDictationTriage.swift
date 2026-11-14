import Foundation

/// What the pill does with a dictation that produced no text, from the audio alone.
///
/// - **Dismiss**: a short press with no speech energy in it, which is an accidental tap. The pill
///   closes as if nothing happened: no row, no sound, no change to the microphone setting.
/// - **Brief**: a real attempt (speech energy, or a real hold) and a microphone that clearly works,
///   but no words came out. One short line that leaves by itself (`briefLifetime`), with no ✕.
/// - **Hint**: a real hold whose microphone sent no sound, or hardly any. The clear, persistent row
///   stays (it names the microphone and offers the fix), because a silent failure there is worse
///   than a row the person has to close.
///
/// Speech energy is the speech gate's own measure (`SpeechGate.Decision.activeFrameFraction`, 20 ms
/// frames above three times the noise floor or above the unambiguous-speech level) turned into
/// seconds. A key click or a bump of the desk lights a few frames; a word lights many more. Measured
/// with `murmur-eval empty-triage` (2026-10-28; table in `.claude/DECISIONS.md`): 222 speech clips and
/// cuts, one word to a long sentence, never under 0.26 s; synthetic presses: clicks 0.04 s, a desk
/// bump 0.06–0.10 s, a breath in a quiet room 0.18–0.20 s. The threshold sits between, at 0.23 s.
public enum EmptyDictationTriage {
    public enum Outcome: String, Equatable, Sendable { case dismiss, brief, hint }

    /// Shorter than this, a press with no speech energy is an accidental tap.
    public static let accidentalPressSeconds: Double = 1.0
    /// At least this much speech energy is speech, whatever the recogniser made of it.
    public static let speechEnergySeconds: Double = 0.23
    /// How long the brief line stays.
    public static let briefLifetime: Duration = .seconds(2)

    /// The speech gate's active frames, in seconds of audio.
    public static func speechSeconds(_ gate: SpeechGate.Decision, duration: Double) -> Double {
        gate.activeFrameFraction * duration
    }

    /// - Parameters:
    ///   - duration: the recording's length in seconds.
    ///   - speechSeconds: `speechSeconds(_:duration:)`.
    ///   - hearing: how much sound the microphone sent at all (`InputHearing`).
    public static func outcome(duration: Double, speechSeconds: Double, hearing: InputHearing) -> Outcome {
        if duration < accidentalPressSeconds, speechSeconds < speechEnergySeconds { return .dismiss }
        // A real attempt and the microphone sent next to nothing: the microphone is the thing to fix.
        if hearing.heardLittle { return .hint }
        // The microphone works (it sent sound), so a persistent "check your mic" would point at the
        // wrong thing: one line that leaves.
        return .brief
    }
}
