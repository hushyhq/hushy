import Foundation

/// Whether an answer says "no" where the speaker did not, told apart from an answer that says the same thing the other
/// way round.
///
/// A count of negation words cannot tell "I'm too busy to take that on" from "I can't take that on" (the second has one
/// more word of negation and the same meaning), nor "I can do it" from "I can't do it" (the second has one more and the
/// opposite meaning). Counting words is the right test for the second pair, so it stays; what is wrong is that the words
/// counted are only half of how English says no. Two things were missing, and each is a closed set of words, not a
/// reading of the sentence:
/// - **Negation worded without "not".** "unable", "unwilling", "impossible", "unavailable", "nothing", "nobody",
///   "nowhere" say no as plainly as "can't". Counted on both sides, "can't" for "unable to" (and the reverse) is no
///   change at all.
/// - **A limit the speaker stated and the answer states with a negation.** "Too busy", "swamped", "my plate is full" and
///   "I'm out of time" already say "I can't". A rewrite that puts it as "I don't have the bandwidth" adds a negation word
///   for a limit that is gone from the answer: the same meaning, the words of a decline. Each such limit that is in the
///   speaker's words and not in the answer's pays for one negation the answer adds, and no more.
///
/// What this never lets through: a negation with nothing the speaker said to pay for it ("I can do it" to "I can't do
/// it", "send it" to "don't send it"), and a negation paid for by a limit the answer still states in the same word
/// ("I'm busy but I can do it" to "I'm busy and I can't do it"). A number of cases the lists cannot reach stay refused;
/// refusing is the safe side of this check, since the answer then falls back to the plain cleanup.
enum NegationPolarity {
    /// The contractions that say no, each with the word it says no to ("can't" is "can" denied), as
    /// `WordRelation.collapsed` spells them (no apostrophes). A speaker who takes one back says that word ("I can't make
    /// it, actually I can").
    static let positiveForm: [String: String] = [
        "cant": "can", "cannot": "can", "wont": "will", "dont": "do", "doesnt": "does", "didnt": "did", "isnt": "is",
        "arent": "are", "wasnt": "was", "werent": "were", "hasnt": "has", "havent": "have", "hadnt": "had",
        "shouldnt": "should", "wouldnt": "would", "couldnt": "could", "mustnt": "must", "neednt": "need",
        "shant": "shall", "aint": "is",
    ]

    /// Words that say no on their own, spelled as `positiveForm` spells them.
    static let negators: Set<String> = Set(positiveForm.keys).union([
        "not", "no", "never", "neither", "nor", "none",
        "unable", "unwilling", "impossible", "unavailable", "nothing", "nobody", "nowhere",
    ])

    /// Words that state a limit on what the speaker can or will do, so that "I can't" or "I don't have the time" follows
    /// from them. A closed list of limits on time, energy, space and room to act; nothing here is a verb, a noun of the
    /// topic or a word that is also an ordinary positive ("full" is here only in "full plate", "out" and "short" are not).
    static let limitWords: Set<String> = [
        "busy", "swamped", "slammed", "buried", "overloaded", "overwhelmed", "stretched", "booked", "underwater",
        "exhausted", "tired",
    ]

    /// Phrases (lower case) that state a limit in more than one word.
    private static let limitPhrases = [
        "tied up", "plate is full", "plate's full", "schedule is packed", "schedule's packed", "calendar is full",
        "calendar's full", "short on time", "short on bandwidth",
        "at capacity", "over capacity", "spread thin", "stretched thin",
        "maxed out", "at my limit", "too much on",
    ]

    /// "Too busy to", "too late for": a limit worded as an excess.
    private static let excess = "\\btoo\\s+[a-z']+\\s+(?:to|for)\\b"

    /// "Out of paper", "out of time": a limit that names what ran out.
    private static let ranOut = "\\bout\\s+of\\s+[a-z']+"

    /// How many negations `text` states, in either form (see the list above). `dunno`, "yes or no" and the like are
    /// settled as `CriticalTokenGuard.negationCount` always has.
    static func count(in text: String) -> Int { CriticalTokenGuard.negationCount(in: text) }

