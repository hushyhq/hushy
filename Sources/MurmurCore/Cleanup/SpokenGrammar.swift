import Foundation

/// Detects spoken-grammar problems that the deterministic rules never resolve on their own, so
/// `ModelHints.worthAsking` can ask the on-device model for a case like:
///
///   "Voice signatures also I think should be in free because if we are stating labelling as
///   free shouldn't, voice signature should automatically be free"
///
/// None of `SmartCleaner`'s existing hints fire here — there is no correction cue ("no",
/// "actually"), no enumeration, no stutter fragment and no near-duplicate self-repair. The
/// problem is ordinary disfluent speech: a dangling negated modal before a comma ("shouldn't,"),
/// a restart that repeats the subject/modal after it ("voice signature should …"), a hedge
/// ("I think") sitting mid-clause instead of at the front, and a long run-on with no sentence
/// break. Rules deliberately never touch grammar (`TextCleaner` only removes fillers/commands and
/// resolves explicit corrections), so leaving this to `worthAsking` returning `false` means the
/// text goes out exactly as spoken — this type exists to change that.
///
/// Deliberately conservative, matching the style of `WordFragmentStutter.mightHaveUnresolvedFragment`
/// and `SelfRepair.mightHaveUnresolvedRepair`: each check requires a specific, low-false-positive
/// shape, not a general "this sentence looks awkward" heuristic. A false positive here only costs
/// one extra (budgeted, fallback-safe) model call; a false negative means a garbled sentence goes
/// out untouched, which is the bug being fixed — so checks lean toward catching real disfluency
/// shapes without firing on ordinary, already-grammatical or casual speech.
public enum SpokenGrammar {
    /// Lowercased comparison key with all punctuation (including apostrophes) stripped, so
    /// "wouldn't", "wouldn\u{2019}t" and "wouldnt" all normalize the same way — matching the
    /// apostrophe-free spellings in `modals` below.
    private static func key(_ token: String) -> String {
        token.lowercased().filter(\.isLetter)
    }

    /// Modals/auxiliaries whose repetition right after a comma signals a restart: the speaker
    /// began a clause with one of these, trailed off (often on a negated form, "shouldn't,"),
    /// and immediately started a new clause with the same (or the positive/negative counterpart
    /// of the same) modal — "…shouldn't, voice signature should automatically be free".
    private static let modals: Set<String> = [
        "should", "shouldnt", "would", "wouldnt", "could", "couldnt", "can", "cant", "will",
        "wont", "must", "mustnt", "might", "may", "do", "dont", "does", "doesnt", "did", "didnt",
        "is", "isnt", "are", "arent", "was", "wasnt", "were", "werent",
    ]

    /// A negated modal/auxiliary immediately followed by a comma, then — after at most a few
    /// words — the same modal's stem again ("shouldn't, voice signature should…"). This is the
    /// exact shape in the product owner's example: the speaker abandons a clause right after a
    /// negated modal, leaving it dangling before the comma, and restarts with the positive form.
    static func hasDanglingNegatedModalRestart(_ text: String) -> Bool {
        // Captures the negated modal right before a comma, then the next few words as one blob
        // (rather than trying to have the regex itself pick out which single following word is
        // the restart) — a non-greedy `{0,4}?` repetition group can't be relied on to prefer a
        // modal match over a shorter one that merely satisfies the overall pattern first, so the
        // whole window is captured and searched word-by-word in Swift instead.
        let pattern = "\\b([A-Za-z]+n['\u{2019}]?t)\\s*,\\s+((?:[A-Za-z]+\\s+){0,4}[A-Za-z]+)"
        for match in Regex.matches(text, pattern) {
            guard let negated = match.string(at: 1, in: text), let window = match.string(at: 2, in: text)
            else { continue }
            // `key` strips punctuation including apostrophes ("wouldn't" -> "wouldnt"), matching
            // the apostrophe-free spellings in `modals` above.
            let negatedKey = key(negated)
            guard modals.contains(negatedKey) else { continue }
            let negatedStem = negatedKey.hasSuffix("nt") ? String(negatedKey.dropLast(2)) : negatedKey
            let windowWords = window.split(whereSeparator: \.isWhitespace).map { key(String($0)) }
            let hasRestart = windowWords.contains { restartKey in
                guard modals.contains(restartKey) else { return false }
                // The restart must be the positive counterpart or bare stem of the negated modal,
                // not an unrelated modal that happens to follow ("shouldn't, can you…" is a
                // genuine two-clause sentence, not a restart).
                return negatedStem == restartKey || negatedStem.hasPrefix(restartKey) || restartKey.hasPrefix(negatedStem)
            }
            if hasRestart { return true }
        }
        return false
    }

