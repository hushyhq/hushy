import Foundation

/// The small, closed set of single-word doublings that are ordinary English rather than a
/// stutter — "very very cold", "she had had enough", "he said that that approach…", "bye bye",
/// "no no", "the demo went so so", "what it is is…", "I like like buttons".
///
/// Everything outside this set is treated as a possible disfluency: a doubled discourse marker
/// ("actually actually"), pronoun ("it it"), article ("the the"), contraction ("it's it's") or
/// auxiliary ("is is") is a stutter. That split drives two things:
/// - `LegitRepeatGuard` only rejects a model answer that collapses a double from this set, so
///   the model is free to remove every other doubling;
/// - `StutterCollapse` (rules) collapses a doubling only from its own closed stutter set, and
///   never one this type calls legitimate in context.
///
/// Context matters for four words: "so so" is the idiom only after a linking verb or before a
/// clause break, never sentence-initially ("so so we should…" is a stutter); "is is"/"was was"
/// only in a pseudo-cleft ("what it is is", "all it was was"); "like like" only after a subject
/// or auxiliary ("I like like buttons", "do you like like her"). The rest are legitimate anywhere.
public enum LegitDoubles {
    /// Doublings that are ordinary speech wherever they occur: intensifier reduplication
    /// ("very very", "much much better", "far far away", "many many years", "long long ago",
    /// "way way too"), the past perfect "had had", demonstrative/complementizer "that that",
    /// set phrases and onomatopoeia ("bye bye", "night night", "knock knock", "ha ha",
    /// "blah blah", "tsk tsk", "chop chop", "hush hush"), and an emphatic "no no".
    static let alwaysLegitimate: Set<String> = [
        "very", "really", "much", "far", "many", "long", "way",
        "had", "that", "bye", "no", "night", "knock", "ha", "haha", "blah", "tsk", "chop", "hush",
    ]

    /// Words whose doubling is legitimate only in some contexts (see the type doc).
    static let contextual: Set<String> = ["so", "is", "was", "like"]

    /// Linking verbs (and a few degree words) after which "so so" is the idiom "mediocre":
    /// "went so so", "it was so so", "felt pretty so so".
    private static let soSoLeadIns: Set<String> = [
        "went", "go", "goes", "going", "was", "is", "were", "are", "been", "be", "feel", "feels",
        "felt", "look", "looks", "looked", "seem", "seems", "seemed", "sound", "sounds", "sounded",
        "it's", "that's", "pretty", "just", "only", "kinda", "rather", "fairly", "quite", "turned",
    ]

    /// Words that, right after "so so", show it closed a clause as the idiom ("so so but…",
    /// "so so at best", "so so though").
    private static let soSoFollowers: Set<String> = ["but", "and", "at", "though", "honestly", "really", "overall"]

    private static let subjectsAndAuxiliaries: Set<String> = [
        "i", "you", "we", "they", "he", "she", "people", "do", "does", "did", "don't", "doesn't",
        "didn't", "would", "wouldn't", "i'd", "you'd", "we'd", "they'd", "really", "also", "just",
        "actually", "still", "all",
    ]

    private static let pseudoCleftSubjects: Set<String> = ["it", "this", "that", "he", "she", "they"]
    private static let pseudoCleftOpeners: Set<String> = ["what", "all", "how", "where", "why", "who"]

    /// Whether the doubled word at `index` (followed by an identical word at `index + 1`) in
    /// `words` is a legitimate doubling. `words` are comparison keys (see `key(_:)`); `sentenceStart`
    /// is true when `index` is the first word of its sentence.
    public static func isLegitimate(_ words: [String], at index: Int, sentenceStart: Bool) -> Bool {
        guard index >= 0, index + 1 < words.count, words[index] == words[index + 1] else { return false }
        let word = words[index]
        if alwaysLegitimate.contains(word) { return true }
        let previous = index > 0 && !sentenceStart ? words[index - 1] : nil
        switch word {
        case "so":
            guard let previous else { return false }
            if soSoLeadIns.contains(previous) { return true }
            let next = index + 2 < words.count ? words[index + 2] : nil
            return next == nil || soSoFollowers.contains(next!)
        case "is", "was":
            guard let previous, pseudoCleftSubjects.contains(previous) else { return false }
            let window = words[max(0, index - 4)..<(index - 1)]
            return window.contains { pseudoCleftOpeners.contains($0) }
        case "like":
            guard let previous else { return false }
            return subjectsAndAuxiliaries.contains(previous)
        default:
            return false
        }
    }

