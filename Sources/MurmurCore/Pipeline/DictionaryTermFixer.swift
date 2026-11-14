import Foundation

/// A word in the person's Dictionary is a word they say. Vocabulary boosting asks the recognizer for it, but a
/// recognizer that prefers a different word it knows still writes that one ("codecs" for "Codex"), and the Dictionary
/// replacement only knows the exact spellings the person typed under "often heard as". This looks at the words the
/// recognizer wrote and puts the Dictionary word in place of one that sounds the same:
/// - a word that is not an English word at all is the recognizer's guess at a sound, so it becomes the Dictionary word
///   it sounds like, wherever it stands;
/// - an ordinary English word ("relics" for "Relix") becomes the Dictionary word only where a name belongs, by the
///   same cues as an installed app's name (`InstalledNameFixer`), so "the relics were old" stays as spoken.
/// Sound is `ContextSpellingFixer`'s phonetic key plus a small edit distance, as for every other spelling fix.
public enum DictionaryTermFixer {
    /// Dictionary words, then the names of installed apps, then the built-in AI product names, applied to a transcript before cleanup.
    public static func fixNames(_ text: String, settings: PipelineSettings) -> String {
        let dictionary = VocabularySwaps.restore(from: text, to: fix(text, personalizer: settings.personalizer),
            source: .dictionaryName, keeping: settings.keepHeard).text
        let installed = VocabularySwaps.restore(from: dictionary, to: InstalledNameFixer.fix(dictionary, settings: settings),
            source: .installedName, keeping: settings.keepHeard).text
        return VocabularySwaps.restore(from: installed, to: AIProductNameFixer.fix(installed, settings: settings),
            source: .productName, keeping: settings.keepHeard).text
    }

    /// Terms shorter than this are too easy to hit by chance.
    private static let minimumLetters = 4

    static func fix(_ text: String, personalizer: Personalizer) -> String {
        let terms = distinctTerms(in: personalizer.dictionary)
        guard !terms.isEmpty, !text.isEmpty else { return text }
        var output = text
        for match in Regex.matchesCaseSensitive(text, "[A-Za-z]+").reversed() {
            guard let range = Range(match.range, in: output) else { continue }
            let word = String(output[range])
            guard let term = soundAlike(of: word, among: terms, personalizer: personalizer) else { continue }
            guard !personalizer.keep.blocks(heardKey: VocabularySwap.key(word), writtenKey: VocabularySwap.key(term)) else { continue }
            output.replaceSubrange(range, with: term)
        }
        return output
    }

    /// One-word terms of letters only, once each (the fixer compares words, and a term with a dot or a hyphen is a
    /// spelling the person wants kept as typed, not a sound to look for).
    private static func distinctTerms(in dictionary: [DictionaryEntry]) -> [String] {
        var seen = Set<String>()
        return dictionary.compactMap { entry -> String? in
            let term = entry.term.trimmingCharacters(in: .whitespacesAndNewlines)
            guard term.count >= minimumLetters, term.allSatisfy(\.isLetter), seen.insert(term.lowercased()).inserted else { return nil }
            return term
        }
    }

    /// The one term `word` sounds like, or nil when it sounds like none, like more than one, or is an English word
    /// (those are `InstalledNameFixer`'s, with a name position) or a spelling the person listed for a word.
    private static func soundAlike(of word: String, among terms: [String], personalizer: Personalizer) -> String? {
        let key = word.lowercased()
        guard key.count >= minimumLetters, !LearningLexicon.isCommonWord(key), !personalizer.protectsHeardWord(word) else { return nil }
        let matches = terms.filter { sounds(key, likeTerm: $0.lowercased()) }
        return matches.count == 1 ? matches[0] : nil
    }

    private static func sounds(_ heard: String, likeTerm term: String) -> Bool {
        guard heard != term, heard.first == term.first, abs(heard.count - term.count) <= 2,
              ContextSpellingFixer.phoneticKey(heard) == ContextSpellingFixer.phoneticKey(term) else { return false }
        return ContextSpellingFixer.levenshtein(heard, term) <= ContextSpellingFixer.maxEditDistance(for: term.count)
    }
}