    /// The hedge "I think" (or "I guess"/"I feel like") sitting mid-clause rather than at the
    /// front of the sentence — "Voice signatures also I think should be free" reads naturally as
    /// "I think voice signatures should also be free". Only fires when the hedge is preceded by
    /// at least two words that are themselves not a hedge/subject opener, so a sentence that
    /// already starts with the hedge ("I think we should…") never matches.
    static func hasMidClauseHedge(_ text: String) -> Bool {
        // Each word is `\w+` with an optional apostrophe *suffix* that must start with the
        // apostrophe. The earlier `\w+['’]?\w*` let every word split ambiguously between the
        // two `\w` runs, and `{2,}` multiplied those splits across the sentence: a long run-on
        // with no hedge backtracked exponentially (a `murmur-eval grammar` run sat here for 14 h).
        let pattern = "^\\s*(?:\\w+(?:['\u{2019}]\\w*)?\\s+){2,}(?:i think|i guess|i feel like)\\b"
        for sentence in Sentences.split(text) {
            if Regex.firstMatch(sentence, pattern) != nil { return true }
        }
        return false
    }

    /// A repeated subject/topic restart: the same leading noun phrase (1-3 words) appears twice
    /// within a short span, the second time starting a new clause — "voice signature... voice
    /// signature should" — without an explicit correction cue (that shape is already handled by
    /// `ModelHints.hasCorrectionCue`/`SelfCorrection`). Conservative: requires the repeated phrase
    /// to be at least 2 words (a single repeated short word is usually a stutter, already handled
    /// by `WordFragmentStutter`/rules-level stutter removal) and to be separated by a comma.
    static func hasRepeatedSubjectRestart(_ text: String) -> Bool {
        let pattern = "\\b((?:[A-Za-z]+\\s+){1,2}[A-Za-z]+)\\s*,\\s+\\1\\b"
        return Regex.firstMatch(text.lowercased(), pattern) != nil
    }

    /// A long run-on with no internal sentence punctuation at all — the rules-cleaned draft is at
    /// least `longRunOnWordThreshold` words and contains no `.`/`!`/`?` anywhere (not even at the
    /// very end), meaning `TerminalPunctuation`/`Punctuation` never found a natural boundary to
    /// insert one. This is the fallback net for spoken-grammar problems that don't match either
    /// specific shape above: a genuinely long, unbroken ramble is itself worth a model pass to
    /// split into sentences, per the task's "very long unpunctuated run-ons" candidate.
    static let longRunOnWordThreshold = 28

    static func isLongUnpunctuatedRunOn(_ text: String) -> Bool {
        guard TextStats.wordCount(text) >= longRunOnWordThreshold else { return false }
        return !text.contains(where: { $0 == "." || $0 == "!" || $0 == "?" })
    }

    /// "or is it"/"or is that"/"or is this" mid-sentence: a spoken restart that rephrases the
    /// first half of an alternative question without a comma or an explicit correction cue —
    /// "It is like 3-second dictation or is it like 40-second dictation" is really one thought
    /// ("is it a 3-second dictation or a 40-second dictation") restated awkwardly mid-stream.
    /// `Fillers`/`SelfCorrection` never catch this (no cue word, no comma), so without this the
    /// draft goes to the model only if some other hint fires.
    static func hasMidSentenceRestartQuestion(_ text: String) -> Bool {
        Regex.firstMatch(text, "\\bor\\s+is\\s+(?:it|that|this)\\b") != nil
    }

