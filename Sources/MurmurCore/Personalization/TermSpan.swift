import Foundation

/// Where the text around a heard phrase already reads as the Dictionary term it would be replaced with.
///
/// A term can contain its own heard phrase ("jimmylord" heard, "jimmylord.com" meant; "miraholt" heard, "www.miraholt.com"
/// meant). A replacement that swaps only the heard phrase then writes the term's other pieces a second time when the text
/// already carries them: "jimmylord.com" became "jimmylord.com.com". This finds the whole stretch that reads as the term,
/// comparing letters and digits only (so "jimmy lord.com", "Jimmylord.Com" and "jimmylord.com" are the same reading), so the
/// stretch is replaced as one piece and the replacement leaves its own output alone.
enum TermSpan {
    /// The stretch of `text` around `heard` that reads as `term`, with the term's own leading and trailing punctuation when the
    /// text has it. Nil when the heard phrase is not part of such a reading (then only the heard phrase is replaced).
    static func reading(term: String, around heard: Range<String.Index>, in text: String) -> Range<String.Index>? {
        let termKey = keys(of: term)
        let heardCount = keys(of: text[heard]).count
        guard heardCount > 0, heardCount <= termKey.count else { return nil }
        let letters = text.indices.compactMap { index -> (index: String.Index, key: String)? in
            isLetterOrDigit(text[index]) ? (index, text[index].lowercased()) : nil
        }
        guard let first = letters.firstIndex(where: { $0.index >= heard.lowerBound }),
              first + heardCount <= letters.count else { return nil }
        let heardKey = letters[first..<(first + heardCount)].map(\.key)
        for offset in 0...(termKey.count - heardCount) where Array(termKey[offset..<(offset + heardCount)]) == heardKey {
            let start = first - offset
            let end = start + termKey.count
            guard start >= 0, end <= letters.count, letters[start..<end].map(\.key) == termKey else { continue }
            var lower = letters[start].index
            var upper = text.index(after: letters[end - 1].index)
            // The reading is a whole word, as the heard phrase's own match is.
            if lower > text.startIndex, isLetterOrDigit(text[text.index(before: lower)]) { continue }
            if upper < text.endIndex, isLetterOrDigit(text[upper]) { continue }
            let leading = String(term.prefix { !isLetterOrDigit($0) })
            let trailing = String(term.reversed().prefix { !isLetterOrDigit($0) }.reversed())
            if !leading.isEmpty, text[..<lower].lowercased().hasSuffix(leading.lowercased()),
               let moved = text.index(lower, offsetBy: -leading.count, limitedBy: text.startIndex) { lower = moved }
            if !trailing.isEmpty, text[upper...].lowercased().hasPrefix(trailing.lowercased()),
               let moved = text.index(upper, offsetBy: trailing.count, limitedBy: text.endIndex) { upper = moved }
            return lower..<upper
        }
        return nil
    }

    /// Spoken names for the punctuation inside a term, so "dot com" reads as the ".com" the term already ends with.
    private static let spokenSeparators: Set<String> = ["dot", "slash", "underscore", "dash", "hyphen"]

    /// How many of the words that follow a replaced stretch say the ending the term already has.
    ///
    /// The recogniser's boosting swaps the words it heard for the Dictionary term ("jimmy lord" for "jimmylord.com"), but the
    /// speaker also said the ending ("dot com"), and that stays behind the term: "jimmylord.com dot com". The term ends in
    /// pieces set off by punctuation (".com", "/pricing"); the following words are the ending when, ignoring the spoken
    /// separators, their letters and digits are exactly one of those endings. The longest ending that matches wins. Returns 0
    /// when they are not (then nothing is dropped).
    static func wordsSayingTheEnding(of term: String, in following: [String]) -> Int {
        let characters = Array(term)
        var best = 0
        for (offset, character) in characters.enumerated() where !isLetterOrDigit(character) && offset + 1 < characters.count {
            let ending = keys(of: String(characters[(offset + 1)...]))
            guard !ending.isEmpty else { continue }
            var joined: [String] = []
            for (count, word) in following.enumerated() {
                let wordKeys = keys(of: word)
                if wordKeys.isEmpty { continue }
                if spokenSeparators.contains(word.lowercased().filter(\.isLetter)) { continue }
                joined += wordKeys
                if joined == ending { best = max(best, count + 1); break }
                if joined.count >= ending.count { break }
            }
        }
        return best
    }

    private static func keys(of text: some StringProtocol) -> [String] {
        text.filter(isLetterOrDigit).map { $0.lowercased() }
    }

    private static func isLetterOrDigit(_ character: Character) -> Bool {
        character.isLetter || character.isNumber
    }
}
