import Foundation
import NaturalLanguage

/// A word the speaker said that the whole-transcript model's answer left a hole where, which no check looked for.
///
/// `IntentOutputGuard` refuses unsupported values and malformed answers, and `RewriteAccount` counts what an answer
/// *adds*. Neither reads what it takes away. So a model that tidied "…the best success for our app and I go with that"
/// into "…the best success for, and I go with that" passed every check: the noun was simply gone and the sentence left
/// open where it stood. The older group path has had `OutputGuard`'s dropped-word checks since the start; this is the
/// narrow form of the same question for the intent model, whose answers are rewrites, not edits.
///
/// What it does not touch is the intent model's choice of which spoken material says what was meant: a purpose phrase, a
/// clause before a hedge, a tail like "on Friday", taken out whole with the sentence closed behind it
/// (`IntentPipelineGuardTests` pin this: "omitted content is left to the intent model"). It looks only at a hole in the
/// middle of a clause (`holes`), where the place of what is missing is certain and the answer is plainly unfinished.
///
/// What a rewrite may leave out even from the middle of a clause, each a closed class and not a list of phrases:
/// - words that carry no content (glue, politeness, fillers and discourse markers: `RegisterWording`,
///   `DisfluencyOnlyGuard.droppable`), words of two letters or fewer, chunks of time and measure ("a free minute"), and
///   the words that only say how a figure or symbol is spoken ("half past ten", "dot com");
/// - stutters, aborted word-starts, restarts, and anything a correction cue reaches; a dictation with a retraction in it
///   is not read at all, because the retraction checks decide which words belong and putting a word back could bring
///   back what the speaker took away;
/// - a word the answer has in another form (an inflection, a near spelling, two words written as one);
/// - numbers (`NumberValueGuard` compares them by value in both directions);
/// - a content word the answer words another way ("folks" for "team"): a content word the answer puts in the same
///   changed stretch pays for one that is gone, and one placed elsewhere ("going to" for "gonna") does not;
/// - under a register (Professional, Casual, Prompt), which rewords on purpose, everything but nouns and names.
///
/// What is left is a noun or a name (and, with no register, a verb or an adjective) that is gone from the middle of a clause.
/// It is put back where it stood, and the answer is judged again by every other check.
enum DroppedContent {
    /// The reason in the guard's own form, so the log line and the closed `GuardCode` table agree.
    static let reason = "dropped content words"

    /// Part-of-speech tags of the words of `text`, read in the sentence they stand in, by the word as
    /// `EvalMetrics.normalizedWords` spells it. A word the tagger does not tag is not in the table.
    private static func lexicalTags(_ text: String) -> [String: Set<NLTag>] {
        guard !text.isEmpty else { return [:] }
        let tagger = NLTagger(tagSchemes: [.lexicalClass])
        tagger.string = text
        tagger.setLanguage(.english, range: text.startIndex..<text.endIndex)
        var tags: [String: Set<NLTag>] = [:]
        tagger.enumerateTags(in: text.startIndex..<text.endIndex, unit: .word, scheme: .lexicalClass,
                             options: [.omitWhitespace, .omitPunctuation]) { tag, range in
            guard let tag else { return true }
            for word in EvalMetrics.normalizedWords(String(text[range])) { tags[word, default: []].insert(tag) }
            return true
        }
        return tags
    }

    /// The classes of word a rewrite may leave out without leaving out something said: adverbs and intensifiers ("really",
    /// "completely"), interjections, and the closed classes.
    private static let leavable: Set<NLTag> = [
        .adverb, .interjection, .determiner, .pronoun, .preposition, .conjunction, .particle, .classifier, .idiom,
    ]

    /// Words that are not a noun, verb or name of the topic: a chunk of time or measure ("a free minute", "at the moment",
    /// "the way"), and words that only say how a figure or a symbol is spoken ("half past ten", "dot com", "new line").
    private static let chunks: Set<String> = [
        "moment", "minute", "minutes", "second", "seconds", "sec", "time", "times", "point", "way", "ways", "bit", "lot",
        "couple", "bunch", "deal", "kind", "sort",
        "quarter", "half", "past", "dot", "dash", "slash", "colon", "comma", "period", "line", "lines", "paragraph", "new",
        "nobody", "somebody", "anybody", "everybody", "someone", "anyone", "everyone", "nothing", "something", "anything",
        "everything", "nowhere", "somewhere", "anywhere",
        // The frame a request or a statement of need is put in, which a tidy-up or a list takes away ("I need tomato, onions").
        "need", "needs", "needed", "want", "wants", "wanted", "help", "able", "get", "gets", "got", "tell", "let", "try",
    ]

