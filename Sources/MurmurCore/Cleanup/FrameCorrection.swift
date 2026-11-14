import Foundation

/// Frame-aware self-corrections: the speaker keeps the sentence's frame and corrects one slot of
/// it, and the correction refers back to a word the frame holds.
///
/// - Retarget (`retarget`): "Reach out to Raj, wait, scratch that, just text him the address" →
///   "Text Raj the address". The new verb replaces the old one; the pronoun is the old object.
/// - Head noun (`headNoun`): "Download the online maps, no, the offline ones" → "Download the
///   offline maps". "ones" stands for the noun the correction keeps.
/// - Keep the old value (`keepValue`): "Move the standup to 11, actually leave it at 10, but make
///   it shorter" → "Leave the standup at 10, but make it shorter". "it" is the thing being moved.
///
/// Before these rules, `VoiceCommands.applyScratchThat` and `SelfCorrection`'s anchor swap
/// resolved the first two shapes by deleting everything back to the anchor, which dropped the
/// name or noun the pronoun refers to ("Just text him the address", "Download the offline ones").
/// The model only sees the rules draft, so once the word was gone nothing could restore it
/// (docs/product/FINETUNE.md §3.9: 22 of 295 retarget and 36 of 212 head-noun sentences).
///
/// Every rule needs structural evidence (a verb + object before the cue and "just <verb>
/// him/her/them" after it; "one(s)" or the repeated noun after a determiner; "keep/leave it
/// <prep>") and declines otherwise, leaving the cue for `SelfCorrection` and the model.
enum FrameCorrection {
    /// Head-noun and keep-the-old-value shapes. Runs with the other English-only correction
    /// stages, before `FragmentRepair`/`SelfCorrection`.
    static func apply(_ text: String) -> String {
        keepValue(headNoun(text))
    }

    // MARK: - Shared word classes

    /// Correction cues that are safe without a comma before them.
    static let multiwordCue = "(?:oh,? actually,? never ?mind|actually,? never ?mind|never ?mind|wait,? scratch that|"
        + "scratch that|actually,? no|no,? actually|no,? wait|wait,? no|sorry,? no|no,? sorry|i mean|i meant)"
    /// Single-word cues: only when set off by a comma ("Email Raj, no, just call him"); a bare
    /// "no" is too often literal ("Tell the kids no, just give them the snacks").
    static let bareCue = "(?:no|nope|actually|sorry|wait|oops|rather)"

    /// Words that are never the verb whose object a correction retargets or keeps.
    private static let notVerbs: Set<String> = [
        "i", "you", "we", "they", "he", "she", "it", "me", "us", "him", "her", "them", "please", "pls",
        "can", "could", "would", "will", "should", "shall", "must", "may", "might", "to", "and", "or",
        "but", "so", "then", "also", "just", "maybe", "let's", "lets", "do", "does", "did", "don't",
        "doesn't", "didn't", "can't", "won't", "is", "are", "was", "were", "be", "been", "am", "have",
        "has", "had", "i'm", "i'll", "i'd", "it's", "that's", "thanks", "thank", "hi", "hey", "hello",
        "bye", "dear", "sorry", "okay", "ok", "yes", "yeah", "no", "well", "oh", "the", "a", "an",
        "not", "never", "with", "for", "about", "from", "at", "on", "in", "of", "by", "like",
    ]
    /// Particles and prepositions of a phrasal verb ("reach out to Raj", "hand over Wei").
    private static let particles: Set<String> = [
        "to", "out", "over", "up", "in", "with", "back", "on", "down", "off", "about", "through", "along",
    ]
    private static let objectDeterminers: Set<String> = ["the", "my", "our", "your", "their", "his", "this", "that", "these", "those", "a", "an"]
    private static let objectPronouns: Set<String> = ["him", "her", "them", "it", "me", "us", "you", "himself", "herself", "themselves"]

    private static func key(_ word: String) -> String {
        word.lowercased().replacingOccurrences(of: "\u{2019}", with: "'")
            .trimmingCharacters(in: CharacterSet.punctuationCharacters.subtracting(CharacterSet(charactersIn: "'-")))
    }