    /// The limits `text` states, as words: each limit word, each limit phrase as its own key, each "too … to".
    static func limits(in text: String) -> [String] {
        let lower = text.lowercased().replacingOccurrences(of: "\u{2019}", with: "'")
        var found = OutputGuard.words(lower.replacingOccurrences(of: "'", with: "")).filter { limitWords.contains($0) }
        for phrase in limitPhrases where lower.contains(phrase) { found.append(phrase) }
        found += Regex.matches(lower, excess).compactMap { $0.string(at: 0, in: lower) }.map { _ in "too…to" }
        found += Regex.matches(lower, ranOut).compactMap { $0.string(at: 0, in: lower) }
        return found
    }

    /// How many negations `answer` states beyond what the speaker's `draft` states and what a limit it stated that the
    /// answer no longer states pays for. Zero when the answer adds no negation, or adds no more than that.
    static func unpaidNegations(answer: String, draft: String) -> Int {
        let added = count(in: answer) - count(in: draft)
        guard added > 0 else { return 0 }
        var kept = limits(in: answer)
        var paid = 0
        for limit in limits(in: draft) {
            if let same = kept.firstIndex(of: limit) { kept.remove(at: same) } else { paid += 1 }
        }
        return max(0, added - paid)
    }

    /// True when `answer` says no where the speaker did not and no stated limit stands behind it.
    static func addsNegation(answer: String, draft: String) -> Bool {
        unpaidNegations(answer: answer, draft: draft) > 0
    }

    // MARK: A negation the answer lost

    /// A word as written, and whether a comma, stop or dash (or the end of the text) follows it.
    private struct Word {
        let text: String
        let breakAfter: Bool
        var key: String { text.replacingOccurrences(of: "'", with: "") }
    }

    private static func words(_ text: String) -> [Word] {
        let lower = text.lowercased().replacingOccurrences(of: "\u{2019}", with: "'")
        let heard = Regex.replace(lower, "\\b(yes|yeah|yep|yup)(\\s+(?:or|and|and\\s+a|or\\s+a)\\s+)know\\b") { _, parts in parts[1] + parts[2] + "no" }
        let expanded = heard.replacingOccurrences(of: "\\bdunno\\b", with: "don't know", options: .regularExpression)
        let matches = Regex.matches(expanded, "[\\p{L}\\p{N}][\\p{L}\\p{N}']*")
        return matches.enumerated().compactMap { offset, match -> Word? in
            guard let range = Range(match.range, in: expanded) else { return nil }
            let end = offset + 1 < matches.count ? Range(matches[offset + 1].range, in: expanded)?.lowerBound ?? expanded.endIndex
                : expanded.endIndex
            let between = expanded[range.upperBound..<end]
            let last = offset + 1 == matches.count
            return Word(text: String(expanded[range]), breakAfter: last || between.contains(where: { ",.;:!?\u{2014}\u{2013}".contains($0) }))
        }
    }

    /// Words after which "no" negates whatever came before it: "no one", "no longer", "no more".
    private static let negatingNo: Set<String> = ["one", "longer", "more"]

    /// A "no" or "nope" that answers or takes something back ("No, I can make it", "Toronto, no, Madrid", "ten days no
    /// a month"), not one that negates. A negating "no" stands after a verb or a preposition ("there is no time", "with
    /// no budget"; `PlainNegation`) or before "one", "longer" or "more". What this leaves open is a negating "no" in any
    /// other place ("we need no extra chairs"); dictated "no" is far more often the speaker correcting themselves.
    private static func isTakeBackNo(_ words: [Word], at index: Int) -> Bool {
        guard ["no", "nope"].contains(words[index].key) else { return false }
        if words[index].key == "no", PlainNegation.isPlain(words.map(\.text), at: index) { return false }
        return index + 1 == words.count || !negatingNo.contains(words[index + 1].key)
    }

    /// A written answer is not dictation: its "no" runs on from the word before it ("We received no response", "I've no
    /// idea") and negates, unless it stands alone ("No, I can make it", "Toronto, no, Madrid", "yes or no").
    private static func isStandaloneWrittenNo(_ words: [Word], at index: Int) -> Bool {
        guard ["no", "nope"].contains(words[index].key) else { return false }
        guard words[index].key == "no", !words[index].breakAfter else { return true }
        if index + 1 < words.count, negatingNo.contains(words[index + 1].key) { return false }
        return index == 0 || words[index - 1].breakAfter || ["or", "and", "yes", "yeah"].contains(words[index - 1].key)
    }