    /// Whether `word` (as `EvalMetrics.normalizedWords` spells it) is something a rewrite is not free to leave out, in
    /// the sentence `tags` were read from. Under a register (Professional, Casual, Prompt) the model rewords on purpose
    /// ("I left the key at reception" is "The key's at reception", "I need you to send it" is "Could you send it"), so
    /// only a noun or a name counts there; with no register the answer is the same sentence tidied, and a verb or an
    /// adjective counts too. Never glue, a filler, a number, a chunk of time or measure, or a word of three letters or less.
    /// A word a tagger could not place is taken to be a noun.
    static func isContent(_ word: String, tags: [String: Set<NLTag>] = [:], register: IntentRegister? = nil) -> Bool {
        let key = WordRelation.collapsed(word)
        guard key.count >= 3, !key.contains(where: \.isNumber), !SpokenNumberRuns.isNumberWord(key) else { return false }
        guard !RegisterWording.isGlue(key), !RegisterWording.filler.contains(key), !chunks.contains(key),
              !DisfluencyOnlyGuard.droppable.contains(key), !DisfluencyOnlyGuard.droppable.contains(word) else { return false }
        guard let classes = tags[word], !classes.isEmpty else { return true }
        if classes.isSubset(of: leavable) { return false }
        if register != nil, !classes.contains(.noun), !classes.contains(.otherWord) { return false }
        return true
    }

    /// Words that name what a figure counts. "ten thousand dollars" written "$10,000" has not lost "dollars".
    private static let units: Set<String> = [
        "dollar", "dollars", "euro", "euros", "pound", "pounds", "cent", "cents", "percent", "degrees", "degree", "bucks",
    ]

    /// Verbs of the phrases a speaker uses to think aloud or take something back ("let me see", "I guess", "come to think
    /// of it", "hold on", "make that", "say"). Leaving them out loses no fact; the word they carry is the correction's.
    private static let discourseVerbs: Set<String> = [
        "see", "say", "guess", "think", "mean", "know", "hold", "come", "make", "look", "let", "wait", "ignore", "strike",
        "rephrase", "mistake", "wrong", "correct", "correction", "scratch", "forget", "never", "oops", "oop", "erm", "hmm", "mhm",
    ]

    /// The words that can take something back or think aloud, which `ModelHints.correctionCues` and the older guards read.
    private static let cueWords: Set<String> = DisfluencyOnlyGuard.correctionCues.union(discourseVerbs)

    /// How far a cue reaches: the words it takes back come before it (the abandoned clause can be long), the words that
    /// replace them right after.
    private static let reachBefore = 14
    private static let reachAfter = 6

    /// Raw words (by position) the answer has no counterpart for, after what a rewrite may leave out is removed: a word
    /// said twice, a cut-off word, a restart, anything a cue reaches (`reachBefore`, `reachAfter`).
    private static func absent(said: [String], written: [String]) -> [(index: Int, word: String)] {
        var remaining: [String: Int] = [:]
        for word in written { remaining[word, default: 0] += 1 }
        let counts = Dictionary(said.map { ($0, 1) }, uniquingKeysWith: +)
        let cues = said.indices.filter {
            cueWords.contains(said[$0]) && !DisfluencyOnlyGuard.isEmphasisActually(said, at: $0) && !PlainNegation.isPlain(said, at: $0)
        }
        var result: [(index: Int, word: String)] = []
        for (index, word) in said.enumerated() {
            if let left = remaining[word], left > 0 { remaining[word] = left - 1; continue }
            if DisfluencyOnlyGuard.droppable.contains(word) || word.count <= 2 || counts[word, default: 0] > 1 { continue }
            if DisfluencyOnlyGuard.isFragment(said, at: index) || DisfluencyOnlyGuard.insideRestart(said, at: index) { continue }
            if cues.contains(where: { index >= $0 - reachBefore && index <= $0 + reachAfter }) { continue }
            result.append((index, word))
        }
        return result
    }