    private static func isWord(_ token: String) -> Bool {
        token.range(of: "^[A-Za-z][A-Za-z'\u{2019}-]*$", options: .regularExpression) != nil
    }

    private static func capitalizedFirst(_ text: String) -> String {
        guard let first = text.first else { return text }
        return first.uppercased() + text.dropFirst()
    }

    // MARK: - Retarget

    /// "<lead> <verb> <object>, <cue>, [just] <verb2> him|her|them <rest>" →
    /// "<lead> <verb2> <object> <rest>". Runs before "scratch that" deletes the clause.
    static func retarget(_ text: String) -> String {
        var current = text
        for _ in 0..<4 {
            guard let next = retargetFirst(current) else { break }
            current = next
        }
        return current
    }

    private static func retargetFirst(_ text: String) -> String? {
        let cue = "(?:\\s*,\\s*(?:\(multiwordCue)|\(bareCue))|\\s+\(multiwordCue))"
        let pattern = "^((?:.*[.!?]\\s+)?)([^.!?]+?)\(cue)[,.]?\\s+(?:just\\s+|instead\\s+)?([A-Za-z]+)\\s+(him|her|them)\\b"
        guard let match = Regex.firstMatch(text, pattern),
              let pre = match.string(at: 1, in: text), let clause = match.string(at: 2, in: text),
              let verb2 = match.string(at: 3, in: text), let whole = Range(match.range, in: text),
              !notVerbs.contains(key(verb2)), !particles.contains(key(verb2)),
              let frame = verbAndObject(of: clause)
        else { return nil }
        let verb = frame.lead.isEmpty ? capitalizedFirst(verb2.lowercased()) : verb2.lowercased()
        let rebuilt = [frame.lead, verb, frame.object].filter { !$0.isEmpty }.joined(separator: " ")
        return pre + rebuilt + text[whole.upperBound...]
    }

    /// Splits "<lead> <verb> [particles] <object>" off the end of a clause, or nil when the
    /// clause doesn't end in a verb and its object.
    private static func verbAndObject(of clause: String) -> (lead: String, object: String)? {
        let tokens = clause.split(separator: " ").map(String.init)
        guard tokens.count >= 2, let last = tokens.last, isWord(last) else { return nil }
        // The object: from a determiner in the last four words ("the whole team"), else trailing
        // capitalized words ("Raj Patel"), else one lowercase word ("chen").
        var objectStart = tokens.count - 1
        if let det = (max(1, tokens.count - 4)..<tokens.count).first(where: { objectDeterminers.contains(key(tokens[$0])) }),
           det < tokens.count - 1 {
            objectStart = det
        } else if last.first?.isUppercase == true {
            while objectStart > 1, tokens.count - objectStart < 3, isWord(tokens[objectStart - 1]),
                  tokens[objectStart - 1].first?.isUppercase == true {
                objectStart -= 1
            }
        } else if notVerbs.contains(key(last)) || particles.contains(key(last)) || objectPronouns.contains(key(last)) {
            return nil
        }
        let object = tokens[objectStart...]
        // One noun phrase: no pronoun, preposition or verb-ish word inside it ("the report to
        // Raj" has two objects, and "just email him" doesn't say which one it keeps).
        guard object.allSatisfy(isWord),
              !object.dropFirst().contains(where: { objectPronouns.contains(key($0)) || particles.contains(key($0)) || notVerbs.contains(key($0)) }),
              !objectPronouns.contains(key(object[objectStart]))
        else { return nil }
        // The verb, after at most two particles ("reach out to").
        var verbIndex = objectStart - 1
        var skipped = 0
        while verbIndex > 0, skipped < 2, particles.contains(key(tokens[verbIndex])) {
            verbIndex -= 1
            skipped += 1
        }
        guard verbIndex >= 0 else { return nil }
        let verb = tokens[verbIndex]
        guard isWord(verb), !notVerbs.contains(key(verb)) else { return nil }
        // A capitalized word mid-sentence is a name, not the verb ("Call Raj later").
        guard verbIndex == 0 || verb.first?.isLowercase == true else { return nil }
        return (tokens[..<verbIndex].joined(separator: " "), object.joined(separator: " "))
    }