    /// Comparison key for a whitespace token: lowercased, curly apostrophes straightened, and
    /// leading/trailing punctuation stripped ("It's," -> "it's", "so-so" stays one token).
    public static func key(_ token: String) -> String {
        token.lowercased()
            .replacingOccurrences(of: "\u{2019}", with: "'")
            .trimmingCharacters(in: CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "'")).inverted)
    }

    /// Every legitimate double in `text`, as the doubled word, in order ("very", "that", …).
    /// Used by `LegitRepeatGuard` to compare a draft against a model answer.
    public static func legitimateDoubles(in text: String) -> [String] {
        let tokens = text.split(whereSeparator: \.isWhitespace).map(String.init)
        let keys = tokens.map(key)
        var found: [String] = []
        var index = 0
        while index + 1 < keys.count {
            let sentenceStart = index == 0 || tokens[index - 1].last.map { ".!?".contains($0) } == true
            if !keys[index].isEmpty, !endsSentence(tokens[index]),
               isLegitimate(keys, at: index, sentenceStart: sentenceStart) {
                found.append(keys[index])
                index += 2
            } else {
                index += 1
            }
        }
        return found
    }

    static func endsSentence(_ token: String) -> Bool {
        guard let last = token.trimmingCharacters(in: CharacterSet(charactersIn: "\"')]\u{201D}")).last else { return false }
        return ".!?".contains(last)
    }
}

/// Deterministic removal of unambiguous word and phrase stutters — run by the rules at `.clean`
/// and `.polished` (never `.verbatim`), before the model is consulted.
///
/// - A single-word doubling is collapsed only for words in `stutterWords` (articles, subject
///   pronouns, possessives, contractions, copulas, a few conjunctions and prepositions), and
///   never when `LegitDoubles` calls it legitimate in context. Object pronouns that are often
///   legitimately followed by the same word as a subject ("I told you you were right", "I gave
///   her her keys") are deliberately left out; so are modals ("can can") and "do" ("they do do
///   it"), which stay a judgment call for the model.
/// - An exact adjacent repeat of a 2–6 word phrase ("we should we should", "i'm not i'm not",
///   "the problem is the problem is") is collapsed to one copy: a multi-word phrase repeated
///   verbatim is essentially never intentional in dictation.
///
/// A doubling never collapses across a sentence end ("It is. Is it?").
public enum StutterCollapse {
    static let stutterWords: Set<String> = [
        "a", "an", "the", "i", "we", "they", "he", "she", "it", "my", "our", "their", "its",
        "is", "are", "was", "were", "am", "and", "but", "or", "to", "of", "in", "if",
        "it's", "i'm", "i've", "i'll", "i'd", "we're", "we've", "we'll", "they're", "they've",
        "that's", "there's", "he's", "she's", "what's", "you're", "tell",
    ]

    public static func apply(_ text: String) -> String {
        // Keep quoted spans byte-for-byte. Apostrophes in contractions are not quote marks.
        var result = ""
        var unquoted = ""
        var quoted = ""
        var closingQuote: Character?
        var previous: Character?
        for character in text {
            if let closing = closingQuote {
                quoted.append(character)
                if character == closing {
                    result += quoted
                    quoted = ""
                    closingQuote = nil
                }
            } else if character == "\"" || character == "\u{201C}" || character == "\u{2018}"
                || (character == "'" && previous?.isLetter != true) {
                selfAppendUnquoted(&result, &unquoted)
                quoted = String(character)
                closingQuote = character == "\u{201C}" ? "\u{201D}" : (character == "\u{2018}" ? "\u{2019}" : character)
            } else {
                unquoted.append(character)
            }
            previous = character
        }
        result += quoted
        selfAppendUnquoted(&result, &unquoted)
        return result
    }

    private static func selfAppendUnquoted(_ result: inout String, _ unquoted: inout String) {
        result += applyUnquoted(unquoted)
        unquoted = ""
    }

    private static func applyUnquoted(_ text: String) -> String {
        let leading = text.prefix(while: \.isWhitespace)
        if leading.count == text.count { return text }
        let trailing = text.reversed().prefix(while: \.isWhitespace)
        let core = String(text.dropFirst(leading.count).dropLast(trailing.count))
        var out = collapseWords(core)
        out = collapsePhrases(out)
        out = dropAbandonedNegatedRestart(out)
        // A phrase collapse can expose a new single-word doubling ("we we should we should" ->
        // "we we should" is already handled first, but "and then and then i i" needs both).
        return String(leading) + collapseWords(out) + String(trailing.reversed())
    }

