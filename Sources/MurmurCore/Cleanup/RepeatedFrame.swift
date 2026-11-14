import Foundation

/// An opening said twice: "we should cancel the Tuesday sync, we should cancel the Friday retro".
///
/// Three things look alike and are told apart by the shape of the speech, never by particular words:
/// - a restart stops short on a word that needs a complement ("I was going to, I wanted to ask") or on a word-start
///   ("send the inv, send the invoice"): the first attempt is dropped;
/// - a correction carries a cue next to the copies ("send it Tuesday, no, send it Wednesday", "send it Tuesday, send it
///   Wednesday instead"): the first is replaced;
/// - a repeat that adds follows a finished clause with the same opening and no cue: the speaker means both items.
/// This type finds the third and checks what a model answer did with it. It does not decide what the cleaned text says.
///
/// Known limits, kept on purpose: copies more than `reach` words apart are not compared; an opening of one word is not
/// an opening (it recurs in ordinary sentences); a repeat that straddles a group boundary is two groups and is not seen;
/// an item whose every content word also appears in a neighbouring item cannot be seen to be lost; and an uncued repeat
/// whose first attempt really was abandoned on a content word is read as an addition, because losing an item is the
/// worse mistake (the text then keeps the repeat, and a model is asked again). Three more, each chosen the same way:
/// a cue more than `cueReachAfter` words after the second opening is not seen, so that correction is left as spoken
/// rather than applied; a complete word that is a prefix of the next item's word ("Ann" / "Anna") reads as an aborted
/// word-start, as it already does on main (`isFragment`); and a bare verb cue ("cancel", "skip") right after another clause
/// stays a cue, as on main.
enum RepeatedFrame {
    /// One opening said twice, as two neighbouring copies: the first copy, the finished item between them, the second copy.
    struct Repeat {
        let frame: Range<Int>
        let item: Range<Int>
        let second: Range<Int>
    }

    /// The most words between the two copies of an opening that still read as one thought.
    private static let reach = 16
    /// How far past the second copy's opening a cue still belongs to the second item ("send it Wednesday instead").
    private static let cueReachAfter = 3

    /// Repeats of an opening of at least `minimumLength` words, as neighbouring copies, whose first item is a finished
    /// thought with no cue next to it, and which something follows. `words` is lowercase, without punctuation.
    static func finishedRepeats(in words: [String], minimumLength: Int) -> [Repeat] {
        let cues = Set(DisfluencyOnlyGuard.cueIndices(in: words))
        var found: [Repeat] = []
        for left in words.indices {
            // Inside a longer repeated stretch the copies were already compared at its first word.
            guard let right = nextCopy(of: left, in: words, minimumLength: minimumLength) else { continue }
            var length = 0
            while left + length < right, right + length < words.count, words[left + length] == words[right + length] { length += 1 }
            let item = (left + length)..<right
            let afterSecond = (right + length)..<min(words.count, right + length + cueReachAfter)
            guard !item.isEmpty, right + length < words.count,
                  !DisfluencyOnlyGuard.unfinishedEnders.contains(words[right - 1]),
                  !words[right + length].hasPrefix(words[right - 1]) || words[right + length] == words[right - 1],
                  !item.contains(where: cues.contains), !afterSecond.contains(where: cues.contains) else { continue }
            found.append(Repeat(frame: left..<(left + length), item: item, second: right..<(right + length)))
        }
        return found
    }

    /// The nearest later index where the opening that starts at `left` is said again, if it starts a repeated stretch.
    private static func nextCopy(of left: Int, in words: [String], minimumLength: Int) -> Int? {
        for right in (left + 2)..<max(left + 2, min(words.count, left + reach)) where words[left] == words[right] {
            if left > 0, words[left - 1] == words[right - 1] { continue }
            var length = 0
            while left + length < right, right + length < words.count, words[left + length] == words[right + length] { length += 1 }
            if length >= minimumLength { return right }
        }
        return nil
    }

    private static func isContent(_ word: String) -> Bool {
        !DisfluencyOnlyGuard.droppable.contains(word) && word.count > 2 && !word.contains(where: \.isNumber)
    }

    /// Content words of the items the speaker meant to keep, each item judged on its own: a word an item shares with the
    /// item that follows it (the stretch of equal length after the second copy) cannot show that either survived, so only
    /// the words an item has to itself are returned. Numbers are left to the number checks.
    static func firstItemWords(_ words: [String]) -> [String] {
        let repeats = finishedRepeats(in: words, minimumLength: 2)
        return repeats.flatMap { found -> [String] in
            let own = found.item.filter { isContent(words[$0]) && !DisfluencyOnlyGuard.isFragment(words, at: $0) }.map { words[$0] }
            let neighbour = Set(words[found.second.upperBound..<min(words.count, found.second.upperBound + found.item.count + 2)])
            let others = Set(repeats.filter { $0.item != found.item }.flatMap { words[$0.item] })
            return own.filter { !neighbour.contains($0) && !others.contains($0) }
        }
    }

