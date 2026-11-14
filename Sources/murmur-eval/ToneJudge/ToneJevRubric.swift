import CryptoKit
import Foundation
import MurmurCore

/// Tone rubric (`tone-v1`) for TypeSafe's Jev. Separate from the cleanup rubric v2 (`JevRubric`),
/// whose questions and calibrated thresholds are untouched. Eval-only: it judges invented dev-set
/// text from `Evals/tones-dev*.json`, never anything from the app.
///
/// Two requests per output, because the questions need different state:
/// - the **read** request (`tone_read`, a Choice) carries only `spoken` and `output`. The requested
///   tone is left out on purpose, so the answer cannot just echo it.
/// - the **fit** request (`tone_rule_broken`, `tone_overreach`, both Noul) carries the requested
///   tone and that tone's permitted changes, plus `spoken` and `output`.
/// Fault questions are phrased so "yes" means the fault is present (TypeSafe guidance, JUDGES.md).
/// The permitted changes come from `docs/research/tone-design-advice-2026-10-05.md`.
enum ToneJevRubric {
    static let version = "tone-v1"
    static let model = JevRubric.model

    typealias JSON = TypeSafeClient.AnyJSON

    static let readOptions = ["refined", "casual", "professional", "unclear"]

    /// What every tone forbids.
    static let forbiddenEverywhere =
        "Every tone forbids: new content words, swapping a word for a synonym or a stock phrase, guessed names or "
        + "product versions, added courtesy sentences, emoji, and invented greetings or sign-offs."

    /// The permitted changes for a tone, in plain words (design advice table).
    static func rules(for tone: DictationTone) -> String {
        let refined = "Removes isolated fillers and abandoned restarts, resolves an explicit self-correction to the final "
            + "version, fixes agreement when the speaker's own words suffice, fixes capitals, adds punctuation and the "
            + "layout the speaker signalled. Keeps the speaker's register: contractions, names, numbers and technical "
            + "terms stay as spoken, and a spoken reduction such as gonna stays as spoken."
        switch tone {
        case .refined:
            return "Refined. " + refined + " Does not contract or expand anything. " + forbiddenEverywhere
        case .casual:
            return "Casual. Everything Refined does, plus: contracts a pronoun with am, are, is or will, and an "
                + "auxiliary with not (I am becomes I'm, do not becomes don't); lighter closing punctuation in chat; "
                + "an informal greeting layout. A spoken reduction such as gonna stays as spoken. It never contracts a "
                + "noun with is, and never expands anything. " + forbiddenEverywhere
        case .professional:
            return "Professional. Everything Refined does, plus: spells out a short list of spoken reductions (gonna "
                + "becomes going to, wanna becomes want to, kinda becomes kind of, gotta becomes got to, lemme becomes "
                + "let me), expands unambiguous contractions (I'm becomes I am, don't becomes do not), and lays out a "
                + "spoken email greeting and sign-off. Keeps the speaker's hedges, emphasis and chosen phrases, and does "
                + "not make the wording more formal in any other way. " + forbiddenEverywhere
        }
    }

    static func readState(spoken: String, output: String) -> JSON {
        .object(["spoken": .string(spoken), "output": .string(output)])
    }

    static func fitState(tone: DictationTone, spoken: String, output: String) -> JSON {
        .object([
            "requested_tone": .string(tone.title),
            "tone_rules": .string(rules(for: tone)),
            "spoken": .string(spoken),
            "output": .string(output),
        ])
    }

