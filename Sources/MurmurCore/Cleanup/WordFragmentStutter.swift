import Foundation

/// Removes a stuttered word-start fragment the ASR writes as its own short token immediately
/// before the full word it was reaching for: "to actually c calculate the minutes" → "to
/// actually calculate the minutes", "th the report" → "the report", "wh what time" → "what
/// time", "st start" → "start".
///
/// Deliberately narrow, mirroring the standalone-word guard other rules in this file use:
/// - The fragment must be 1-3 lowercase letters. Real short words ("a", "an", "to", "in") are
///   never mistaken for a stutter because of the standalone-word exclusion list below, not
///   because of length alone (some real short words are 2-3 letters too).
/// - The fragment must be an exact prefix of the next word, case-insensitively, and shorter
///   than it — "a apple" is a repeated article (or a disfluency rules elsewhere already leave
///   alone), never a fragment of "apple".
/// - A capitalized fragment ("C" in "C programming", an initial like "J. Smith") is never
///   touched — capitalization signals a real token, not a stutter, and this rule only ever
///   matches an all-lowercase fragment.
enum WordFragmentStutter {
    /// Short real words that must never be treated as a stutter fragment of a following word
    /// they happen to prefix ("a apple", "in inside", "so sorry", "or organize"). Deliberately
    /// generous — anything on this list is a word Hushy's dictation goldens (and ordinary
    /// English) can plausibly precede another word with, spoken deliberately rather than cut
    /// off mid-word.
    static let standaloneWords: Set<String> = [
        "a", "i", "an", "at", "to", "in", "on", "is", "it", "as", "so", "do", "go", "no", "we",
        "he", "me", "my", "by", "or", "of", "up", "us", "am", "be", "if", "ok",
    ]

    static func remove(_ text: String) -> String {
        // Fragment: an explicit hyphenated word-cut ("st-") of 1-3 letters — an unambiguous ASR
        // marker for a self-interrupted word, so length alone doesn't need to carry the whole
        // signal — OR an unhyphenated bare fragment of only 1-2 letters, where a 3+ letter bare
        // token ("cat categories") is far more likely to be a real short word spoken
        // deliberately than a stutter, and is left to the explicit standalone-word list plus
        // this length cap rather than guessed at.
        // Neither pattern may start right after an apostrophe: `\b` alone treats the "s" in
        // "Let's" as its own word, and "s ship" (from "Let's ship") would otherwise read as a
        // fragment of "ship" — a contraction's tail is never a stutter fragment.
        //
        // The full word is matched in a lookahead, not consumed: consuming it made "we m make"
        // match as fragment "we" + word "m", so the real fragment "m" never got its own turn.
        let hyphenated = "(?<!['’])\\b([a-zA-Z]{1,3})-\\s+(?=([a-zA-Z]+)\\b)"
        // A letter right after "dash" is a spoken command-line flag ("dash r requirements"), never a stutter.
        let bare = "(?<!['’])(?<!\\bdash )\\b([a-zA-Z]{1,2})\\s+(?=([a-zA-Z]+)\\b)"
        var out = Regex.replace(text, hyphenated) { whole, groups in resolve(whole, groups, explicitCut: true) }
        // A repeated 1-2 letter onset ("c c calculate", "th th the") goes as a whole run, rather
        // than letting the single-fragment pass remove just its last copy and leave "th the".
        // Longer repeats are not touched here: "the the theory" and "for for forty" repeat a real
        // word, and deleting is the risky direction; whole-word collapse and the model handle
        // those. Real short words ("in in inside") are kept for that collapse too.
        out = Regex.replace(out, "(?<!['’])(?<!\\bdash )\\b([a-z]{1,2})(?:\\s+\\1)+\\s+(?=\\1[a-z]+\\b)") { whole, groups in
            guard groups.count > 1, !standaloneWords.contains(groups[1].lowercased()),
                  groups[1] == groups[1].lowercased() else { return whole }
            return ""
        }
        // A longer explicit cut ("Wednes- Wednesday", "configur- configuration") is unambiguous
        // too when the next word completes it.
        out = Regex.replace(out, "(?<!['’])\\b([a-zA-Z]{4,})-\\s+(?=([a-zA-Z]+)\\b)") { whole, groups in
            guard groups.count > 2, groups[2].count > groups[1].count,
                  groups[2].lowercased().hasPrefix(groups[1].lowercased()) else { return whole }
            return ""
        }
        out = Regex.replace(out, bare) { whole, groups in resolve(whole, groups, explicitCut: false) }
        return out
    }

    /// Returns "" (drop the fragment and its trailing space) for a stutter, else `whole`.
    private static func resolve(_ whole: String, _ groups: [String], explicitCut: Bool) -> String {
        guard groups.count > 2 else { return whole }
        let fragment = groups[1]
        let fullWord = groups[2]
        // A lone letter with no cut marker may be a label for the word before it.
        guard explicitCut || fragment.count > 1 else { return whole }
        // Capitalized: an ALL-CAPS token ("PR process", "IT team") is an acronym, never a
        // stutter. A Titlecase 1–2 letter token that begins the next word ("the Gr
        // green button") is how Parakeet writes a cut-off word-start, so it is dropped — unless it
        // is a real short word ("In", "My") or the next word is capitalized too (a name).
        if fragment != fragment.lowercased() {
            let isTitlecase = fragment.first!.isUppercase && fragment.dropFirst() == fragment.dropFirst().lowercased()
            // "Ed Edwards", "Jo Jones": a Titlecase word before a Titlecase word may be a name.
            guard isTitlecase, fragment.count >= 2, fullWord.first?.isLowercase == true else { return whole }
        }
        guard !standaloneWords.contains(fragment.lowercased()) else { return whole }
        guard fullWord.count > fragment.count else { return whole }
        guard fullWord.lowercased().hasPrefix(fragment.lowercased()) else { return whole }
        return ""
    }

    /// True when `ruled` (the already rule-cleaned output) still contains a fragment shape this
    /// rule is conservative about resolving on its own: a 1 or 3-4 letter bare (non-hyphenated) word
    /// immediately followed by a longer word it prefixes, and not on the standalone-word list.
    /// `remove(_:)` only ever acts on 1-2 letter bare fragments (or an explicitly hyphenated cut
    /// of up to 3), precisely so a real short word like "cat" in "cat categories" is never
    /// silently eaten — but that same caution means a genuine 3-4 letter fragment ("cal
    /// calculate", "min minutes") survives cleanup untouched. Used only as a hint for
    /// `ModelHints.worthAsking`: when this shape is still present after rules ran, it's worth
    /// giving the model — which has actual language understanding — a chance to decide whether
    /// it's really a stutter, rather than silently leaving a possible fragment in the final text.
    static func mightHaveUnresolvedFragment(_ ruled: String) -> Bool {
        let pattern = "(?<!['’])\\b([a-z]{1,4})\\s+([a-zA-Z]+)\\b"
        for match in Regex.matches(ruled, pattern) {
            guard let fragment = match.string(at: 1, in: ruled), let fullWord = match.string(at: 2, in: ruled)
            else { continue }
            guard !standaloneWords.contains(fragment) else { continue }
            guard fullWord.count > fragment.count, fullWord.lowercased().hasPrefix(fragment.lowercased())
            else { continue }
            return true
        }
        return false
    }
}