    /// Positions of words that take back what was said just before them: "wait", "sorry", "scratch that", "hold on",
    /// "my mistake", "I mean", "let me rephrase", "let me see", "second thought", "never mind", a correcting "no" or "actually". An
    /// opening or emphasis "actually" ("we should actually ship") takes nothing back, nor does a cue with nothing after it
    /// ("…, sorry").
    private static func takeBackCues(_ words: [Word], written: Bool) -> [Int] {
        let texts = words.map(\.text)
        return words.indices.filter { index in
            guard index + 1 < words.count else { return false }
            let word = words[index].key, after = words[index + 1].key
            let before = index > 0 ? words[index - 1].key : ""
            switch word {
            case "wait", "sorry", "scratch", "instead", "oops", "correction", "rephrase": return true
            case "actually": return index > 0 && !DisfluencyOnlyGuard.isEmphasisActually(texts, at: index)
            case "no", "nope": return written ? isStandaloneWrittenNo(words, at: index) : isTakeBackNo(words, at: index)
            case "mean", "meant": return before == "i"
            case "thought": return before == "second"
            case "see": return before == "me" && index > 1 && words[index - 2].key == "let"
            case "hold": return after == "on"
            case "mistake", "bad": return before == "my"
            case "never": return after == "mind"
            case "make", "change", "strike", "forget", "ignore": return after == "that"
            default: return false
            }
        }
    }

    /// "That's not right": the speaker saying the words before were wrong, not a negation of what follows.
    private static func isNotRight(_ words: [Word], at index: Int) -> Bool {
        guard words[index].key == "not", index > 0, index + 1 < words.count, words[index + 1].key == "right" else { return false }
        return words[index - 1].key == "thats" || (index > 1 && words[index - 2].key == "that" && words[index - 1].key == "is")
    }

    /// How far before a cue the words it takes back can start (`DisfluencyOnlyGuard` reads the same reach).
    private static let reachBefore = 8

    private static let hesitations: Set<String> = ["um", "uh", "er", "erm", "uhm", "hmm"]
    private static let subjects: Set<String> = ["i", "we", "you", "they", "he", "she", "it", "its", "this", "thats", "there"]

    /// A negation the speaker said and then began again: "we don't we don't need it", "I can't I won't make it", "we do
    /// not, we do not", "we should not we should never". The one to three words before the negation come again right
    /// after it (a hesitation between allowed), and the second time carries the speaker's words. One word that is not a
    /// subject counts only when a negation follows it again, so "do not do that" stays a negation. A negated modal left
    /// hanging before a comma and said again within a few words is the same ("…shouldn't, voice signatures should…").
    private static func isRestarted(_ words: [Word], at index: Int) -> Bool {
        let key = words[index].key
        if words[index].breakAfter, let positive = positiveForm[key],
           words[(index + 1)..<min(words.count, index + 6)].contains(where: { $0.key == positive || $0.key == key }) {
            return true
        }
        var resume = index + 1
        while resume < words.count, hesitations.contains(words[resume].key) { resume += 1 }
        for length in 1...3 where index >= length && resume + length <= words.count {
            let lead = words[(index - length)..<index].map(\.key)
            guard words[resume..<(resume + length)].map(\.key) == lead else { continue }
            let negatedAgain = resume + length < words.count && negators.contains(words[resume + length].key)
            if length > 1 || subjects.contains(lead[0]) || negatedAgain { return true }
        }
        return false
    }