    /// Words that take something back or change it, beyond the cues `IntentOutputGuard.hasRetraction` reads.
    private static let retractingWords: Set<String> = [
        "bad", "thoughts", "hang", "ignore", "strike", "change", "changed", "mistake", "wrong", "rephrase", "oops", "oop",
        "sorry", "nope", "scratch", "forget", "scrap", "revise", "instead", "correction",
    ]

    /// Whether the speaker took something back in `raw`. A retraction decides which of the words said belong in the
    /// answer, which is the job of the retraction checks (`RetractedWording`, `NumberValueGuard`); a word that goes with
    /// it is not a loss, and putting it back would bring back what the speaker took away. So an answer to a dictation
    /// that holds one is not read for losses.
    private static func retracts(_ raw: String, said: [String]) -> Bool {
        IntentOutputGuard.hasRetraction(raw) || said.contains { retractingWords.contains($0) }
    }

    /// The content words of `raw` that `answer` leaves out with nothing in their place, before any question of where.
    private static func candidates(answer: String, raw: String, register: IntentRegister?) -> Set<String> {
        let said = EvalMetrics.normalizedWords(raw)
        let written = EvalMetrics.normalizedWords(answer)
        guard !said.isEmpty, !written.isEmpty, !retracts(raw, said: said) else { return [] }
        let account = RewriteAccount.measure(answer, against: raw)
        let gone = Set(account.droppedWords)
        let spokenTags = lexicalTags(raw)
        let figures = answer.contains(where: { "$€£%".contains($0) }) || written.contains { $0.contains(where: \.isNumber) }
        let candidates = absent(said: said, written: written).filter { entry in
            let word = entry.word
            return gone.contains(WordRelation.collapsed(word)) && isContent(word, tags: spokenTags, register: register)
                && !discourseVerbs.contains(word) && !(figures && units.contains(word))
                // Two words written as one ("out of date", "outdated") still has the word in it.
                && !(word.count >= 4 && written.contains { $0.contains(word) })
        }
        guard !candidates.isEmpty else { return [] }
        let writtenTags = lexicalTags(answer)
        var unpaid = Set<String>()
        for case .changed(let old, let new) in BoostGuard.align(said, written) {
            let lostHere = candidates.filter { old.contains($0.index) }
            let payers = written[new].count { isContent($0, tags: writtenTags, register: register) }
            if lostHere.count > payers { unpaid.formUnion(lostHere.map { WordRelation.collapsed($0.word) }) }
        }
        return unpaid
    }

    /// A hole the answer left in the middle of a clause: words of the speaker's that are gone, with the two words that stood
    /// either side of them one right after the other in the answer.
    struct Hole {
        /// The content words the answer lost there.
        let words: [String]
        /// What the speaker said there, as the speaker said it.
        let phrase: String
        /// Where it goes in the answer: the end of the word before the hole.
        let at: String.Index
    }

    /// The holes in `answer`, in the order said.
    ///
    /// Only a hole in the middle of a clause counts: the words before and after the lost run are both in the answer, side by
    /// side, in the speaker's order, with no sentence break between them ("…the best success for, and I go with that" where
    /// the speaker said "for our app and I go with that"). Everything the intent model takes out whole, with the sentence
    /// closed behind it (a purpose phrase, a clause before a hedge, a trailing "on Friday"), is its choice of which words
    /// say what was meant, and stays its choice: the gate "does not restore omissions" (`IntentOutputGuard`). What it never
    /// does is leave the sentence open where a word was: that is a word lost, and where it stood is certain.
    static func holes(answer: String, raw: String, register: IntentRegister? = nil) -> [Hole] {
        let lostKeys = candidates(answer: answer, raw: raw, register: register)
        guard !lostKeys.isEmpty else { return [] }
        let gone = Set(RewriteAccount.measure(answer, against: raw).droppedWords)
        let said = tokens(raw), written = tokens(answer)
        guard !said.isEmpty, !written.isEmpty else { return [] }
        var holes: [Hole] = []
        var index = 0
        while index < said.count {
            guard gone.contains(said[index].key) else { index += 1; continue }
            let start = index
            var end = index
            while end + 1 < said.count, gone.contains(said[end + 1].key) { end += 1 }
            index = end + 1
            let run = Array(said[start...end])
            guard let last = run.lastIndex(where: { lostKeys.contains($0.key) }), start > 0, end + 1 < said.count else { continue }
            var first = 0
            while first < last, RegisterWording.filler.contains(run[first].key) { first += 1 }
            guard let from = run[first...last].first, let to = run[first...last].last,
                  let at = place(after: said[start - 1].key, before: said[end + 1].key, in: written, answer: answer) else { continue }
            let words = run[first...last].map(\.key).filter(lostKeys.contains)
            holes.append(Hole(words: words, phrase: String(raw[from.range.lowerBound..<to.range.upperBound]), at: at))
        }
        return holes
    }

