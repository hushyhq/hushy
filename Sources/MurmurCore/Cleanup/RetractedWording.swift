import Foundation

/// A takeback phrase ("no that is the old one", "not that", "scratch that") belongs to the value the speaker gave up.
/// When a value was taken back and the answer still carries the phrase, the answer keeps the retracted wording
/// next to the value the speaker kept ("The alarm code is 4711; that is the old one."), which reads as if the
/// kept value were the old one. The good answer drops the phrase together with the old value.
enum RetractedWording {
    private static let phrases = [
        "that is the old one", "that was the old one", "thats the old one", "that's the old one",
        "not that", "scratch that", "strike that", "ignore that", "disregard that", "forget that",
    ]

    /// The takeback phrase the answer kept, if the speaker took a value back with it.
    static func kept(answer: String, raw: String) -> String? {
        let rawText = normalized(raw)
        let answerText = normalized(answer)
        let keys = phrases.map(normalized)
        guard let key = keys.first(where: { contains(rawText, $0) && contains(answerText, $0) }) else { return nil }
        // The phrase's own "one" is no value: the speaker must have given a number besides it.
        let rest = keys.reduce(rawText) { $0.replacingOccurrences(of: $1, with: " ") }
        return SpokenNumberRuns(rest).runs.isEmpty ? nil : key
    }

    private static func normalized(_ text: String) -> String {
        let plain = text.lowercased().replacingOccurrences(of: "\u{2019}", with: "'")
        let spaced = plain.replacingOccurrences(of: "[^a-z0-9']+", with: " ", options: .regularExpression)
        return " " + spaced.trimmingCharacters(in: .whitespaces) + " "
    }

    private static func contains(_ text: String, _ phrase: String) -> Bool {
        text.contains(phrase)
    }
}