    /// Bare filler "like" used as a hedge rather than a comparison — sitting directly before a
    /// number/quantity phrase ("like 3-second", "like five minutes") with no comma around it.
    /// `Fillers.remove` only strips "like" when it is comma-set-off on both sides, so a bare
    /// mid-clause "like" (extremely common in real speech, and exactly what the product owner's
    /// real dictations showed) otherwise never triggers a model call at all under `.clean`.
    /// Deliberately narrow to "like" immediately before a number or a small set of quantity words,
    /// rather than any "like" at all, so a genuine comparison ("tastes like chicken", "acts like
    /// a manager") is never treated as a disfluency signal.
    static func hasBareFillerLike(_ text: String) -> Bool {
        Regex.firstMatch(text, "\\blike\\s+(?:\\d|a\\s+few|a\\s+couple|five|ten|fifteen|twenty|thirty)\\b") != nil
    }

    /// An exact phrase repeat of 2+ words, immediately adjacent (optionally comma-separated) —
    /// "it's a it's it's a", "in the w in the". This is a *detection* signal only: whether the
    /// repeat is a disfluency (drop it) or a legitimate doubled phrase ("very very", "that that",
    /// "bye bye", "had had") is a judgment call left to the model, which has real sentence
    /// context — see the module doc and `.claude/DECISIONS.md` for why rules only detect this
    /// shape rather than collapsing it outright. Requires the repeated phrase to have 2+ words
    /// specifically because a single repeated word ("very very", "no no") is exactly the
    /// ambiguous case the product owner asked to leave to the model; a 2+ word phrase repeating
    /// verbatim ("it's a" twice) is essentially never an intentional doubling in ordinary speech.
    static func hasMultiWordPhraseRepeat(_ text: String) -> Bool {
        // Allows a short gap (0-3 stray words) between the two occurrences of the phrase, not
        // just strict adjacency: a real ASR restart often interleaves a false start between the
        // repeats ("it's a it's it's a" is "it's a" ... "it's" ... "it's a" — the phrase recurs
        // after one extra word, not immediately). This is detection only (triggers a model call),
        // so a slightly wider net than the strict-adjacency fallback collapse below is fine —
        // the negatives above confirm it doesn't fire on ordinary sentences or the legitimate
        // single-word doublings ("very very", "that that", "bye bye", "had had").
        let pattern = "\\b((?:[A-Za-z']+\\s+){1,4}[A-Za-z']+)\\b(?:,?\\s+(?:[A-Za-z']+\\s*){0,3})?\\1\\b"
        return Regex.firstMatch(text.lowercased(), pattern) != nil
    }

    /// A single-letter (or two-letter, non-word) orphan fragment immediately followed by a short
    /// word it doesn't prefix meaningfully, itself followed by a repeat of an earlier short
    /// phrase — "in the w in the above sentence": "w" is an aborted word-start with nothing
    /// after it to complete it (unlike `WordFragmentStutter`, which matches a fragment that IS a
    /// prefix of the next word), sitting inside a repeated "in the … in the" span. Detection
    /// only, same reasoning as `hasMultiWordPhraseRepeat`.
    static func hasOrphanFragmentInRepeat(_ text: String) -> Bool {
        // A short (1-2 letter) lowercase token that is NOT a real standalone word (reusing
        // `WordFragmentStutter`'s exclusion list) and does NOT prefix the following word (if it
        // did, that's `WordFragmentStutter`'s own territory), sitting between two occurrences of
        // the same short lead-in phrase.
        let pattern = "\\b((?:[A-Za-z]+\\s+){1,2})([a-z]{1,2})\\s+\\1\\b"
        for match in Regex.matches(text.lowercased(), pattern) {
            guard let leadIn = match.string(at: 1, in: text.lowercased()),
                  let orphan = match.string(at: 2, in: text.lowercased())
            else { continue }
            guard !WordFragmentStutter.standaloneWords.contains(orphan) else { continue }
            _ = leadIn
            return true
        }
        return false
    }

    // MARK: - Hedge fillers and missing punctuation

