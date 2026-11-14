import Foundation

/// "Context awareness": read up to ~1,000 characters around the insertion point in the focused
/// app when dictation starts, pull out candidate names/terms from that text, and use them for
/// *this dictation only* — as temporary vocabulary-boost terms (still filtered through
/// `BoostGuard`, see `VocabularyContext`) and in a conservative post-ASR spelling-fix pass that
/// maps a near-miss ASR word onto a term actually present in the surrounding text.
///
/// Everything here is pure/testable and holds no state: the caller (`DictationController`) reads
/// the surrounding text once via the Accessibility API, calls `ContextExtractor.extract`, uses
/// the result for one dictation, and drops it — nothing captured is logged or persisted (see
/// `.claude/DECISIONS.md`'s context-awareness entry).
public enum ContextExtractor {
    /// Longest surrounding-text window read at dictation start (±1,000 characters), matching the
    /// task's "up to ±1,000 characters around the insertion point" requirement.
    public static let maxWindowLength = 1000
    /// A term must be at least this long to be worth boosting/fixing — 1–2 letter tokens produce
    /// far too many accidental matches in the spelling-fix pass.
    static let minTermLength = 3
    /// Caps how many candidate terms one extraction returns, so a boost list built from a huge
    /// paragraph doesn't dilute or slow down vocabulary boosting.
    static let maxTerms = 24

    /// Pulls candidate names/terms out of surrounding editor text: capitalized words (not
    /// sentence-initial — see `looksSentenceInitial`), the local part of email addresses, and
    /// camelCase/snake_case identifiers. Returns terms in first-seen order, deduplicated
    /// case-insensitively, longest surface form kept when the same key repeats.
    public static func extract(from text: String) -> [String] {
        extract(from: text, window: maxWindowLength, limit: maxTerms)
    }

    /// `extract` over the last `window` characters, keeping at most `limit` terms. The window reader passes the whole
    /// of what it read (up to `WindowTextReader.Budget.maxCharacters`) and the merged-term cap.
    public static func extract(from text: String, window: Int, limit: Int) -> [String] {
        guard !text.isEmpty else { return [] }
        let windowed = String(text.suffix(window))
        var seen: [String: String] = [:] // lowercase key -> best surface form
        var order: [String] = []

        func consider(_ term: String) {
            let trimmed = term.trimmingCharacters(in: CharacterSet(charactersIn: "._-"))
            guard trimmed.count >= minTermLength, trimmed.count <= 64 else { return }
            let key = trimmed.lowercased()
            guard !commonWordDenylist.contains(key), ScreenBoostPolicy.shouldBoost(trimmed) else { return }
            if let existing = seen[key] {
                // Prefer a longer surface form, or — when the same length — a capitalized one
                // over a lowercase one (e.g. "Rutger" over the email-local-part "rutger"):
                // capitalization carries real information about how the name should be spelled.
                let existingIsCapitalized = existing.first?.isUppercase ?? false
                let trimmedIsCapitalized = trimmed.first?.isUppercase ?? false
                if trimmed.count > existing.count || (trimmed.count == existing.count && trimmedIsCapitalized && !existingIsCapitalized) {
                    seen[key] = trimmed
                }
            } else {
                seen[key] = trimmed
                order.append(key)
            }
        }

        for email in emailLocalParts(in: windowed) { consider(email) }
        for handle in Regex.matchesCaseSensitive(windowed, "@[A-Za-z][A-Za-z0-9_]{2,63}") {
            if let value = handle.string(at: 0, in: windowed) { consider(value) }
        }
        // Whole words in any script ("Kristaps Porziņģis", "De'Aaron Fox"): never the tail of a word ("Aaron Fox" in
        // "De'Aaron Fox", which the boost then wrote over the whole name).
        let nameWord = "\\p{Lu}\\p{Ll}+(?:['’]\\p{Lu}\\p{Ll}+)?"
        let nameMatches = Regex.matchesCaseSensitive(
            windowed, "(?<![\\p{L}\\p{N}])(?<!\\p{L}['’])\(nameWord)(?:[ ]+\(nameWord)){1,2}(?![\\p{L}\\p{N}])")
        for name in nameMatches {
            if let value = name.string(at: 0, in: windowed) { consider(value) }
        }
        for identifier in codeIdentifiers(in: windowed) { consider(identifier) }
        for word in capitalizedWords(in: windowed) { consider(word) }
        for word in Regex.matchesCaseSensitive(windowed, "\\b[a-z][a-z]{5,24}\\b") {
            if let value = word.string(at: 0, in: windowed), !LearningLexicon.isCommonWord(value) {
                consider(value)
            }
        }

        return order.prefix(limit).compactMap { seen[$0] }
    }