    static func collapseWords(_ text: String) -> String {
        // Line structure (lists, "new line") is preserved by working line by line.
        text.components(separatedBy: "\n").map(collapseWordsInLine).joined(separator: "\n")
    }

    private static func collapseWordsInLine(_ line: String) -> String {
        var tokens = line.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
        guard tokens.count > 1 else { return line }
        var index = 0
        while index + 1 < tokens.count {
            let keys = tokens.map(LegitDoubles.key)
            let word = keys[index]
            let sentenceStart = index == 0 || LegitDoubles.endsSentence(tokens[index - 1])
            let isBoundaryPair = !word.isEmpty && word == keys[index + 1] && BoundaryRepeatGuard.isBoundaryAnchor(word)
                && index > 0
            let isStutter = !isBoundaryPair && !word.isEmpty && word == keys[index + 1] && stutterWords.contains(word)
                && !LegitDoubles.endsSentence(tokens[index])
                && !LegitDoubles.isLegitimate(keys, at: index, sentenceStart: sentenceStart)
                && isPlainWord(tokens[index])
            if isBoundaryPair {
                index += 2
            } else if isStutter {
                // Keep the second copy (it carries any trailing punctuation), but take the first
                // copy's capitalization so a sentence-initial "It's it's" stays capitalized.
                let first = tokens[index]
                var second = tokens[index + 1]
                if first.first?.isUppercase == true, let head = second.first, head.isLowercase {
                    second = head.uppercased() + second.dropFirst()
                }
                tokens.remove(at: index)
                tokens[index] = second
            } else {
                index += 1
            }
        }
        return tokens.joined(separator: " ")
    }

    /// A token that is just a word with optional trailing comma — not quoted, not code, not an
    /// ALL-CAPS acronym ("IT IT department" is left alone).
    private static func isPlainWord(_ token: String) -> Bool {
        let stripped = token.trimmingCharacters(in: CharacterSet(charactersIn: ",-"))
        guard !stripped.isEmpty, stripped.allSatisfy({ $0.isLetter || $0 == "'" || $0 == "\u{2019}" }) else { return false }
        return !(stripped.count > 1 && stripped == stripped.uppercased())
    }

    /// "<2–3 word lead-in> not|never <same lead-in> …" is a restart that abandoned the first
    /// attempt: "we should not we should never load it" -> "we should never load it", "i do not i
    /// do want it" -> "i do want it". The later attempt is kept, as with every restart; a
    /// one-word lead-in ("it not it") is too ambiguous and is left to the model.
    static func dropAbandonedNegatedRestart(_ text: String) -> String {
        let pattern = "\\b((?:[A-Za-z'\u{2019}]+\\s+){2,3})(?:not|never)\\s+(?=\\1)"
        return Regex.replace(text, pattern, with: "")
    }

    static func collapsePhrases(_ text: String) -> String {
        // 2–6 words, repeated immediately (an optional comma between).
        // `Regex` is case-insensitive, so "We should we should" collapses too.
        let pattern = "\\b((?:[A-Za-z'\u{2019}]+\\s+){1,5}[A-Za-z'\u{2019}]+)\\b(?:,?\\s+\\1\\b)+"
        return Regex.replace(text, pattern) { whole, groups in
            guard groups.count > 1 else { return whole }
            let phrase = groups[1]
            // Legitimate doubled single words inside a two-word phrase ("very very very very")
            // are not a phrase restart; and an ALL-CAPS phrase is likely deliberate emphasis.
            let words = phrase.split(whereSeparator: \.isWhitespace).map { LegitDoubles.key(String($0)) }
            if Set(words).count == 1, LegitDoubles.alwaysLegitimate.contains(words[0]) { return whole }
            if phrase.count > 3, phrase == phrase.uppercased() { return whole }
            // Number words alone are digits of one number ("four one five five five five ..." is a phone
            // number, "two two two two" a code): repeating them is what the number says, never a stutter.
            if words.allSatisfy(isSpokenNumberWord) { return whole }
            let after = BoundaryRepeatGuard.wordAfterMatch(whole, in: text)
            if BoundaryRepeatGuard.preservesPhraseRepeat(phrase, wordAfter: after) { return whole }
            return phrase
        }
    }

    /// A cardinal or ordinal number word, or the "oh" spoken for a zero inside digits.
    private static func isSpokenNumberWord(_ word: String) -> Bool {
        word == "oh" || SpokenNumberRuns.isNumberWord(word)
    }
}