    /// Words that are filler in nearly every dictation use ("basically", "literally"), "you know"
    /// used as a tag rather than as "you know <what/how/that…>", and a bare "like" in a position
    /// where it can't be the verb or a comparison — after a modal or "to" and before a word that
    /// isn't an object ("we could like hide it", "to like fix the login"), or after a noun and
    /// before a verb-looking word. Detection only (the model decides), so it may over-fire a little.
    static func hasHedgeFiller(_ text: String) -> Bool {
        let lower = text.lowercased()
        if Regex.firstMatch(lower, "\\b(?:basically|literally)\\b") != nil { return true }
        if Regex.firstMatch(lower, "\\byou know\\b(?!\\s+(?:what|how|that|why|where|who|if|the|it|this|him|her|them|me|about|when|whether|a|an|my|your|our|their)\\b)") != nil {
            return true
        }
        let keepBefore = "(?:i|you|we|they|would|i'd|you'd|we'd|they'd|don't|doesn't|didn't|do|does|did|look|looks|looked|seem|seems|seemed|sound|sounds|sounded|feel|feels|felt|taste|tastes|smell|smells|act|acts|things|stuff|something|anything|just|more|much|exactly|not|really|also|i'll|we'll|you'll|people)"
        let objectAfter = "(?:that|this|these|those|it|them|him|her|me|us|you|a|an|the|to|what|how|when|i|we|they|he|she|my|your|our|their|his|its)"
        let pattern = "(?<!\\b\(keepBefore)\\s)\\blike\\s+(?!\(objectAfter)\\b)[a-z]"
        return Regex.firstMatch(lower, pattern) != nil
    }

    /// At least `unpunctuatedWordThreshold` words with no sentence punctuation or comma anywhere
    /// but (possibly) a single terminal mark — the shape of a transcript from an engine that
    /// didn't punctuate. Parakeet usually punctuates, so this rarely fires on its output.
    static let unpunctuatedWordThreshold = 14

    public static func lacksSentencePunctuation(_ raw: String) -> Bool {
        var body = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        while let last = body.last, ".!?".contains(last) { body.removeLast() }
        guard TextStats.wordCount(body) >= unpunctuatedWordThreshold else { return false }
        return !body.contains(where: { ".!?,;:".contains($0) })
    }

    // MARK: - Discourse-marker overuse

    /// Discourse markers that carry meaning only sometimes: "actually" is contrastive in "I
    /// actually disagree" but empty filler in "so actually we should actually probably actually
    /// do X". Deciding which is which needs real sentence understanding, so rules never delete
    /// these on their own (see `hasRepeatedDiscourseMarker`'s fallback, which only ever collapses
    /// an exact repeat of the SAME marker) — this list exists only to detect overuse and trigger
    /// the model, which decides case by case under `SmartCleaner.instructions`/`polishedInstructions`.
    static let discourseMarkers: Set<String> = [
        "actually", "basically", "literally", "just", "really", "so", "youknow", "imean",
        "kindof", "sortof", "like", "right",
    ]

    /// The markers too ordinary as plain words ("so", "just", "really", "right") to say anything when they appear
    /// once; they count only when repeated (`hasRepeatedDiscourseMarker`).
    private static let ordinaryWords: Set<String> = ["so", "just", "really", "right"]

    /// True when the text still holds a marker the cleanup instructions ask the model to weigh (rule 4: the same
    /// `discourseMarkers` list, "kind of" and "sort of" and "you know" and "I mean" included), other than the four
    /// ordinary words. Detection only; the model decides whether it carries meaning. One vocabulary, not a copy.
    static func hasFillerMarker(_ text: String) -> Bool {
        let keys = text.split(whereSeparator: \.isWhitespace).map { markerKey(String($0)) }.filter { !$0.isEmpty }
        for (index, key) in keys.enumerated() {
            if discourseMarkers.contains(key), !ordinaryWords.contains(key) { return true }
            if index + 1 < keys.count {
                let pair = key + keys[index + 1]
                if discourseMarkers.contains(pair) { return true }
            }
        }
        return false
    }