    private static func fourGrams(_ words: [String]) -> [String: Int] {
        guard words.count >= 4 else { return [:] }
        return Dictionary((0...(words.count - 4)).map { (words[$0..<($0 + 4)].joined(separator: " "), 1) }, uniquingKeysWith: +)
    }

    /// Words that sequence or set against each other: the closed class of ordinals, sequence adverbs and contrast
    /// connectives. Next to a copy they say the repeat is a sequence or a contrast, which joining would erase; an answer
    /// that adds one has put an order or a contrast the speaker did not say.
    private static let ordersOrOpposes: Set<String> = [
        "first", "second", "third", "fourth", "next", "then", "finally", "lastly", "afterwards", "meanwhile",
        "but", "while", "whereas", "versus", "however", "although", "though", "instead", "rather", "unlike", "otherwise",
    ]

    /// Why a model answer to a draft that says an opening twice did more than join, or nil. Three things only:
    /// a clause copied in again (a four-word stretch with a content word that the answer says twice or more, more often than the draft),
    /// a word of the opening left out altogether (a "can you" that made a request, a question word; a word the answer corrected at every place it stood, `reheard`, is not left out), and an order or
    /// contrast word the speaker did not say.
    static func violation(draftWords: [String], answerWords: [String], reheard: Set<String> = []) -> String? {
        let repeats = finishedRepeats(in: draftWords, minimumLength: 2)
        guard !repeats.isEmpty else { return nil }
        let before = fourGrams(draftWords)
        let copied = fourGrams(answerWords).filter { gram, count in
            count > 1 && count > before[gram, default: 0] && gram.split(separator: " ").contains { isContent(String($0)) }
        }
        if let gram = copied.keys.sorted().first { return "added content words: [\"\(gram)\"]" }
        let answerSet = Set(answerWords)
        // A filler the opening happens to be built on ("like the draft ... like the review") is not what the opening says:
        // only its content words can be lost, as in `firstItemWords`. A "can you" keeps "can" and is still seen.
        let openingLost = repeats.flatMap { draftWords[$0.frame] }.filter { isContent($0) && !answerSet.contains($0) && !reheard.contains($0) }
        if !openingLost.isEmpty { return "dropped content words: \(Array(Set(openingLost)).sorted().prefix(4))" }
        let added = answerWords.filter { ordersOrOpposes.contains($0) && !draftWords.contains($0) }
        if !added.isEmpty { return "added content words: \(Array(Set(added)).sorted().prefix(4))" }
        return nil
    }

    /// What to tell the second model about a text that already holds an opening said twice.
    struct Prompt {
        let note: String
        let opening: [String]
    }

    /// The prompt for a text that says an opening twice, or nil when it does not. Three words or more, with a content
    /// word among them, so that "I think" and "we should" opening two sentences do not each cost a second model call;
    /// and none when a sequence or contrast word sits next to a copy. The note asks for the join and nothing else.
    static func prompt(for text: String) -> Prompt? {
        let words = EvalMetrics.normalizedWords(text)
        let found = finishedRepeats(in: words, minimumLength: 3).first { found in
            let between = words[max(0, found.frame.lowerBound - 1)..<found.second.lowerBound]
            return !between.contains(where: ordersOrOpposes.contains) && found.frame.contains { isContent(words[$0]) && !DisfluencyOnlyGuard.unfinishedEnders.contains(words[$0]) }
        }
        guard let found else { return nil }
        let opening = Array(words[found.frame])
        let note = "\nThe speaker said \"\(opening.joined(separator: " "))\" twice. If the second time only adds another item to the first, "
            + "say the opening once and join the two items with \"and\". Change nothing else: keep every other word, keep the sentence "
            + "as the speaker framed it (a question stays a question, a request stays a request), and add no word that orders or "
            + "contrasts the items. If the second time is not an addition, leave the text as it is."
        return Prompt(note: note, opening: opening)
    }

    /// Whether a second-model answer said the opening fewer times than the text it was given: the join the note asked for.
    static func joined(_ prompt: Prompt, from first: String, to answer: String) -> Bool {
        func count(_ text: String) -> Int {
            let words = EvalMetrics.normalizedWords(text)
            let size = prompt.opening.count
            guard words.count >= size else { return 0 }
            return (0...(words.count - size)).filter { Array(words[$0..<($0 + size)]) == prompt.opening }.count
        }
        return count(answer) < count(first)
    }
}