    /// Capitalized tokens that are not the first word of a sentence (sentence-initial
    /// capitalization is just English grammar, not a name/term worth boosting). A token counts
    /// as sentence-initial when it is the first word of the window or immediately follows
    /// sentence-ending punctuation (with optional whitespace/quotes between).
    static func capitalizedWords(in text: String) -> [String] {
        var results: [String] = []
        // Letters of any script, so "Porziņģis" is one word and not "Porzi".
        let tokens = Regex.matchesCaseSensitive(text, "(?<![\\p{L}\\p{N}])\\p{L}[\\p{L}'’-]*")
        for match in tokens {
            guard let range = Range(match.range, in: text) else { continue }
            let word = String(text[range])
            guard let first = word.first, first.isUppercase else { continue }
            // All-uppercase acronyms (API, URL) are useful boost terms; skip single letters.
            guard word.count >= minTermLength else { continue }
            if looksSentenceInitial(text, before: range) { continue }
            results.append(word)
        }
        return results
    }

    /// True when the text immediately preceding `range` is the start of the window or a
    /// sentence terminator, allowing intervening whitespace/quote characters.
    private static func looksSentenceInitial(_ text: String, before range: Range<String.Index>) -> Bool {
        var index = range.lowerBound
        if index == text.startIndex { return true }
        while index > text.startIndex {
            let previous = text.index(before: index)
            let char = text[previous]
            if char.isWhitespace || char == "\"" || char == "'" || char == "\u{201C}" || char == "\u{201D}" {
                index = previous
                continue
            }
            return char == "." || char == "!" || char == "?" || char == "\n"
        }
        return true
    }

    /// The local part of an email address ("ada" from "ada@example.com") — a reliable
    /// source of names/handles the ASR is likely to mangle.
    static func emailLocalParts(in text: String) -> [String] {
        Regex.matchesCaseSensitive(text, "\\b([A-Za-z0-9._%+-]{2,64})@[A-Za-z0-9.-]+\\.[A-Za-z]{2,}\\b").compactMap {
            $0.string(at: 1, in: text)
        }
    }

    /// camelCase and snake_case identifiers — jargon/API names a plain-English ASR model has no
    /// hope of getting right from context alone. Splits into readable pieces (`myAccountId` ->
    /// "myAccountId" kept whole; also worth boosting as-is since users say identifiers as words).
    static func codeIdentifiers(in text: String) -> [String] {
        var results: [String] = []
        // snake_case: two or more lowercase/number segments joined by underscores.
        for match in Regex.matchesCaseSensitive(text, "\\b[a-z][a-z0-9]*(?:_[a-z0-9]+)+\\b") {
            if let value = match.string(at: 0, in: text) { results.append(value) }
        }
        // camelCase: a lowercase-starting token with at least one internal uppercase letter.
        for match in Regex.matchesCaseSensitive(text, "\\b[a-z][a-z0-9]*(?:[A-Z][a-z0-9]*)+\\b") {
            if let value = match.string(at: 0, in: text) { results.append(value) }
        }
        // Letters with digits, joined or not: run names, tickets, versions and models ("rl-v9", "TRY-95", "v2.3",
        // "gpt4o"). Without this the capitalized-word pass cut "TRY-95" to "TRY" and lowercase ones were never read.
        for match in Regex.matchesCaseSensitive(text, "(?<![A-Za-z0-9_.-])[A-Za-z][A-Za-z0-9]*(?:[-_.][A-Za-z0-9]+)*") {
            if let value = match.string(at: 0, in: text), value.contains(where: \.isNumber),
               ScreenTermShape.kind(of: value) == .identifier {
                results.append(value)
            }
        }
        return results
    }