    /// Normalizes a token the same way `discourseMarkers` is spelled: lowercased, letters only
    /// (so "actually," "Actually" and "actually" all match, and multi-word markers can be
    /// compared against a joined key).
    private static func markerKey(_ token: String) -> String {
        token.lowercased().filter(\.isLetter)
    }

    /// True when the same discourse marker appears 2 or more times within one sentence — "So
    /// actually we should actually probably actually do X" has "actually" three times in one
    /// sentence. This alone doesn't prove every instance is meaningless (rare, but a marker can
    /// legitimately recur), so it is only ever used as a *trigger* for the model here; the
    /// separate, much narrower `collapseRepeatedDiscourseMarkers` fallback below is the only
    /// thing that ever deletes one deterministically, and only when the count is unambiguous.
    static func hasRepeatedDiscourseMarker(_ text: String) -> Bool {
        for sentence in Sentences.split(text) {
            let words = sentence.split(whereSeparator: \.isWhitespace).map(String.init)
            var counts: [String: Int] = [:]
            for word in words {
                let key = markerKey(word)
                guard discourseMarkers.contains(key) else { continue }
                counts[key, default: 0] += 1
                if counts[key]! >= 2 { return true }
            }
        }
        return false
    }

    /// Deterministic fallback (unambiguous only): when the SAME discourse marker occurs 3 or
    /// more times in one sentence, keeps only the first occurrence and drops the rest — "so
    /// actually we should actually probably actually do X" -> "so actually we should probably do
    /// X". Requires 3+ (not 2+) specifically because two occurrences of a marker in one sentence
    /// is common in ordinary speech ("Actually, I actually like it") and not confidently a
    /// disfluency; 3+ repeats of the identical marker in one sentence is a much stronger signal
    /// nothing but the model should second-guess, and even then this only fires as the *fallback*
    /// when the model is unavailable/timed out/rejected — the model is always asked first (via
    /// `hasRepeatedDiscourseMarker`) and decides case by case which instances carry meaning.
    static func collapseRepeatedDiscourseMarkers(_ text: String) -> String {
        // Only a sentence that lost a marker is rewritten, in place. Re-joining every sentence with
        // single spaces used to split ".bashrc", "package.json" and "2.3.1" at their dots.
        var result = text
        for sentence in Sentences.split(text) {
            var counts: [String: Int] = [:]
            let words = sentence.split(whereSeparator: \.isWhitespace).map(String.init)
            var kept: [String] = []
            for word in words {
                let key = markerKey(word)
                if discourseMarkers.contains(key), !key.isEmpty {
                    counts[key, default: 0] += 1
                    if counts[key]! >= 3 { continue } // drop the 3rd+ occurrence
                }
                kept.append(word)
            }
            guard kept.count != words.count, let range = result.range(of: sentence) else { continue }
            result.replaceSubrange(range, with: kept.joined(separator: " "))
        }
        return result
    }

    /// True when the rule-cleaned draft shows leftover *disfluency* — a restart, phrase repeat,
    /// orphan fragment or bare filler the deterministic rules couldn't safely resolve on their
    /// own — as opposed to a pure grammar problem (agreement, a misplaced hedge, an unbroken
    /// run-on) that doesn't involve any disfluency residue. This is the trigger used at `.clean`
    /// (hybrid): "Cleaned up" only removes disfluency (see `SmartCleaner.instructions`), so it
    /// only asks the model when disfluency is actually present — asking it to fix a pure grammar
    /// issue it isn't instructed to touch would just spend a model call for nothing. There is no
    /// word-count floor here: a short 3-second dictation gets exactly the same scrutiny as a long
    /// one, per the "length must not matter" requirement.
    public static func mightHaveDisfluencyResidue(_ text: String) -> Bool {
        hasHedgeFiller(text)
            || hasDanglingNegatedModalRestart(text)
            || hasRepeatedSubjectRestart(text)
            || hasMultiWordPhraseRepeat(text)
            || hasOrphanFragmentInRepeat(text)
            || hasMidSentenceRestartQuestion(text)
            || hasBareFillerLike(text)
            || hasRepeatedDiscourseMarker(text)
    }