    /// The negations of `words` that state what the speaker meant, as positions: not an answering or correcting "no",
    /// not "never mind", not the "not" of "sorry, not four", not a "nor" that carries on a negation already said ("I
    /// don't want tea nor coffee"), not one the speaker said and began again, and not one in the words a correction took
    /// back. A negation counts as taken back only when the cue really withdrew something: the answer leaves out a word
    /// between the negation and the cue, and the cue with it ("we do not ship in June, hold on, November" loses "June"
    /// and "hold on"), or the speaker started the clause again after it ("we will not extend the trial, no wait, we will
    /// extend it", "I can't make it, actually I can"). "I can't make it, sorry, I have a dentist appointment" does
    /// neither, so its "can't" stands. With `answer`, a negation the answer heard as the start of another word is no
    /// negation either ("no JS" written "Node.js"). Without it, `words` are a written answer.
    private static func meantNegations(_ words: [Word], answer: [Word]?) -> [Int] {
        let written = answer == nil
        let cues = takeBackCues(words, written: written)
        let answerCounts = Dictionary((answer ?? []).map { ($0.key, 1) }, uniquingKeysWith: +)
        let saidCounts = Dictionary(words.map { ($0.key, 1) }, uniquingKeysWith: +)
        func takesBack(_ cue: Int, from negation: Int) -> Bool {
            guard answer != nil else { return false }
            let cueKept = answerCounts[words[cue].key, default: 0] >= saidCounts[words[cue].key, default: 0]
            let lost = !cueKept && words[(negation + 1)..<cue].contains { word in
                word.key.count >= 3 && !negators.contains(word.key) && !DisfluencyOnlyGuard.droppable.contains(word.text)
                    && answerCounts[word.key] == nil
            }
            guard !lost, cue + 2 < words.count else { return lost }
            let before = words[max(0, cue - reachBefore)..<cue]
            let restart = (words[cue + 1].key, words[cue + 2].key)
            return zip(before, before.dropFirst()).contains { first, second in
                first.key == restart.0 && (second.key == restart.1 || positiveForm[second.key] == restart.1)
            }
        }
        // "Three emails, not one": a "not" that sets an alternative aside (no auxiliary before it) goes with that
        // alternative. The answer that leaves out "not one" still says three; one that keeps "Saturday" from "Friday,
        // not Saturday" and drops the "not" says the other day.
        func setsAsideWhatGoes(_ index: Int) -> Bool {
            guard answer != nil, words[index].key == "not", index + 1 < words.count,
                  !PlainNegation.isPlain(words.map(\.text), at: index) else { return false }
            let alternative = words[index + 1].key
            return answerCounts[alternative, default: 0] < saidCounts[alternative, default: 0]
        }
        func heardAsAnotherWord(_ index: Int) -> Bool {
            guard let answer, index + 1 < words.count else { return false }
            let negator = words[index].key, next = words[index + 1].key
            return zip(answer, answer.dropFirst()).contains { first, second in
                second.key == next && first.key.hasPrefix(negator) && first.key != negator && !negators.contains(first.key)
            }
        }
        // After an opening "no" or a lone "actually" a "not" is the speaker's ("No, not today", "it's actually not ready");
        // after "no, actually" it is the correction's.
        func correctsWithNot(_ cue: Int) -> Bool {
            if words[cue].key == "actually" { return cues.contains(cue - 1) }
            return cue > 0 || !isTakeBackNo(words, at: cue)
        }
        func carriesOn(_ index: Int) -> Bool {
            words[index].key == "nor" && words[max(0, index - reachBefore)..<index].contains { negators.contains($0.key) }
        }
        return words.indices.filter { index in
            guard negators.contains(words[index].key) else { return false }
            if written ? isStandaloneWrittenNo(words, at: index) : isTakeBackNo(words, at: index) { return false }
            if words[index].key == "never", index + 1 < words.count, words[index + 1].key == "mind" { return false }
            // "Sorry, not four", "strike that, not two weeks": the "not" belongs to the correction.
            if words[index].key == "not",
               cues.contains(where: { index > $0 && index - $0 <= 2 && correctsWithNot($0) }) || isNotRight(words, at: index) {
                return false
            }
            if carriesOn(index) || heardAsAnotherWord(index) || setsAsideWhatGoes(index) { return false }
            if !written, isRestarted(words, at: index) { return false }
            return !cues.contains { $0 > index && $0 - index <= reachBefore && takesBack($0, from: index) }
        }
    }

    // MARK: A negation the answer words without a negation