    /// Common capitalized words that are not worth boosting even when not sentence-initial
    /// (days, months, pronoun "I", common titles) — keeps the candidate list focused on genuine
    /// names/jargon rather than every capitalized word an editor happens to contain.
    static let commonWordDenylist: Set<String> = [
        "i", "monday", "tuesday", "wednesday", "thursday", "friday", "saturday", "sunday",
        "january", "february", "march", "april", "may", "june", "july", "august", "september",
        "october", "november", "december", "mr", "mrs", "ms", "dr", "the", "a", "an",
    ]
}

/// Fixes near-miss ASR words by mapping them onto a context term when the two are close enough
/// (edit distance) and sound alike enough (phonetic key) — deliberately conservative so this
/// never rewrites an ordinary word the recognizer heard correctly. Distinct from `BoostGuard`,
/// which reverts CTC vocabulary-boost substitutions; this pass instead *introduces* a fix by
/// comparing the plain (unboosted) ASR output against terms pulled from surrounding context.
public enum ContextSpellingFixer {
    /// Maximum character edit distance allowed between an ASR word and a context term for a fix
    /// to be considered — conservative so unrelated short words never match by chance.
    static func maxEditDistance(for termLength: Int) -> Int {
        switch termLength {
        case ..<5: 1
        case 5..<9: 2
        default: 3
        }
    }

    /// Rewrites words in `text` that are a close edit-distance/phonetic match for one of
    /// `terms` and not already an exact (case-insensitive) match, so the fixer never touches a
    /// word that's already correct. Terms shorter than `ContextExtractor.minTermLength` are
    /// ignored (see that constant) to avoid false positives on very short words.
    public static func fix(_ text: String, terms: [String]) -> String { applyFix(text, terms: terms) }

    /// Like `fix`, but also returns how many whitespace tokens changed.
    public static func fixCounting(_ text: String, terms: [String]) -> (text: String, repairs: Int) {
        guard !terms.isEmpty, !text.isEmpty else { return (text, 0) }
        let after = applyFix(text, terms: terms)
        let repairs = zip(text.split(whereSeparator: \.isWhitespace), after.split(whereSeparator: \.isWhitespace))
            .filter { $0.0 != $0.1 }.count
        return (after, repairs)
    }

    private static func applyFix(_ text: String, terms: [String]) -> String {
        guard !terms.isEmpty, !text.isEmpty else { return text }
        // A letters-only near miss never becomes a term with a digit in it: "rl-v9" on screen once turned the heard
        // "Rl-v9" into "rl-v99" (the letters "Rl-v" matched it). Identifiers are matched exactly by `ScreenIdentifierJoiner`.
        let candidates = terms.filter { $0.count >= ContextExtractor.minTermLength && !$0.contains(where: \.isNumber) }
        guard !candidates.isEmpty else { return text }

        let tokens = Regex.matchesCaseSensitive(text, "[A-Za-z][A-Za-z'’-]*")
        guard !tokens.isEmpty else { return text }

        var output = text

        // Walk matches in reverse so earlier replacements don't invalidate later ranges.
        for match in tokens.reversed() {
            guard let range = Range(match.range, in: output), !isInsideLargerToken(range, in: output) else { continue }
            let word = String(output[range])
            guard let replacement = bestMatch(for: word, in: candidates) else { continue }
            output.replaceSubrange(range, with: replacement)
        }
        return output
    }

    /// True when the letters at `range` are only part of a longer token: a digit, letter, underscore, slash or "@" is
    /// next to them, or a dot with a letter or digit beyond it ("v9", "auth.swift", "user_name").
    static func isInsideLargerToken(_ range: Range<String.Index>, in text: String) -> Bool {
        func joins(_ char: Character) -> Bool { char.isLetter || char.isNumber || "_/@".contains(char) }
        if range.lowerBound > text.startIndex {
            let before = text.index(before: range.lowerBound)
            if joins(text[before]) { return true }
            if text[before] == ".", before > text.startIndex, joins(text[text.index(before: before)]) { return true }
        }
        if range.upperBound < text.endIndex {
            let after = text[range.upperBound]
            if joins(after) { return true }
            let next = text.index(after: range.upperBound)
            if after == ".", next < text.endIndex, joins(text[next]) { return true }
        }
        return false
    }