    // MARK: - Head noun

    private static let headDeterminer = "(?:the|a|an|this|these|those|my|our|your|their)"
    private static let spanWord = "[A-Za-z0-9][A-Za-z0-9'\u{2019}-]*"
    /// Words that can't be part of a short noun phrase: the span would cross a clause.
    private static let notNounPhrase: Set<String> = [
        "to", "of", "for", "with", "and", "or", "but", "is", "are", "was", "were", "be", "in", "on", "at",
        "from", "by", "it", "i", "you", "we", "they", "he", "she", "that", "this", "not", "will", "can",
        "no", "so", "if", "as", "do", "did", "have", "has", "had", "just", "actually", "sorry", "wait",
        "mean", "meant", "the", "a", "an",
    ]

    /// "the <span>, <cue>, the <modifiers> one(s)|<same noun>" → the corrected noun phrase with
    /// the head noun kept: "the online maps, no, the offline ones" → "the offline maps"; "the
    /// window seat i mean the aisle seat" → "the aisle seat". Without "one(s)" or the repeated noun
    /// the correction isn't provably about this noun phrase, so it's left alone.
    static func headNoun(_ text: String) -> String {
        let cue = "(?:\\s*,\\s*(?:\(multiwordCue)|\(bareCue)|or rather)\\s*,?\\s+|\\s+(?:\(multiwordCue)|no|sorry|actually|or rather)\\s*,?\\s+)"
        let pattern = "\\b(\(headDeterminer))\\s+((?:\(spanWord)\\s+){0,3}\(spanWord))\(cue)(\(headDeterminer))\\s+((?:\(spanWord)\\s+){0,4}\(spanWord))"
        return Regex.replace(text, pattern) { whole, groups in
            guard groups.count > 4 else { return whole }
            let span = groups[2].split(separator: " ").map(String.init)
            let det = groups[3]
            let after = groups[4].split(separator: " ").map(String.init)
            guard !span.contains(where: { notNounPhrase.contains(key($0)) }) else { return whole }
            guard let replaced = correctedPhrase(span: span, after: after) else { return whole }
            let rest = after[replaced.consumed...].joined(separator: " ")
            let phrase = ([det] + replaced.words).joined(separator: " ")
            return rest.isEmpty ? phrase : phrase + " " + rest
        }
    }

    /// The corrected noun phrase (without its determiner) and how many words of `after` it used.
    private static func correctedPhrase(span: [String], after: [String]) -> (words: [String], consumed: Int)? {
        guard let noun = span.last else { return nil }
        for index in 1..<min(after.count, 4) {
            let modifiers = Array(after[..<index])
            guard !modifiers.contains(where: { notNounPhrase.contains(key($0)) || key($0) == "one" || key($0) == "ones" }) else { return nil }
            let head = after[index]
            let headKey = key(head)
            // "the old one, actually, the new one is fine": the replacement opens a new clause.
            if after.count > index + 1,
               startsClause(key(after[index + 1]), afterSingular: headKey == "one" || !looksPlural(headKey)) {
                return nil
            }
            if sameNoun(headKey, key(noun)) {
                // "the window seat, I mean the aisle seat": the plain swap is already frame-safe.
                return (modifiers + [head], index + 1)
            }
            if headKey == "one" || headKey == "ones" {
                // "ones" stands for a plural noun, "one" for a singular one: "the maps for the
                // long trip, no, the offline ones" is about the maps, not the trip.
                guard looksPlural(key(noun)) == (headKey == "ones") else { return nil }
                // "the old configuration values, no, the broken ones": the first word of the span
                // is the corrected modifier; a one-word span is itself the noun ("the draft, no,
                // the final one" → "the final draft").
                let kept = span.count == 1 ? span : Array(span.dropFirst())
                guard kept.allSatisfy({ !["one", "ones"].contains(key($0)) }) else { return nil }
                return (modifiers + kept, index + 1)
            }
        }
        return nil
    }

