import Foundation

/// A capitalised word in an answer that repairs a spoken span in place: "get hub" -> "GitHub", "doc her" -> "Docker",
/// "Google meat" -> "Google Meet", "Wensday" -> "Wednesday". The recogniser wrote the sound of the word; the model wrote
/// the word. `CorrectionBound` calls this before it counts a capitalised word as one the speaker never said.
///
/// A word is a repair only when all of these hold:
/// - the spoken words (one, two or three side by side), written together, sound like it: `ContextSpellingFixer`'s
///   phonetic key, or its consonants as a run inside the answer word's ("Wensday" is "Wednesday" with a syllable
///   missing), and a small edit distance, as for a Dictionary word (`DictionaryTermFixer`);
/// - it starts with the same letter and has four letters or more, so a short name is never found in a short word;
/// - those spoken words are not themselves a name: a word the draft capitalised in mid-sentence ("Sarah", "Marcus")
///   was said as a name, and a different name in its place is a swap, not a repair. A part of a full name (two or more
///   capitalised words in a row, "Chet Holgren") is the exception: the recogniser capitalises the sound of a name it
///   does not know, so "Holgren" -> "Holmgren" is the model spelling the person it knows, in place, beside the parts it
///   kept. A lone first name keeps the swap rule (default-parity, 2026-11-11);
/// - it stands where the span stood: the word before or the word after is the same in the draft and the answer;
/// - two or three spoken words are not already the same letters ("mary ann" -> "Maryann" is a name the speaker never said),
///   but one word re-spelled is a repair ("wifi" -> "Wi-Fi").
/// A name with no spoken source, and one that replaces a different spoken name, are not repairs.
enum SpokenNameRepair {
    private static let minimumLetters = 4
    private static let longestSpan = 3

    private struct Token {
        let raw: String
        let folded: String
        /// The spoken piece ended in punctuation ("Sarah," in "Sarah, Marcus"): the next word does not join it in a name.
        var endsPhrase = false
    }

    /// True when `word` (a capitalised word of `answer`, `name` its lowercased letters) repairs a span of `draft` in place.
    /// A product written with a dot ("Node.js") reaches here as its first piece, so the whole token is what is compared.
    static func repairs(_ word: String, name: String, answer: String, draft: String) -> Bool {
        repairs(word, name: name, answer: answer, draft: draft, fromBlock: false)
    }

    /// A block spelling can resolve a wider ASR misspelling, but still needs a sound match in place.
    static func repairsFromBlock(_ word: String, name: String, answer: String, draft: String) -> Bool {
        repairs(word, name: name, answer: answer, draft: draft, fromBlock: true)
    }

    private static func repairs(_ word: String, name: String, answer: String, draft: String, fromBlock: Bool) -> Bool {
        let answerTokens = tokens(answer), spoken = tokens(draft)
        guard !spoken.isEmpty else { return false }
        for (index, token) in answerTokens.enumerated() where token.raw == word || token.raw.hasPrefix(word + ".") {
            let target = token.raw == word ? name : letters(token.folded)
            guard target.count >= minimumLetters else { continue }
            // A weekday or a month is always capitalised, so a capitalised spoken word that sounds like one is a
            // mis-hearing of it; any other capitalised spoken word was said as a name.
            let sameCalendarWord = CorrectionBound.calendarNames.contains(target)
            if spansReplaced(by: target, at: index, in: answerTokens, spoken: spoken,
                             spokenNamesCount: !sameCalendarWord, fromBlock: fromBlock) { return true }
        }
        return false
    }

    private static func letters(_ text: String) -> String { String(text.filter(\.isLetter)) }

    private static func spansReplaced(
        by name: String, at index: Int, in answer: [Token], spoken: [Token], spokenNamesCount: Bool,
        fromBlock: Bool
    ) -> Bool {
        let before = index > 0 ? answer[index - 1].folded : nil
        let after = index + 1 < answer.count ? answer[index + 1].folded : nil
        for start in spoken.indices {
            for length in 1...(fromBlock ? 6 : longestSpan) where start + length <= spoken.count {
                if spokenNamesCount, (start..<start + length).contains(where: {
                    isSpokenName(spoken[$0], atStart: $0 == 0) && !isInFullName($0, spoken)
                }) { continue }
                let joined = letters(spoken[start..<start + length].map(\.folded).joined())
                // One spoken word with the same letters is the word re-spelled ("wifi" -> "Wi-Fi"); two or three words
                // made one name are a name the speaker never said ("mary ann" -> "Maryann" is not a repair).
                guard fromBlock || length == 1 || joined != name,
                      fromBlock ? (joined == name || soundsWithBlock(joined, likeName: name))
                          : (joined.first == name.first && (joined == name || sounds(joined, likeName: name)))
                else { continue }
                let spokenBefore = start > 0 ? spoken[start - 1].folded : nil
                let spokenAfter = start + length < spoken.count ? spoken[start + length].folded : nil
                if fromBlock {
                    if (before != nil && before == spokenBefore) || (after != nil && after == spokenAfter) { return true }
                } else if before == spokenBefore || after == spokenAfter { return true }
            }
        }
        return false
    }

