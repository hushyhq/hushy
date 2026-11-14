import Foundation

/// Resolves a near-duplicate self-repair: the speaker starts a word (or short compound), catches
/// themselves mid-word or right after, and immediately repeats a corrected version — "select the
/// stop clock, stopwatch" → "select the stopwatch"; "the Tues-, Tuesday" → "the Tuesday"; "Sat,
/// Saturday" → "Saturday".
///
/// Unlike `SelfCorrection`, there is no cue word ("no", "actually") — the repair is signalled
/// only by the two sides being the *same word*, one a truncation/near-miss of the other. This is
/// deliberately tight: only the single word (or short hyphenated compound) immediately before the
/// comma and the single word immediately after are compared, so a plain list ("apples, oranges",
/// "red, green") never satisfies the repair test, and the rest of the sentence is never touched —
/// only the repaired word itself is replaced, everything around it (including "is on", "the")
/// stays exactly as spoken.
enum SelfRepair {
    static func apply(_ text: String) -> String {
        var current = text
        for _ in 0..<6 {
            guard let next = resolveFirst(current) else { break }
            current = next
        }
        return current
    }

    /// Group 1: up to two words right before the comma, optionally with a trailing hyphen
    /// marking an explicit mid-word cut ("Tues-,"). Two words lets the repair test try both
    /// the single last word ("clock") and the two words concatenated ("stopclock") against
    /// the repair — the latter catches a compound like "stop clock" -> "stopwatch" that the
    /// last word alone ("clock" vs "stopwatch") is too dissimilar to match confidently.
    /// Group 2: the single word right after the comma — a repair replaces one word/compound
    /// with one word, never a longer phrase, so the second side stays narrow on purpose.
    private static let pattern = "\\b(?:([A-Za-z][A-Za-z']*)\\s+)?([A-Za-z][A-Za-z']*)-?,\\s+([A-Za-z][A-Za-z']*)\\b"

    private static func resolveFirst(_ text: String) -> String? {
        // Every candidate `word, word` shape in the text is checked in order, not just the
        // first — a long dictation can have several unrelated comma-separated word pairs before
        // the real self-repair (an ordinary list item, a rejected near-miss), and the original
        // version of this rule gave up entirely the moment the *first* one failed the guards
        // below, silently leaving every later, valid repair (in a different sentence) untouched.
        for match in Regex.matches(text, pattern) {
            guard let lastWord = match.string(at: 2, in: text),
                  let second = match.string(at: 3, in: text),
                  let wholeRange = Range(match.range(at: 0), in: text)
            else { continue }
            let precedingWord = match.string(at: 1, in: text)

            guard isCloseRepair(lastWord: lastWord, precedingWord: precedingWord, second: second) else { continue }
            guard !isPartOfLongerList(text, around: wholeRange) else { continue }
            return resolve(match: match, text: text, lastWord: lastWord, second: second,
                           precedingWord: precedingWord, wholeRange: wholeRange)
        }
        return nil
    }

    private static func resolve(
        match: NSTextCheckingResult, text: String, lastWord: String, second: String,
        precedingWord: String?, wholeRange: Range<String.Index>
    ) -> String? {

        // Only the matched span before the comma is replaced with `second`; a `precedingWord`
        // that was captured but did NOT contribute to the match (the single-word comparison was
        // the one that fired) must be kept, so replace starting from `lastWord`'s own range
        // instead of the whole capture when `precedingWord` exists but wasn't the reason this
        // matched.
        let lastWordRange = match.range(at: 2)
        guard let replaceRange = Range(lastWordRange, in: text) else { return nil }
        let matchedOnCompound = precedingWord != nil && isCloseRepair(lastWord: precedingWord! + lastWord, precedingWord: nil, second: second)
        if matchedOnCompound, let fullRange = Range(match.range, in: text) {
            return text.replacingCharacters(in: fullRange, with: second)
        }
        return text.replacingCharacters(in: replaceRange.lowerBound..<wholeRange.upperBound, with: second)
    }

    /// True when `second` is confidently a self-repair of `lastWord` (or, when present, of
    /// `precedingWord + lastWord` concatenated as a compound) — the same normalized stem with a
    /// short, real edit (truncation or near-miss) — never two independent short words that merely
    /// start alike ("cat"/"car" must NOT trigger).
    private static func isCloseRepair(lastWord: String, precedingWord: String?, second: String) -> Bool {
        if isCloseRepairPair(WordDiff.key(lastWord), WordDiff.key(second)) { return true }
        if let precedingWord {
            return isCloseRepairPair(WordDiff.key(precedingWord + lastWord), WordDiff.key(second))
        }
        return false
    }