    /// The content words `answer` loses from the middle of a clause (see `holes`).
    static func lost(answer: String, raw: String, register: IntentRegister? = nil) -> [String] {
        holes(answer: answer, raw: raw, register: register).flatMap(\.words)
    }

    /// The refusal for an answer that leaves content out, in the form every guard reason has.
    static func violation(answer: String, raw: String, register: IntentRegister? = nil) -> String? {
        let words = lost(answer: answer, raw: raw, register: register)
        return words.isEmpty ? nil : "\(reason): \(Array(words.prefix(4)))"
    }

    // MARK: A name left out

    /// The reason for a register answer that leaves out a name; it carries no words.
    static let droppedNameReason = "\(reason): name"

    /// Whether `answer` leaves out a name the speaker said, anywhere: a leading subject ("J Hai and Quan are out…" written
    /// "Ping me instead, as Quan is out…"), a name in a list. `holes` reads only the middle of a clause; a name is never
    /// the model's to leave out. A name written together with a word beside it ("DeAaron", `writtenJoined`) is kept. A name the
    /// answer spells another way ("Shengun" as "Şengün", "Holgren" as "Holmgren": the same first letter and a near spelling,
    /// accents aside) is not left out, and neither is a filler ("Um") or a name a correction took back (`takenBack`).
    static func dropsName(answer: String, raw: String) -> Bool {
        let written = Set(RewriteAccount.keys(answer).map(folded))
        let said = RewriteAccount.keys(raw)
        let foldedSaid = said.map(folded)
        return names(in: raw).contains { name in
            let key = folded(name)
            guard !written.contains(where: { $0 == key || ($0.first == key.first && WordRelation.isNearSpelling($0, key)) })
            else { return false }
            return !writtenJoined(key, said: foldedSaid, written: written) && !takenBack(name, in: said)
        }
    }

    /// The name written together with the words beside it, as one word ("De Aaron" as "DeAaron", "J Hai" as "Jhai",
    /// "Speech Engine" as "SpeechEngine"): the name is still there.
    private static func writtenJoined(_ name: String, said: [String], written: Set<String>) -> Bool {
        said.indices.filter { said[$0] == name }.contains { place in
            (max(0, place - 3)...place).contains { start in
                (place..<min(said.count, start + 4)).contains { end in
                    end > start && written.contains(said[start...end].joined())
                }
            }
        }
    }

    /// A name a correction cue follows closely ("Marcus, no, sorry, Ana", "Marcus, I mean Ana") was taken back. The cue
    /// must stand within `nameCueReach` words after every place the name was said; a cue further on ("J Hai and Quan are
    /// out until Monday, so ping me instead") takes back something else.
    private static func takenBack(_ name: String, in said: [String]) -> Bool {
        let places = said.indices.filter { said[$0] == name }
        guard !places.isEmpty else { return false }
        return places.allSatisfy { place in
            (place + 1..<min(said.count, place + 1 + nameCueReach)).contains { index in
                nameCues.contains(said[index]) || (said[index] == "i" && index + 1 < said.count && ["mean", "meant"].contains(said[index + 1]))
            }
        }
    }

    private static let nameCueReach = 4
    private static let nameCues: Set<String> = [
        "no", "nope", "actually", "wait", "sorry", "scratch", "forget", "instead", "rather", "oops", "correction", "nevermind",
    ]

