import Foundation

/// Removes discourse-marker "like" — the quotative/hedge filler ("Like, do we have a
/// threshold?", "…stopped after the above sentence like automatically") — while never touching
/// its verb, preposition, or comparison uses ("I like it", "looks like rain", "something like
/// that", "things like that", "like I said").
///
/// Deliberately narrow: only two positions are touched, both chosen so the surrounding syntax
/// makes "like" unambiguously a filler rather than a content word.
enum DiscourseMarkers {
    /// Adverbs whose -ly suffix, immediately after "like", makes "like" a hedge rather than a
    /// comparison ("like automatically", "like literally") — a real comparison needs a noun
    /// phrase after "like" ("like a robot"), not an adverb.
    private static let adverbException: Set<String> = ["only", "early", "family", "friendly", "likely", "ugly", "holy"]

    static func remove(_ text: String) -> String {
        var out = text
        out = removeSentenceInitial(out)
        out = removeAfterOpeningMarkers(out)
        out = removeBeforeAdverb(out)
        out = removeBeforeQuantity(out)
        return out
    }

    /// "like" right after a sentence's opening discourse markers ("so like the build is green",
    /// "yeah so like we should…", "okay like I said" excluded) is the hedge. Only before a clause
    /// start (a determiner, pronoun or wh-word), never "like that/this" ("yeah, like that one").
    private static func removeAfterOpeningMarkers(_ text: String) -> String {
        let openers = "(?:um|uh|yeah|okay|ok|so|well|and|but|oh)"
        let followers = "(?:the|a|an|i|you|we|they|it|he|she|there|what|how|when|why|if|my|our|your|their)"
        let pattern = "(?:^|(?<=[.!?]\\s)|(?<=\\n))((?:\(openers),?\\s+){1,3})like,?\\s+(?!i\\s+said\\b)(?=\(followers)\\b)"
        return Regex.replace(text, pattern, with: "$1")
    }

    /// Hedge "like" directly before a number — "spent like two hours", "files over like 2
    /// gigs", "is it like more than two seconds", "like five or six seconds" — is removed. Vaguer
    /// quantities ("like a few minutes", "like a couple") are left to the model: in a casual
    /// message ("I'm gonna be like a few minutes late") the speaker's register is kept. The
    /// verb "like" is kept: after a subject or auxiliary ("I'd like two coffees", "we like 3 of
    /// them", "would like 5"), after "to"/"don't"/"really" ("don't like two of them"), and the
    /// "such as" sense after "things/stuff/numbers" ("numbers like 5 and 7") or a comparison verb
    /// ("looks like two people").
    private static func removeBeforeQuantity(_ text: String) -> String {
        let keepAfter = "(?:i|you|we|they|people|would|i'd|you'd|we'd|they'd|he'd|she'd|to|do|don't|does|doesn't|did|didn't|really|also|just|things|stuff|something|anything|numbers|values|look|looks|looked|seem|seems|seemed|sound|sounds|sounded|feel|feels|felt|taste|tastes|smell|smells|act|acts|more|much)"
        let numberWords = "(?:one|two|three|four|five|six|seven|eight|nine|ten|eleven|twelve|fifteen|twenty|thirty|forty|fifty|sixty|ninety|a\\s+hundred|a\\s+thousand|a\\s+dozen|more\\s+than|less\\s+than|over|under|about|around)"
        let pattern = "(?<!\\b\(keepAfter)\\s)\\blike,?\\s+(?=(?:\\d|\(numberWords)\\b))"
        return Regex.replace(text, pattern, with: "")
    }

    /// Sentence-initial "Like," or "Like " immediately followed by an auxiliary/pronoun/wh-word
    /// ("Like do we have a threshold", "Like, is that right?") is the hedge/quotative opener.
    /// "Like I said" is excluded — it is a fixed phrase, not a hedge, and must survive verbatim.
    private static func removeSentenceInitial(_ text: String) -> String {
        let followers = "(?:i|you|we|they|he|she|it|do|does|did|is|are|was|were|can|could|will|would|should|what|why|how|when|where|who)\\b"
        // Negative lookaheads keep fixed phrases intact: "Like I said" (an idiom, not a hedge)
        // and "Like it or not" (the follower "it" would otherwise match the generic pronoun
        // case, but this is a set phrase where "like" is load-bearing). Case-insensitive
        // throughout: this runs before final capitalization, so a sentence-initial "like" may
        // not yet be capitalized.
        let pattern = "(?:^|(?<=[.!?]\\s)|(?<=\\n))like,?\\s+(?!i\\s+said\\b)(?!it\\s+or\\s+not\\b)(?=\(followers)\\b)"
        return Regex.replace(text, pattern, with: "")
    }

    /// "like" immediately before an adverb ending in "-ly" (excluding real adjectives/nouns that
    /// happen to end in -ly, e.g. "family", "friendly") or before "literally"/"totally"/"basically",
    /// when it follows the end of a noun phrase (a word, not a verb like "looks"/"seems"/"sounds"
    /// immediately before "like" — those are genuine comparisons: "looks like literally nothing
    /// changed" must keep "like").
    private static func removeBeforeAdverb(_ text: String) -> String {
        let comparisonVerbs = "(?:look|looks|looked|seem|seems|seemed|sound|sounds|sounded|feel|feels|felt|act|acts|acted|taste|tastes|tasted|smell|smells|smelled)"
        let adverb = "(?:literally|totally|basically|honestly|actually|seriously|essentially|technically|[a-z]+ly)"
        let pattern = "(?<!\(comparisonVerbs) )like\\s+(\(adverb))\\b"
        return Regex.replace(text, pattern) { whole, groups in
            let adverbWord = groups.count > 1 ? groups[1] : ""
            let normalized = adverbWord.lowercased()
            if adverbException.contains(normalized) { return whole }
            return adverbWord
        }
    }
}