    static let readQuestions: [String: TypeSafeClient.Question] = [
        "tone_read": .init(
            type: .choice,
            instructions: .string(
                "Compare `output` with `spoken` (the words as the speaker said them). Which tone was applied to "
                    + "produce `output`? Ignore what was removed as filler or taken back in a correction; look at how the "
                    + "speaker's own words were turned into typed text."),
            criteria: .strings([
                "refined": "`output` keeps the speaker's register: nothing was contracted and nothing was spelled out beyond what `spoken` already had, and any gonna or contraction in `spoken` is still there.",
                "casual": "`output` turns spoken full forms into everyday contractions (I am became I'm, do not became don't), and closes lightly.",
                "professional": "`output` spells out spoken reductions (gonna became going to, wanna became want to) or expands contractions (I'm became I am, don't became do not).",
                "unclear": "`spoken` has nothing a tone would change (no full form to contract, no contraction or reduction to spell out), so `output` reads the same whichever tone was applied.",
            ])),
    ]

    static let fitQuestions: [String: TypeSafeClient.Question] = [
        "tone_rule_broken": .init(
            type: .noul,
            instructions: .string(
                "Does `output` break the rules of `requested_tone` in `tone_rules`? Count both kinds: a change the "
                    + "tone does not permit, and a change the tone is meant to make that is missing although `spoken` "
                    + "gave the chance (for example Professional leaving 'I am gonna' where gonna can be spelled out, or "
                    + "Casual leaving 'do not' uncontracted). If `spoken` has nothing the tone would change, leaving "
                    + "the words as spoken is correct. Fillers and the retracted half of a self-correction are removed "
                    + "by every tone and never count."),
            criteria: .strings([
                "true": "`output` makes a change `tone_rules` forbids, or leaves in place something `tone_rules` says to change.",
                "false": "Every change in `output` is allowed by `tone_rules`, and nothing that `tone_rules` says to change was left.",
            ])),
        "tone_overreach": .init(
            type: .noul,
            instructions: .string(
                "Does `output` change the speaker's wording beyond what `tone_rules` allows? Count a new content "
                    + "word, a synonym or stock-phrase swap, a reworded or reordered clause, a courtesy sentence, an "
                    + "invented greeting or sign-off, an emoji, and a guessed name or version. Removing fillers, "
                    + "resolving a self-correction, punctuation, capitals, and the word changes `tone_rules` lists do not count."),
            criteria: .strings([
                "true": "`output` rewrites or adds wording that `tone_rules` does not allow.",
                "false": "Every wording change in `output` is one `tone_rules` allows.",
            ])),
    ]

    static func cacheKey(state: JSON, questions: [String: TypeSafeClient.Question]) -> String {
        let request = TypeSafeClient.Request(state: state, model: model, questions: questions)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let body = (try? encoder.encode(request)) ?? Data()
        let hex = SHA256.hash(data: body).map { String(format: "%02x", $0) }.joined()
        return "jev__\(model)__\(version)__\(hex)"
    }
}

/// Jev's answer to `tone_read`: which tone the output reads as, with the full distribution.
struct ToneRead: Codable, Equatable, Sendable {
    let choice: String
    let probabilities: [String: Double]

    func probability(of option: String) -> Double { probabilities[option] ?? 0 }

    static func decode(_ response: TypeSafeClient.Response) throws -> ToneRead {
        guard let answer = response.answers["tone_read"], let choice = answer.choice else {
            throw TypeSafeClient.ClientError.decoding("tone-v1 read response is missing tone_read")
        }
        return ToneRead(choice: choice, probabilities: answer.probabilities ?? [:])
    }
}

/// Jev's answers to the two fault questions for one (tone, output) pair.
struct ToneFit: Codable, Equatable, Sendable {
    let ruleBroken: Double
    let overreach: Double

    /// "Any violation": the higher of the two fault probabilities.
    var pBad: Double { max(ruleBroken, overreach) }

    static let flagAt = 0.5

    var flagged: Bool { pBad >= Self.flagAt }

    static func decode(_ response: TypeSafeClient.Response) throws -> ToneFit {
        guard let broken = response.answers["tone_rule_broken"]?.noul,
              let overreach = response.answers["tone_overreach"]?.noul
        else { throw TypeSafeClient.ClientError.decoding("tone-v1 fit response is missing answers") }
        return ToneFit(ruleBroken: broken, overreach: overreach)
    }
}