    private static func isCloseRepairPair(_ a: String, _ b: String) -> Bool {
        guard !a.isEmpty, !b.isEmpty, a != b else { return false } // identical repeat is a stutter, handled elsewhere

        // Case 1: a truncated fragment that is a strict prefix of the repair, at least 3
        // characters of shared material and missing at least 2 characters of the full word —
        // "tues" -> "tuesday", "sat" -> "saturday". The 3-character floor keeps very short
        // words ("a", "to") from ever qualifying as a "truncation" of a longer word.
        if b.hasPrefix(a), a.count >= 3, b.count - a.count >= 2 { return true }
        if a.hasPrefix(b), b.count >= 3, a.count - b.count >= 2 { return false } // repair shorter than original: not a forward repair

        // Case 2: a compound/near-miss repair that shares a long lead-in but is not a strict
        // prefix — "stopclock" (from "stop clock") -> "stopwatch" shares "stop" then diverges
        // completely. Deliberately prefix-based rather than a global edit-distance/substring
        // heuristic: a 4+ character shared prefix with a meaningfully different remainder on
        // both sides is common to real repairs but essentially never happens between two
        // unrelated short list items ("cat"/"car" shares only 2, "start"/"stark" only 3,
        // "cats"/"cars" only 3) — see the negative tests in SelfRepairTests for the words this
        // was checked against.
        let sharedPrefix = commonPrefixLength(a, b)
        return sharedPrefix >= 4 && min(a.count, b.count) - sharedPrefix >= 2
    }

    private static func commonPrefixLength(_ a: String, _ b: String) -> Int {
        var count = 0
        for (x, y) in zip(a, b) {
            guard x == y else { break }
            count += 1
        }
        return count
    }

    /// A run of 3+ comma-separated segments in the sentence containing the match means this is a
    /// list, not an isolated repair — e.g. "apples, oranges, bananas" must never fire, and a
    /// match inside a longer enumeration (even a 2-word one, like "milk, eggs, bread") is safely
    /// excluded this way since the third comma reveals the list shape.
    private static func isPartOfLongerList(_ text: String, around range: Range<String.Index>) -> Bool {
        guard let sentence = Sentences.split(text).first(where: { text.range(of: $0)?.overlaps(range) ?? false })
        else { return false }
        let parts = sentence.components(separatedBy: ",").map { $0.trimmingCharacters(in: .whitespaces) }
        return parts.count >= 3
    }

    /// True when `ruled` (the already rule-cleaned output) still contains a two-word,
    /// comma-separated pair that shares a real but sub-threshold prefix — close enough to look
    /// like a possible repair, not close enough for `isCloseRepairPair`'s confident bar (a
    /// shared prefix of 2-3 characters, versus the 4+ this rule requires to act on its own).
    /// Used only as a hint for `ModelHints.worthAsking`: a borderline pair like this is exactly
    /// the kind of judgment call this deterministic rule is designed to decline rather than
    /// guess at, so it's worth giving the model — which can use real context — a chance instead
    /// of silently leaving a possible unresolved repair in the final text. Excluded from firing
    /// on a longer list for the same reason `resolveFirst` excludes one via `isPartOfLongerList`.
    static func mightHaveUnresolvedRepair(_ ruled: String) -> Bool {
        let pattern = "\\b([A-Za-z][A-Za-z']*)-?,\\s+([A-Za-z][A-Za-z']*)\\b"
        for match in Regex.matches(ruled, pattern) {
            guard let first = match.string(at: 1, in: ruled), let second = match.string(at: 2, in: ruled),
                  let wholeRange = Range(match.range(at: 0), in: ruled)
            else { continue }
            guard !isPartOfLongerList(ruled, around: wholeRange) else { continue }
            let a = WordDiff.key(first)
            let b = WordDiff.key(second)
            guard !a.isEmpty, !b.isEmpty, a != b else { continue }
            // Already resolved (or confidently rejected as unrelated) by `isCloseRepairPair`;
            // only a shape it didn't already call confident is a "might be" case.
            guard !isCloseRepairPair(a, b) else { continue }
            let sharedPrefix = commonPrefixLength(a, b)
            if sharedPrefix >= 2, min(a.count, b.count) - sharedPrefix >= 1, max(a.count, b.count) >= 4 {
                return true
            }
        }
        return false
    }
}