    /// Finite verbs that show the words after a cue start a new clause, not a noun phrase.
    static let clauseVerbs: Set<String> = [
        "is", "are", "was", "were", "has", "have", "had", "will", "would", "can", "could", "should",
        "does", "did", "doesn't", "don't", "didn't", "isn't", "aren't", "wasn't", "weren't", "won't",
        "can't", "looks", "seems", "works", "worked", "needs", "goes", "went", "came", "got", "love",
        "loves", "matters", "matter",
    ]

    /// True when `word`, right after a correction's head noun, is a finite verb — the words after
    /// the cue are a new clause ("…the dataset, actually, the second one runs faster"), not a
    /// noun phrase replacing the old one. Beyond `clauseVerbs`: a past tense ("-ed"), and after a
    /// singular head a present "-s" ("one runs", "one takes"). Declining is always safe here.
    static func startsClause(_ word: String, afterSingular: Bool) -> Bool {
        if clauseVerbs.contains(word) { return true }
        if word.count > 3, word.hasSuffix("ed") { return true }
        return afterSingular && word.count > 2 && word.hasSuffix("s") && !word.hasSuffix("ss") && !word.hasSuffix("'s")
    }

    private static func looksPlural(_ noun: String) -> Bool {
        if ["people", "children", "men", "women", "feet", "teeth", "mice", "data", "media"].contains(noun) { return true }
        guard noun.hasSuffix("s"), noun.count > 2 else { return false }
        return !(noun.hasSuffix("ss") || noun.hasSuffix("us") || noun.hasSuffix("is") || noun.hasSuffix("ous"))
    }

    private static func sameNoun(_ a: String, _ b: String) -> Bool {
        guard !a.isEmpty, !b.isEmpty else { return false }
        if a == b { return true }
        let stem = { (w: String) in w.hasSuffix("es") ? String(w.dropLast(2)) : w.hasSuffix("s") ? String(w.dropLast()) : w }
        return a.count > 3 && b.count > 3 && stem(a) == stem(b)
    }

    // MARK: - Keep the old value

    /// "<lead> <verb> <the thing> <prep> <value>, <cue>, keep|leave it <prep> <value> <tail>" →
    /// "<lead> keep|leave <the thing> <prep> <value> <tail>".
    static func keepValue(_ text: String) -> String {
        let cue = "(?:\\s*,\\s*(?:\(multiwordCue)|\(bareCue))|\\s+\(multiwordCue))"
        let pattern = "^((?:.*[.!?]\\s+)?)([^.!?]+?)\(cue)[,.]?\\s+(?:just\\s+)?(keep|leave)\\s+(?:it|that)\\s+(?=(?:on|at|in|as|to)\\b)"
        guard let match = Regex.firstMatch(text, pattern),
              let pre = match.string(at: 1, in: text), let clause = match.string(at: 2, in: text),
              let keepVerb = match.string(at: 3, in: text), let whole = Range(match.range, in: text)
        else { return text }
        let thingPattern = "^(.*?)\\b([A-Za-z]+)\\s+((?:the|my|our|your|their|this|that)\\s+.+?)\\s+(?:to|from|at|on|in|by|until|till|for|into|as)\\s+[^,]+$"
        guard let thing = Regex.firstMatch(clause, thingPattern),
              let lead = thing.string(at: 1, in: clause), let verb = thing.string(at: 2, in: clause),
              let object = thing.string(at: 3, in: clause),
              !notVerbs.contains(key(verb))
        else { return text }
        let leadText = lead.trimmingCharacters(in: .whitespaces)
        let verbText = leadText.isEmpty ? capitalizedFirst(keepVerb.lowercased()) : keepVerb.lowercased()
        let rebuilt = [leadText, verbText, object].filter { !$0.isEmpty }.joined(separator: " ")
        return pre + rebuilt + " " + text[whole.upperBound...]
    }
}
