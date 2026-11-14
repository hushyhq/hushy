import Foundation

/// Professional register: spell out a closed set of spoken reductions and unambiguous
/// contractions. Anything that is not clearly one of them is left as spoken.
enum ToneProfessionalRules {
    /// Pronoun contractions that have exactly one expansion.
    static let pronounExpansions: [String: String] = [
        "i'm": "i am", "we're": "we are", "you're": "you are", "they're": "they are",
        "i'll": "i will", "we'll": "we will", "you'll": "you will", "they'll": "they will",
        "he'll": "he will", "she'll": "she will", "it'll": "it will",
        "i've": "i have", "we've": "we have", "you've": "you have", "they've": "they have",
    ]

    static let negativeExpansions: [String: String] = [
        "don't": "do not", "doesn't": "does not", "didn't": "did not", "can't": "cannot",
        "won't": "will not", "isn't": "is not", "aren't": "are not",
        "wasn't": "was not", "weren't": "were not", "wouldn't": "would not", "couldn't": "could not",
        "shouldn't": "should not", "hasn't": "has not", "haven't": "have not", "hadn't": "had not",
    ]

    /// Expanded wherever the grammar allows (see `rewriteChunk`). "gotta" is not here: it is conditional,
    /// see `gottaExpansion`.
    static let reductionExpansions: [String: String] = [
        "gonna": "going to", "wanna": "want to", "kinda": "kind of", "lemme": "let me", "gimme": "give me",
    ]
    static let gottaWithHave = "got to"
    static let gottaWithSubject = "have got to"

    static var introducedWords: Set<String> {
        let phrases = Array(pronounExpansions.values) + Array(negativeExpansions.values)
            + Array(reductionExpansions.values) + [gottaWithHave, gottaWithSubject]
        return Set(phrases.flatMap { $0.split(separator: " ").map(String.init) })
    }

    private static let beWords: Set<String> = ["am", "are", "is", "was", "were", "be", "been", "isn't", "aren't", "wasn't", "weren't"]
    private static let beSuffixes = ["'m", "'re", "'s"]
    private static let subjectPronouns: Set<String> = ["i", "you", "he", "she", "it", "we", "they", "there"]
    private static let questionWords: Set<String> = ["what", "where", "who", "why", "how", "which", "when"]
    private static let wannaSubjects: Set<String> = ["i", "we", "you", "they"]
    private static let determiners: Set<String> = ["a", "an", "the"]
    private static let skippableAdverbs: Set<String> = [
        "really", "just", "also", "still", "only", "actually", "definitely", "totally",
    ]
    private static let gottaConnectives: Set<String> = [
        "and", "but", "so", "then", "because", "cause", "since", "that", "if", "when", "while", "also",
    ]
    /// Negatives that open a clause as a command ("Don't forget"); the rest there are inverted
    /// questions or elliptical ("Isn't it ready", "Can't wait").
    private static let commandNegatives: Set<String> = ["don't"]

    static func rewrite(_ chunks: [ToneChunk]) -> [ToneChunk] {
        let verbs = ToneVerbReading(chunks)
        return chunks.indices.map { rewriteChunk(chunks, at: $0, verbs: verbs) }
    }

    private static func rewriteChunk(_ chunks: [ToneChunk], at index: Int, verbs: ToneVerbReading) -> ToneChunk {
        let chunk = chunks[index]
        guard chunk.isWord, ToneText.hasPlainCase(chunk.core) else { return chunk }
        let key = chunk.lowered
        if let expansion = pronounExpansions[key] { return replace(chunk, with: expansion) }
        if let expansion = negativeExpansions[key] {
            return allowsNegativeExpansion(chunks, at: index, key: key) ? replace(chunk, with: expansion) : chunk
        }
        guard hasFollowingWord(chunks, at: index) else { return chunk }
        // A capitalised reduction inside a sentence is a name candidate ("Open Kinda Studio").
        if isReduction(key), isCapitalisedMidSentence(chunks, at: index) { return chunk }
        switch key {
        case "gonna": return followsBe(chunks, at: index) ? replace(chunk, with: "going to") : chunk
        case "wanna":
            return allowsWanna(chunks, at: index) && nextWordIsVerb(chunks, after: index, verbs)
                ? replace(chunk, with: "want to") : chunk
        case "gotta":
            guard let expansion = gottaExpansion(chunks, at: index), nextWordIsVerb(chunks, after: index, verbs) else { return chunk }
            return replace(chunk, with: expansion)
        case "kinda", "lemme", "gimme": return replace(chunk, with: reductionExpansions[key] ?? key)
        default: return chunk
        }
    }

    private static func replace(_ chunk: ToneChunk, with expansion: String) -> ToneChunk {
        chunk.replacingCore(ToneText.matchCase(expansion, like: chunk.core))
    }

    private static func hasFollowingWord(_ chunks: [ToneChunk], at index: Int) -> Bool {
        guard index + 1 < chunks.count, chunks[index].joinsNext else { return false }
        return chunks[index + 1].isWord
    }

    private static func isReduction(_ key: String) -> Bool { key == "gotta" || reductionExpansions[key] != nil }