    /// Finds the best context term to substitute for `word`, or nil when nothing is close enough.
    static func bestMatch(for word: String, in terms: [String]) -> String? {
        let key = word.lowercased()
        guard key.count >= ContextExtractor.minTermLength else { return nil }
        guard !LearningLexicon.isCommonWord(key) else { return nil }

        var matches: [(term: String, distance: Int)] = []
        for term in terms {
            let termKey = term.lowercased()
            guard termKey != key else { return nil } // already exact, nothing to fix
            if LearningLexicon.isCommonWord(termKey) { continue }
            guard abs(termKey.count - key.count) <= 3 else { continue }
            let distance = levenshtein(key, termKey)
            // Require phonetic agreement too, so "chat" -> "chart" (distance 1, different
            // sound) doesn't fire just because it's numerically close.
            guard phoneticKey(key) == phoneticKey(termKey) else { continue }
            guard distance <= maxEditDistance(for: termKey.count) else { continue }
            matches.append((term, distance))
        }
        guard let best = matches.min(by: { $0.distance < $1.distance }) else { return nil }
        // A second plausible term close to the winner makes the intended spelling unclear.
        // Require a two-edit margin; ties and one-edit near-ties leave the ASR token untouched.
        let runnerUpDistance = matches.lazy.map(\.distance).filter { $0 != best.distance }.min()
        if let runnerUpDistance, runnerUpDistance - best.distance < 2 { return nil }
        // Equal-distance candidates are ambiguous too (the distance filter above intentionally
        // excludes every candidate tied with `best` from runnerUpDistance).
        guard matches.filter({ $0.distance == best.distance }).count == 1 else { return nil }
        return best.term
    }

    /// Character-level Levenshtein distance.
    static func levenshtein(_ a: String, _ b: String) -> Int {
        let a = Array(a), b = Array(b)
        if a.isEmpty { return b.count }
        if b.isEmpty { return a.count }
        var previous = Array(0...b.count)
        var current = [Int](repeating: 0, count: b.count + 1)
        for i in 1...a.count {
            current[0] = i
            for j in 1...b.count {
                let cost = a[i - 1] == b[j - 1] ? 0 : 1
                current[j] = min(previous[j] + 1, current[j - 1] + 1, previous[j - 1] + cost)
            }
            swap(&previous, &current)
        }
        return previous[b.count]
    }

    /// A coarse, dependency-free phonetic key: collapses vowels to a single marker, drops
    /// doubled consonants, drops silent "h" (Sioban/Siobhan, John/Jon-style mishears), and folds
    /// a handful of common ASR-confusable consonant pairs to the same symbol (c/k, s/z, f/v,
    /// j/g). Not a full Soundex/Metaphone implementation, but enough to reject
    /// numerically-close-but-different-sounding pairs like "chat"/"chart" while still matching
    /// "Sioban"/"Siobhan" and "Cooper Netties"-style mishears.
    static func phoneticKey(_ word: String) -> String {
        let vowels: Set<Character> = ["a", "e", "i", "o", "u", "y"]
        let foldMap: [Character: Character] = [
            "k": "c", "z": "s", "j": "g", "v": "f", "w": "u", "q": "k",
        ]
        var result = ""
        var lastEmitted: Character?
        // "x" is spoken "ks": Codex and "codecs", relix and "relics" are one sound.
        for raw in word.lowercased().replacingOccurrences(of: "x", with: "cs") {
            guard raw.isLetter, raw != "h" else { continue }
            let folded = foldMap[raw] ?? raw
            let symbol: Character = vowels.contains(folded) ? "*" : folded
            if symbol == lastEmitted { continue } // collapse doubles/adjacent vowel runs
            result.append(symbol)
            lastEmitted = symbol
        }
        return result
    }
}