    /// "Sarah" in mid-sentence is a name the speaker said. An acronym ("JS") or a lowercase word is not one. The first word
    /// of the draft is capitalised whatever it is.
    private static func isSpokenName(_ token: Token, atStart: Bool) -> Bool {
        guard !atStart, let first = token.raw.first, first.isUppercase else { return false }
        return token.raw.dropFirst().contains(where: \.isLowercase)
    }

    /// The spoken word at `index` sits beside another capitalised word with no punctuation between them: a full name.
    /// A neighbour that opens a sentence is capitalised whatever it is, so there it counts only when it is not an
    /// ordinary word ("Yesterday Marcus said" holds one name, "Demontis Sabonus is out" two).
    private static func isInFullName(_ index: Int, _ spoken: [Token]) -> Bool {
        func namePart(_ i: Int) -> Bool {
            guard spoken.indices.contains(i), let first = spoken[i].raw.first, first.isUppercase,
                  spoken[i].raw.dropFirst().contains(where: \.isLowercase) else { return false }
            let opensSentence = i == 0 || spoken[i - 1].endsPhrase
            return !opensSentence || !BoostGuard.systemWords.contains(spoken[i].folded)
        }
        let before = index > 0 && namePart(index - 1) && !spoken[index - 1].endsPhrase
        let after = namePart(index + 1) && !spoken[index].endsPhrase
        return namePart(index) && (before || after)
    }

    private static func sounds(_ heard: String, likeName name: String) -> Bool {
        guard ContextSpellingFixer.levenshtein(heard, name) <= ContextSpellingFixer.maxEditDistance(for: name.count) else { return false }
        let heardKey = ContextSpellingFixer.phoneticKey(heard), nameKey = ContextSpellingFixer.phoneticKey(name)
        return heardKey == nameKey || isSubsequence(consonants(heardKey), of: consonants(nameKey))
    }

    private static func soundsWithBlock(_ heard: String, likeName name: String) -> Bool {
        guard heard.count >= 3 else { return false }
        if CorrectionClassifier.soundsAlike(heard, name) { return true }
        // A visible spelling can resolve sounds that share little orthography.
        // The ordinary repair path keeps its stricter key.
        func key(_ word: String) -> String {
            ContextSpellingFixer.phoneticKey(word.replacingOccurrences(of: "mh", with: "v"))
                .trimmingCharacters(in: CharacterSet(charactersIn: "*"))
        }
        let heardKey = key(heard), nameKey = key(name)
        if heardKey == nameKey, heardKey.count >= 2 || (name.count >= 5 && heard.count >= 4 && !heardKey.isEmpty) {
            return true
        }
        guard heardKey.count >= 2, nameKey.count >= 2 else { return false }
        return name.count >= 5 && heard.count >= 4
            && ContextSpellingFixer.levenshtein(heardKey, nameKey) == 1
            && Double(ContextSpellingFixer.levenshtein(heard, name)) / Double(max(heard.count, name.count)) <= 0.75
    }

    private static func consonants(_ key: String) -> [Character] { key.filter { $0 != "*" } }

    private static func isSubsequence(_ small: [Character], of large: [Character]) -> Bool {
        guard !small.isEmpty else { return false }
        var next = small.startIndex
        for character in large where next < small.endIndex && character == small[next] { next += 1 }
        return next == small.endIndex
    }

    private static func tokens(_ text: String) -> [Token] {
        text.split(whereSeparator: \.isWhitespace).compactMap { piece in
            let raw = piece.trimmingCharacters(in: .punctuationCharacters.union(.symbols))
            let folded = raw.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil)
                .replacingOccurrences(of: "\u{2019}", with: "'")
            let endsPhrase = piece.last.map { $0.isPunctuation } ?? false
            return raw.isEmpty ? nil : Token(raw: raw, folded: folded, endsPhrase: endsPhrase)
        }
    }
}