    /// True when the rule-cleaned draft shows a spoken-grammar OR disfluency problem the
    /// deterministic rules never fully resolve on their own. This is the wider trigger used at
    /// `.polished` (always asked, so the trigger only affects which extra examples/latency
    /// bookkeeping apply, not whether the model runs) and by callers that want the full picture —
    /// it's `mightHaveDisfluencyResidue` plus the pure-grammar shapes (a misplaced hedge, an
    /// unbroken run-on) that only `.polished`'s grammar-repair instructions are allowed to fix.
    public static func mightNeedRepair(_ text: String) -> Bool {
        mightHaveDisfluencyResidue(text)
            || hasMidClauseHedge(text)
            || isLongUnpunctuatedRunOn(text)
    }

    // MARK: - Deterministic fallback (unambiguous patterns only)
    //
    // Used only when the model is unavailable, times out, or its answer is rejected by the
    // guards — i.e. exactly the cases `SmartCleaner.refine` already falls back to the rules'
    // draft for. Deliberately narrower than the *detection* triggers above: only an exact,
    // unambiguous phrase repeat (2+ words, or the orphan-fragment shape) is collapsed here,
    // never a single repeated word ("very very", "that that", "bye bye"), which stays exactly as
    // spoken when there is no model available to make the judgment call.

    /// Collapses an exact 2+ word phrase repeat to one copy — the unambiguous half of
    /// `hasMultiWordPhraseRepeat`'s detection shape. "it's a it's it's a three second dictation"
    /// -> "it's a three second dictation".
    static func collapseUnambiguousPhraseRepeat(_ text: String) -> String {
        let pattern = "\\b((?:[A-Za-z']+\\s+){1,4}[A-Za-z']+)\\b(?:,?\\s+\\1\\b)+"
        return Regex.replace(text, pattern) { whole, groups in
            guard groups.count > 1 else { return whole }
            let phrase = groups[1]
            let after = BoundaryRepeatGuard.wordAfterMatch(whole, in: text)
            return BoundaryRepeatGuard.preservesPhraseRepeat(phrase, wordAfter: after) ? whole : phrase
        }
    }

    private static let codeSeparators: Set<String> = ["dot", "slash", "arrow", "underscore", "colon"]

    /// Drops an orphan single/double-letter fragment sitting inside a repeated short lead-in —
    /// the unambiguous half of `hasOrphanFragmentInRepeat`'s detection shape. "in the w in the
    /// above sentence" -> "in the above sentence".
    ///
    /// In a code line the lead-in may end in a separator word: "x dot y dot z" is the member chain
    /// `x.y.z`, and "src slash a slash b" a path, not a restart with a stray letter. Evidence needed: a
    /// code context and a lead-in whose last word is one of the closed separator words below.
    static func dropOrphanFragmentInRepeat(_ text: String, codeContext: Bool = false) -> String {
        let pattern = "\\b((?:[A-Za-z]+\\s+){1,2})([a-z]{1,2})\\s+\\1\\b"
        return Regex.replace(text, pattern) { whole, groups in
            guard groups.count > 2 else { return whole }
            let orphan = groups[2].lowercased()
            guard !WordFragmentStutter.standaloneWords.contains(orphan) else { return whole }
            // "tar dash x dash f": the repeated lead-in is the flag word, and the "orphan" is a flag.
            let leadIn = groups[1].trimmingCharacters(in: .whitespaces).lowercased().split(separator: " ").last
            guard leadIn != "dash" else { return whole }
            if codeContext, let leadIn, codeSeparators.contains(String(leadIn)) { return whole }
            return groups[1]
        }
    }

    /// Applies both unambiguous fallback collapses, phrase-repeat first (an orphan fragment is
    /// often nested inside a repeated lead-in, so collapsing the outer repeat first can already
    /// resolve it; running the fragment pass afterward catches what's left either way).
    public static func collapseUnambiguousDisfluency(_ text: String) -> String {
        collapseRepeatedDiscourseMarkers(dropOrphanFragmentInRepeat(collapseUnambiguousPhraseRepeat(text)))
    }
}