    /// Without accents, so a name re-spelled with its own letters ("Shengun" as "Şengün") reads as the same name.
    private static func folded(_ key: String) -> String {
        key.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil)
    }

    /// The names in `raw`, keyed as `RewriteAccount` keys words: a word written with a capital and then a small letter
    /// ("Hai", "Okonkwo-Reilly", "McKenna"; not "I", not an acronym). Inside a sentence the capital is the recogniser's
    /// evidence of a name ("J Hai"); at a sentence's start it is only the sentence's, so there the word counts when it is
    /// not ordinary English ("Quan is out", not "Can you").
    static func names(in raw: String) -> [String] {
        Regex.matchesCaseSensitive(raw, "\\p{Lu}[\\p{L}'\u{2019}-]*\\p{Ll}[\\p{L}'\u{2019}-]*").flatMap { match -> [String] in
            guard let range = Range(match.range, in: raw) else { return [] }
            let before = raw[..<range.lowerBound].last(where: { $0.isNewline || !($0.isWhitespace || "\"'\u{201C}\u{2018}(-".contains($0)) })
            let opens = before.map { $0.isNewline || ".!?:".contains($0) } ?? true
            return RewriteAccount.keys(String(raw[range])).filter { key in
                key.count >= 2 && !(opens && WordFrequency.shared.isOrdinary(key)) && !RegisterWording.filler.contains(key)
                    && !DisfluencyOnlyGuard.droppable.contains(key)
            }
        }
    }

    // MARK: Putting a dropped piece back

    private struct Token {
        let key: String
        let range: Range<String.Index>
    }

    private static func tokens(_ text: String) -> [Token] {
        Regex.matches(text, "[\\p{L}\\p{N}][\\p{L}\\p{N}'\u{2019}]*").compactMap { match -> Token? in
            guard let range = Range(match.range, in: text) else { return nil }
            let word = String(text[range])
            let key = WordRelation.collapsed(EvalMetrics.normalizedWords(word).first ?? word)
            return key.isEmpty ? nil : Token(key: key, range: range)
        }
    }

    /// `answer` with each hole filled with what the speaker said there, or nil when there is none. The model's rewording
    /// of everything else stays. The caller judges the result again with every other check.
    static func restoring(answer: String, raw: String, register: IntentRegister? = nil) -> String? {
        let found = holes(answer: answer, raw: raw, register: register)
        guard !found.isEmpty else { return nil }
        var restored = answer
        for hole in found.sorted(by: { $0.at > $1.at }) { restored.insert(contentsOf: " " + hole.phrase, at: hole.at) }
        return lost(answer: restored, raw: raw, register: register).isEmpty ? restored : nil
    }

    /// Words a clause cannot end on: prepositions, articles, possessives, conjunctions, "to", and the auxiliaries.
    private static let unfinished: Set<String> = [
        "for", "to", "of", "in", "on", "at", "by", "with", "from", "about", "into", "than", "as", "the", "a", "an", "my", "our",
        "your", "their", "his", "her", "its", "and", "or", "but", "that", "is", "are", "was", "were", "be", "been", "will", "would",
        "can", "could", "should", "so", "because", "if", "when",
    ]

    private static let identifierJoiners: Set<Character> = ["_", "-", "/"]

    /// Where a run goes: the end of the answer's only word `head` that is followed by `tail` with no sentence break between.
    private static func place(after head: String, before tail: String, in written: [Token], answer: String) -> String.Index? {
        var found: String.Index?
        for position in written.indices where written[position].key == head {
            guard position + 1 < written.count, written[position + 1].key == tail else { continue }
            let between = answer[written[position].range.upperBound..<written[position + 1].range.lowerBound]
            guard !between.contains(where: { ".!?;:\n".contains($0) }) else { continue }
            // Words written as one identifier ("max_retries", "build-id") are not a gap: the speaker's "underscore" or
            // "dash" is the character between them, and putting the word back would split the name it joins.
            guard !between.contains(where: { identifierJoiners.contains($0) }) else { continue }
            // A comma between them is a clause break unless the word before it cannot end a clause ("for, and I go"): a name or
            // a noun followed by a comma ("Leo, I'm too busy") is a finished opening, and what was said there was left out whole.
            if between.contains(","), !unfinished.contains(head) { continue }
            if found != nil { return nil }
            found = written[position].range.upperBound
        }
        return found
    }
}
