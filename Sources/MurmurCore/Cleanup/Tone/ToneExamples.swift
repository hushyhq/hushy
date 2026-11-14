import Foundation

/// The one spoken sentence that teaches the choice, and what each choice types for it.
///
/// `spoken` is what the person says (lowercase, no punctuation, as speech recognition returns it).
/// `cleaned` is what the Hushy cleanup model made of it on 2026-10-06 (`murmur-eval tones --path wired`,
/// `hushy-cleanup-2b-v5.4-4bit`): the filler gone, the "four, no, five" correction resolved, names
/// and sentences written properly. The model part cannot run in a unit test, so `cleaned` is stored as
/// recorded; a test keeps it honest by checking each tone's line against what `ToneRegister` does to
/// it today. Each tone's line is the real output of the rules on `cleaned`, laid out as everyday
/// writing (`StyleContext.other`), so the screen never promises more than the code does.
///
/// What the three lines show, and so all they may claim: Refined keeps your words ("gonna", "do not");
/// Casual contracts them ("don't"); Professional spells out the shortcuts ("going to") and the
/// contractions. Casual and Refined differ only by those contractions on speech that did not already
/// contract.
public enum ToneExamples {
    public static let spoken =
        "so uh the deploy is gonna go out at four no five and we do not need the rollback plan can you ping omar if it fails"

    public static let cleaned =
        "The deploy is gonna go out at five, and we do not need the rollback plan. Can you ping Omar if it fails?"

    /// The first sentence of `cleaned`, for the small cards where the whole example does not fit. It
    /// carries every difference between the tones (gonna, going to, do not, don't).
    public static let cleanedFirstSentence = "The deploy is gonna go out at five, and we do not need the rollback plan."

    /// "As spoken" keeps every word, including the filler and the one the person took back.
    public static let asSpoken = spoken

    /// The one-sentence version for the small cards.
    public static func shortText(for choice: ToneChoice) -> String {
        guard let tone = choice.tone else { return asSpoken }
        return ToneRegister.apply(tone, to: cleanedFirstSentence, in: .other)
    }

    public static func text(for choice: ToneChoice) -> String {
        guard let tone = choice.tone else { return asSpoken }
        return ToneRegister.apply(tone, to: cleaned, in: .other)
    }
}

/// The one example each lane of the tone page shows: something a person says, and what Hushy typed for it.
///
/// Every line is a recorded output of the app's real cleanup path (`murmur-eval intent-app`, the app's own tone and
/// layout settings per app), never an invented sample: `docs/yc/tones-register-2026-10-28.md` and
/// `docs/yc/demo-rehearsal-2026-10-28.md`, `hushy-cleanup-4b-r10d-6bit`, 2026-10-28.
///
/// Which line is shown depends on the writing model in use (`LocalModelEntry.understandsRegisterLines`):
/// - With register lines, Professional, Casual and Prompt are real rewrites ("after" column).
/// - Without them, only the word-level tone pass runs (`ToneRegister`): the "register off" column, the same
///   spoken line with contractions spelled out or kept. Prompt is not offered then, so it has no example.
/// Refined sends no register line, so its output is the same either way (public 300: byte-identical).
/// The register-off lines were recorded on the 4B with the line switched off; a smaller model runs the same word
/// pass, and its cleanup of the same words may differ in small ways.
public struct ToneLaneExample: Equatable, Sendable {
    public let spoken: String
    public let written: String
    /// The app the line was recorded in, as the page names it ("in Mail").
    public let app: String

    public static func forLane(_ lane: ToneLane, registerLines: Bool) -> ToneLaneExample? {
        switch (lane, registerLines) {
        case (.refined, _): refined
        case (.professional, true): professionalRewrite
        case (.professional, false): professionalWords
        case (.casual, true): casualRewrite
        case (.casual, false): casualWords
        case (.prompt, true): prompt
        case (.prompt, false): nil
        case (.asSpoken, _): asSpoken
        }
    }

    /// Demo rehearsal slack-1 (Slack, Default): the self-correction resolved, the doubled word gone.
    public static let refined = ToneLaneExample(
        spoken: "hey um can you send me the the q3 deck by friday no wait thursday thanks",
        written: "Hey, can you send me the Q3 deck by Thursday? Thanks.", app: "Slack")

    static let professionalSpoken =
        "hi dana thanks for thinking of me for the panel but i'm going to have to say no this time i don't have the bandwidth for this right now"
    /// Register lines pro-1, after.
    public static let professionalRewrite = ToneLaneExample(
        spoken: professionalSpoken,
        written: "Hi Dana,\n\nThanks for thinking of me for the panel. Unfortunately, I don't have the bandwidth for this at this time.",
        app: "Mail")
    /// Register lines pro-1, register off.
    public static let professionalWords = ToneLaneExample(
        spoken: professionalSpoken,
        written: "Hi Dana,\n\nThanks for thinking of me for the panel, but I am going to have to say no this time. I do not have the bandwidth for this right now.",
        app: "Mail")

    static let casualSpoken = "hey i'm running like ten minutes late um grab us a table and i'll be there"
    /// Register lines msg-1, after.
    public static let casualRewrite = ToneLaneExample(
        spoken: casualSpoken, written: "I'm running about 10 minutes late, so grab us a table and I'll be there", app: "Messages")
    /// Register lines msg-1, register off.
    public static let casualWords = ToneLaneExample(
        spoken: casualSpoken, written: "Hey I'm running like 10 minutes late. Grab us a table and I'll be there", app: "Messages")

    /// Register lines x-claudecode, after.
    public static let prompt = ToneLaneExample(
        spoken: "hey claude code can you run the tests then if anything fails fix it and run them again until they all pass",
        written: "Run the tests, then fix any failures and run them again until they all pass.", app: "Claude")

    /// As spoken keeps every word, the filler and the day taken back included (what verbatim cleanup leaves).
    public static let asSpoken = ToneLaneExample(spoken: refined.spoken, written: refined.spoken, app: "Slack")
}
