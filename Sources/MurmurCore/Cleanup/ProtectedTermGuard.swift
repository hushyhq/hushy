import Foundation

/// Rejects a model rewrite that drops or respells a protected term — the user's Dictionary
/// entries and terms learned from their edits (`LearnedPersonalization`). The rule-cleaned
/// draft already has the term right (dictionary spelling is applied after cleanup, and ASR
/// boosting put it there); a fluent rewrite must not "correct" "Priya" to "Pria" or drop
/// "Kubernetes". Case-insensitive, whole-word; a term the draft doesn't contain is ignored.
///
/// The draft can also hold a *heard variant* the Dictionary replaces after cleanup ("diarisation"
/// → "diarization", `Personalizer`). A rewrite that respells the variant would keep that
/// replacement from ever matching, so the variant is protected too: the answer must keep either
/// the variant or its term as often as the draft held them (`Alias`).
public enum ProtectedTermGuard {
    /// A spelling the recognizer produces (`heard`) that the Dictionary rewrites to `term`.
    public struct Alias: Sendable, Equatable {
        public let heard: String
        public let term: String
        public init(heard: String, term: String) {
            self.heard = heard
            self.term = term
        }
    }

    public static func violation(answer: String, draft: String, terms: [String], aliases: [Alias] = []) -> String? {
        let draftKey = normalized(draft)
        let answerKey = normalized(answer)
        for alias in aliases {
            let heard = words(alias.heard), term = words(alias.term)
            guard !heard.isEmpty, !term.isEmpty, contains(draftKey, heard) else { continue }
            let before = count(draftKey, heard) + count(draftKey, term)
            if count(answerKey, heard) + count(answerKey, term) < before { return "changed protected term: \(alias.heard)" }
        }
        for term in terms {
            let key = words(term)
            guard !key.isEmpty, contains(draftKey, key) else { continue }
            if count(draftKey, key) > count(answerKey, key) { return "changed protected term: \(term)" }
        }
        return nil
    }

    /// The guard for the whole-transcript model, which also resolves what the speaker took back: a term (or heard variant)
    /// the speaker retracted in `raw` and replaced in the answer is not owed to the answer (see `RetractedTerms`).
    static func violation(
        answer: String, draft: String, raw: String, terms: [String], aliases: [Alias] = []
    ) -> String? {
        let gone = RetractedTerms.retracted(terms + aliases.flatMap { [$0.heard, $0.term] }, raw: raw, answer: answer)
        return violation(
            answer: answer, draft: draft, terms: terms.filter { !gone.contains($0) },
            aliases: aliases.filter { !gone.contains($0.heard) && !gone.contains($0.term) })
    }

    /// Normalized words joined by single spaces.
    private static func words(_ text: String) -> String {
        CorrectionAlignment.tokens(text).map(CorrectionAlignment.key).filter { !$0.isEmpty }.joined(separator: " ")
    }

    /// `words`, padded so whole-word matches are plain substring checks.
    private static func normalized(_ text: String) -> String { " " + words(text) + " " }

    private static func contains(_ text: String, _ key: String) -> Bool { text.contains(" \(key) ") }

    private static func count(_ text: String, _ key: String) -> Int {
        text.components(separatedBy: " \(key) ").count - 1
    }
}
