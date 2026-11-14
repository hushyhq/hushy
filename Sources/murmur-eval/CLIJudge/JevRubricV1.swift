import Foundation

/// Rubric v1 — the original five-question Jev judge (`state = {spoken, hushy_output, expected}`),
/// kept verbatim only so `murmur-eval judge calibrate` can compare it with rubric v2
/// (`JevRubric`). Not used by any other command since the 2026-09-27 calibration.
enum JevRubricV1 {
    static let questions: [String: TypeSafeClient.Question] = [
        "meaning_preserved": .init(
            type: .score,
            instructions: .string(
                "Compare hushy_output against spoken (the speaker's original words, including any "
                    + "self-corrections). Rate whether hushy_output keeps every fact and request the "
                    + "speaker still meant after applying their own corrections. Ignore wording, "
                    + "punctuation, and formatting differences — only judge whether the intended meaning "
                    + "survived."),
            criteria: .array([
                .string("Meaning is lost: hushy_output is missing or contradicts something the speaker still meant."),
                .string("Meaning is mostly lost: hushy_output keeps only a small part of what the speaker still meant."),
                .string("Meaning is partially preserved: hushy_output keeps some but not all of what the speaker still meant."),
                .string("Meaning is mostly preserved: hushy_output keeps nearly everything, with one minor gap."),
                .string("Meaning is fully preserved: hushy_output keeps every fact and request the speaker still meant, with nothing missing or contradicted."),
            ])),
        "dropped_content": .init(
            type: .noul,
            instructions: .string(
                "hushy_output is missing at least one fact, item, name, or request that the speaker "
                    + "still meant to keep after applying their own self-corrections in spoken. Do not "
                    + "count content the speaker explicitly retracted (e.g. said 'actually, skip X' or "
                    + "'no wait, forget X') as dropped."),
            criteria: .strings([
                "true": "Something the speaker still meant to keep is missing from hushy_output.",
                "false": "Everything the speaker still meant to keep is present in hushy_output.",
            ])),
        "added_or_changed_facts": .init(
            type: .noul,
            instructions: .string(
                "hushy_output contains a name, number, date, negation, or other factual detail that is "
                    + "different from or absent in spoken (after applying the speaker's own corrections), "
                    + "or introduces new content the speaker never said."),
            criteria: .strings([
                "true": "hushy_output has a name, number, negation, or fact that does not match what the speaker said, or adds new content.",
                "false": "Every name, number, negation, and fact in hushy_output matches what the speaker said, with nothing invented.",
            ])),
        "correction_resolved": .init(
            type: .noul,
            instructions: .string(
                "spoken contains the speaker correcting themselves (e.g. 'actually', 'no wait', 'I mean', "
                    + "'scratch that', restating a name or number). If so, hushy_output keeps only the "
                    + "speaker's final, corrected intent and does not keep the retracted earlier version "
                    + "alongside it. If spoken contains no self-correction at all, answer true (vacuously "
                    + "satisfied)."),
            criteria: .strings([
                "true": "Either there is no self-correction in spoken, or hushy_output correctly keeps only the final corrected intent.",
                "false": "spoken contains a self-correction, but hushy_output still includes the retracted earlier version, or resolved it incorrectly.",
            ])),
        "format": .init(
            type: .choice,
            instructions: .string(
                "What output format does hushy_output take? Judge only its shape, not its content."),
            criteria: .strings([
                "sentence": "A single flowing sentence or short paragraph of prose, no list markers.",
                "list": "A bulleted or numbered list, or clearly enumerated line-separated items.",
                "email": "Has email structure: greeting, body, and/or sign-off, or explicit subject/recipient framing.",
                "message": "A short, informal chat/text-message-style utterance.",
                "code_or_technical": "Source code, a command line, a file path, or another technical/structured notation.",
            ])),
        "format_matches_expected": .init(
            type: .noul,
            instructions: .string(
                "hushy_output's format (sentence, list, email, message, or code/technical) matches the "
                    + "format that expected uses. Judge structure only, not wording."),
            criteria: .strings([
                "true": "hushy_output uses the same kind of structure (sentence/list/email/message/code) as expected.",
                "false": "hushy_output uses a different structure than expected.",
            ])),
    ]

    static func state(spoken: String, output: String, expected: String) -> TypeSafeClient.AnyJSON {
        .object(["spoken": .string(spoken), "hushy_output": .string(output), "expected": .string(expected)])
    }

    /// v1's verdict inputs: P(meaning < 3 on the 0…4 scale), dropped, added/changed.
    struct Judgment: Codable, Equatable, Sendable {
        let meaningScore: Double
        let meaningBelowThree: Double
        let droppedContent: Double
        let addedOrChangedFacts: Double

        /// The original `jevPassed` rule.
        var passed: Bool { meaningScore >= 3.0 && droppedContent < 0.5 && addedOrChangedFacts < 0.5 }
        var pBad: Double { max(meaningBelowThree, droppedContent, addedOrChangedFacts) }
    }

    static func decode(_ response: TypeSafeClient.Response) throws -> Judgment {
        guard let meaning = response.answers["meaning_preserved"], let score = meaning.score,
              let dropped = response.answers["dropped_content"]?.noul,
              let added = response.answers["added_or_changed_facts"]?.noul
        else { throw TypeSafeClient.ClientError.decoding("Jev v1 response is missing answers") }
        let probs = meaning.probabilities ?? [:]
        let below = (0..<3).reduce(0.0) { $0 + (probs[String($1)] ?? 0) }
        return Judgment(meaningScore: score, meaningBelowThree: below, droppedContent: dropped, addedOrChangedFacts: added)
    }
}