    /// The first word of the text, or after . ! ? or a line break.
    private static func startsSentence(_ chunks: [ToneChunk], at index: Int) -> Bool {
        guard index > 0 else { return true }
        let previous = chunks[index - 1]
        return previous.gapHasNewline || previous.trail.contains { ".!?".contains($0) }
    }

    private static func isCapitalisedMidSentence(_ chunks: [ToneChunk], at index: Int) -> Bool {
        chunks[index].core.first?.isUppercase == true && !startsSentence(chunks, at: index)
    }

    /// "wanna" and "gotta" are expanded only when the next word (after any plain adverb) is read as a
    /// verb; a noun there ("I wanna coffee", "I gotta car") may mean "want a" or "got a".
    private static func nextWordIsVerb(_ chunks: [ToneChunk], after index: Int, _ verbs: ToneVerbReading) -> Bool {
        var cursor = index + 1
        while cursor + 1 < chunks.count, chunks[cursor].isWord, chunks[cursor].joinsNext,
              skippableAdverbs.contains(chunks[cursor].lowered) { cursor += 1 }
        guard cursor < chunks.count, chunks[cursor].isWord, chunks[cursor - 1].joinsNext else { return false }
        return verbs.isVerb(at: cursor)
    }

    private static func startsClause(_ chunks: [ToneChunk], at index: Int) -> Bool {
        index == 0 || chunks[index - 1].endsClause
    }

    // MARK: Negatives

    private static func allowsNegativeExpansion(_ chunks: [ToneChunk], at index: Int, key: String) -> Bool {
        if startsClause(chunks, at: index), !commandNegatives.contains(key) { return false }
        if index > 0, chunks[index - 1].isWord, chunks[index - 1].joinsNext,
           questionWords.contains(chunks[index - 1].lowered) { return false }
        if index + 1 < chunks.count, chunks[index].joinsNext, chunks[index + 1].isWord,
           subjectPronouns.contains(chunks[index + 1].lowered) { return false }
        return !sentenceIsQuestion(chunks, from: index)
    }

    private static func sentenceIsQuestion(_ chunks: [ToneChunk], from index: Int) -> Bool {
        var cursor = index
        while cursor < chunks.count {
            let trail = chunks[cursor].trail
            if trail.contains(where: { ".!?;".contains($0) }) { return trail.contains("?") }
            if chunks[cursor].gapHasNewline { return false }
            cursor += 1
        }
        return false
    }

    // MARK: Reductions

    private static func isBeForm(_ chunk: ToneChunk) -> Bool {
        guard chunk.isWord else { return false }
        let key = chunk.lowered
        if beWords.contains(key) { return true }
        return key != "let's" && beSuffixes.contains { key.hasSuffix($0) }
    }

    private static func followsBe(_ chunks: [ToneChunk], at index: Int) -> Bool {
        var cursor = index - 1
        guard cursor >= 0, chunks[cursor].joinsNext else { return false }
        if chunks[cursor].isWord, chunks[cursor].core == "not" {
            cursor -= 1
            guard cursor >= 0, chunks[cursor].joinsNext else { return false }
        }
        return isBeForm(chunks[cursor])
    }

    private static func allowsWanna(_ chunks: [ToneChunk], at index: Int) -> Bool {
        if determiners.contains(chunks[index + 1].lowered) { return false }
        if startsClause(chunks, at: index) { return true }
        var cursor = index - 1
        while cursor >= 0, chunks[cursor].joinsNext, chunks[cursor].isWord,
              skippableAdverbs.contains(chunks[cursor].lowered) { cursor -= 1 }
        guard cursor >= 0, chunks[cursor].joinsNext, chunks[cursor].isWord else { return false }
        let previous = chunks[cursor]
        if wannaSubjects.contains(previous.lowered) { return true }
        if previous.lowered == "do" || previous.lowered == "don't" { return true }
        return previous.core == "not" && cursor > 0 && chunks[cursor - 1].isWord && chunks[cursor - 1].lowered == "do"
    }

    /// "gotta" is the one reduction that is NOT expanded everywhere. It becomes "got to" after
    /// have/has/'ve/'s, and "have got to" after I, we, you or they only when that subject starts a clause
    /// or follows a plain connective (and, but, so, then, because...). Anywhere else it is left as spoken:
    /// "Hey Tomas I gotta go" (no clause boundary after the name) stays, "Hey Tomas, I gotta go" expands.
    /// "gonna" needs a form of "be" before it, and "wanna" a subject or "do"/"don't"; see `rewriteChunk`.
    private static func gottaExpansion(_ chunks: [ToneChunk], at index: Int) -> String? {
        guard index > 0, chunks[index - 1].isWord, chunks[index - 1].joinsNext else { return nil }
        let previous = chunks[index - 1]
        let key = previous.lowered
        if key == "have" || key == "has" || key.hasSuffix("'ve") || (key.hasSuffix("'s") && key != "let's") {
            return gottaWithHave
        }
        guard wannaSubjects.contains(key) else { return nil }
        if startsClause(chunks, at: index - 1) { return gottaWithSubject }
        let before = chunks[index - 2]
        let connects = before.isWord && before.joinsNext && gottaConnectives.contains(before.lowered)
        return connects ? gottaWithSubject : nil
    }
}