    /// Negative idioms a rewrite puts without a negation word, each with the words that put it. A new idiom is a new
    /// row; a double negative ("can't not go") is an obligation ("have to go") for every contraction.
    private static let idioms: [(said: [String], written: [[String]])] = {
        func phrases(_ list: [String]) -> [[String]] { list.map { $0.split(separator: " ").map(String.init) } }
        let eager = phrases(["look forward", "looking forward", "eager", "excited"])
        let rows: [(said: [String], written: [[String]])] = [
            (["cant", "wait"], eager), (["cannot", "wait"], eager),
            (["dont", "hesitate"], phrases(["feel free", "please"])), (["not", "hesitate"], phrases(["feel free", "please"])),
            (["whether", "or", "not"], phrases(["whether"])),
            (["nothing", "but"], phrases(["only", "just"])),
            (["no", "longer"], phrases(["anymore", "any more", "any longer"])),
        ]
        let obligation = phrases(["have to", "has to", "had to", "must", "need to", "needs to", "got to"])
        return rows + positiveForm.keys.sorted().map { ([$0, "not"], obligation) }
    }()

    /// Prefixes that make a word's antonym: "not sure" is "unsure", "don't agree" is "disagree".
    private static let negativePrefixes = ["un", "dis", "in", "im", "ir", "il", "non"]

    /// How many of the speaker's negations (`meant`, positions in `said`) the answer states with no negation word: a
    /// negative idiom put another way (`idioms`), or the word after the negation given its negative-prefixed antonym.
    /// Each written word stands for one idiom or antonym, and only where no negation of the answer's stands in the four
    /// words before it ("I don't look forward to it" says the opposite).
    private static func reworded(_ meant: [Int], said: [Word], answer: [Word]) -> Int {
        var used = Set<Int>()
        func take(_ phrase: [String]) -> Bool {
            let start = answer.indices.first { start in
                !used.contains(start) && start + phrase.count <= answer.count
                    && answer[start..<(start + phrase.count)].map(\.key) == phrase
                    && !answer[max(0, start - 4)..<start].contains { negators.contains($0.key) }
            }
            guard let start else { return false }
            used.insert(start)
            return true
        }
        let open = Set(meant)
        var credited = Set<Int>()
        for idiom in idioms {
            for start in said.indices where start + idiom.said.count <= said.count
                && said[start..<(start + idiom.said.count)].map(\.key) == idiom.said {
                let negations = (start..<(start + idiom.said.count)).filter { open.contains($0) && !credited.contains($0) }
                guard !negations.isEmpty, idiom.written.contains(where: take) else { continue }
                credited.formUnion(negations)
            }
        }
        let saidKeys = Set(said.map(\.key))
        for index in meant where !credited.contains(index) && !said[index].breakAfter && index + 1 < said.count {
            let reach = said[index + 1].breakAfter ? index + 2 : min(said.count, index + 3)
            let negated = said[(index + 1)..<min(said.count, reach)].filter { $0.key.count >= 4 && !negators.contains($0.key) }
            let antonym = negated.lazy.flatMap { word in negativePrefixes.map { $0 + word.key } }
                .first { !saidKeys.contains($0) && !negators.contains($0) && take([$0]) }
            if antonym != nil { credited.insert(index) }
        }
        return credited.count
    }

    /// How many negations the speaker meant (see `meantNegations`) `answer` no longer states. One the answer words
    /// another way (`reworded`) is kept, and a limit the answer now states that the speaker put as a negation ("I don't
    /// have the time" as "I'm stretched too thin") pays for one, the mirror of `unpaidNegations`. Zero when the answer
    /// still says no everywhere the speaker did.
    static func droppedNegations(answer: String, said: String) -> Int {
        let answerWords = words(answer)
        let saidWords = words(said)
        let meant = meantNegations(saidWords, answer: answerWords)
        let missing = meant.count - reworded(meant, said: saidWords, answer: answerWords)
            - meantNegations(answerWords, answer: nil).count
        guard missing > 0 else { return 0 }
        var spoken = limits(in: said)
        var paid = 0
        for limit in limits(in: answer) {
            if let same = spoken.firstIndex(of: limit) { spoken.remove(at: same) } else { paid += 1 }
        }
        return max(0, missing - paid)
    }

    /// True when `answer` no longer says no where the speaker meant it.
    static func dropsNegation(answer: String, said: String) -> Bool {
        droppedNegations(answer: answer, said: said) > 0
    }
}
