import Foundation

/// A learned term whose heard spellings Hushy watches for: when one is written and the person leaves it,
/// that is one more "left alone" for the term (`EvidenceCell.kept`).
public struct WatchedTerm: Sendable, Equatable {
    /// `LearnedItem.key`.
    public let itemKey: String
    /// The heard spellings as comparison keys (`VocabularySwap.key`): lowercased words, one entry per spelling.
    public let heardKeys: [String]

    public init(itemKey: String, heardKeys: [String]) {
        self.itemKey = itemKey
        self.heardKeys = heardKeys
    }
}

/// Which watched terms a dictation left alone. Pure: the field is read by the caller and never stored.
public enum ExposureDerivation {
    /// The item keys of terms Hushy wrote as heard in this dictation and the person left as written. All must hold:
    /// the spelling is in what the recogniser heard (`raw`) and in what Hushy inserted; the field still has it where the
    /// dictation is (the dictation unchanged, or located and that stretch untouched); and the person did not change
    /// the term in this dictation (`editedKeys`, the terms the capture taught). No field text is returned.
    ///
    /// `fieldValues` are the reads of the field, newest first; the newest one that still holds the dictation decides.
    /// Nil when none does (the field was cleared or rewritten): then nothing is known about this dictation.
    public static func leftAlone(
        inserted: String, raw: String, fieldValues: [String], watched: [WatchedTerm], editedKeys: Set<String> = []
    ) -> Set<String>? {
        guard !watched.isEmpty else { return [] }
        let rawKeys = keys(raw), insertedKeys = keys(inserted)
        // Each remaining term with the heard spellings that Hushy wrote as heard in this dictation.
        let written = watched.filter { !editedKeys.contains($0.itemKey) }.compactMap { term -> (term: WatchedTerm, phrases: [[String]])? in
            let phrases = term.heardKeys.map(phrase).filter { !$0.isEmpty && occurrences(of: $0, in: rawKeys) > 0 && occurrences(of: $0, in: insertedKeys) > 0 }
            return phrases.isEmpty ? nil : (term, phrases)
        }
        guard !written.isEmpty else { return [] }
        guard let fieldKeys = fieldValues.lazy.compactMap({ placed(inserted, insertedKeys, in: $0) }).first else { return nil }
        // Left alone means every time it was written it is still there.
        return Set(written.filter { entry in
            entry.phrases.contains { occurrences(of: $0, in: fieldKeys) >= occurrences(of: $0, in: insertedKeys) }
        }.map(\.term.itemKey))
    }

    /// The comparison keys of the stretch of `fieldValue` that holds the dictation, or nil when it does not.
    private static func placed(_ inserted: String, _ insertedKeys: [String], in fieldValue: String) -> [String]? {
        if fieldValue.contains(inserted) { return insertedKeys }
        return CorrectionAlignment.locate(inserted: inserted, in: fieldValue)?.edited.map(CorrectionAlignment.key)
    }

    private static func keys(_ text: String) -> [String] {
        CorrectionAlignment.tokens(text).map(CorrectionAlignment.key).filter { !$0.isEmpty }
    }

    private static func phrase(_ heardKey: String) -> [String] {
        heardKey.split(separator: " ").map(String.init)
    }

    /// How many times `words` occurs as a run inside `tokens`.
    static func occurrences(of words: [String], in tokens: [String]) -> Int {
        guard !words.isEmpty, tokens.count >= words.count else { return 0 }
        return (0...(tokens.count - words.count)).filter { Array(tokens[$0..<($0 + words.count)]) == words }.count
    }
}
