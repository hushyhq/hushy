import Foundation

/// The counters of a list said aloud ("one … two … 3 … number four … fifth …"), found when the answer lays the items
/// out as a list, so the value checks read the list numbers as layout and not as values the speaker said.
///
/// `FoldedCounters` covers an answer that writes the items as prose, and `NumberValueGuard` a numbered answer whose
/// count matches counters said as plain words. A real dictated list is looser: the speaker mixes "one", "2", "number
/// three" and "fourth", corrects themselves ("three let's use the quill no wait three let's use the feather"), and the
/// answer may number or bullet the items. Here a counter is
/// - a whole number from 1 to 20 said as a word or digits, or an ordinal from first to twentieth, optionally after
///   "number", "item", "step" or "point" (that word goes with it);
/// - the next number of the list (the list starts at one), or the same number again right after a correction cue
///   within the four words before it;
/// - a word on its own: no number word or digit after it (nor before the first counter), no determiner or value word
///   before a cardinal ("the one",
///   "at 3", "costs five"), and an item word after it that is not a unit or quantity ("two weeks", "one of", "3 pm").
/// It needs two counters at least and an answer with a list line for every item counted. Every other number stays in the draft,
/// so an amount, a time, a date, a version or a count inside an item still binds.
enum SpokenListCounters {
    private static let prefixes: Set<String> = ["number", "item", "step", "point"]
    private static let determiners: Set<String> = [
        "the", "this", "that", "these", "those", "which", "another", "each", "every", "any", "a", "an", "my", "your", "our",
        "their", "his", "her", "its", "no", "only", "just", "page", "chapter", "section", "option", "version", "room",
    ]
    /// A word that makes the number after it a value whatever follows: "at 3", "by four", "is two", "costs five".
    private static let valueWords: Set<String> = [
        "at", "by", "until", "till", "before", "after", "from", "around", "about", "for", "in", "on", "under", "over",
        "is", "are", "was", "were", "be", "been", "cost", "costs", "of", "with", "than", "maybe", "like", "say", "roughly",
    ]
    private static let notItems: Set<String> = [
        "of", "more", "other", "another", "half", "hundred", "thousand", "million", "billion", "point", "percent", "times",
        "second", "seconds", "minute", "minutes", "hour", "hours", "day", "days", "week", "weeks", "month", "months",
        "year", "years", "dollar", "dollars", "euro", "euros", "pound", "pounds", "cent", "cents", "bucks",
        "mile", "miles", "kilometers", "kilometres", "meters", "metres", "gig", "gigs", "am", "pm", "oclock", "o'clock",
        "x", "per", "or", "to", "and",
    ]
    private static let cues: Set<String> = ["no", "wait", "sorry", "actually", "mean", "meant", "change", "rather", "scratch", "oops"]
    private static let cueWindow = 4
    private static let largestCounter = 20

    /// The answer without its list markers and the draft without its spoken counters, or nil when the answer lays out no
    /// list or the draft counts none.
    /// The answer must hold every item counted: a list line each, or a sentence or an ", and" clause each in the text
    /// before or after the list ("Please add these to the board, and send the list to the team.", which a prompt often puts
    /// first). A heading that ends in a colon ("The plan for Friday:") holds none, so a list with an item left out is still
    /// refused.
    static func stripped(answer: String, draft: String) -> (answers: [String], draft: String)? {
        guard let counted = counters(in: draft), itemsHeld(by: answer) >= counted.items else { return nil }
        return ([withoutMarkers(answer), withoutMarkers(openingMovedLast(answer))], counted.draft)
    }

    /// The answer with the prose before its list put after it: a prompt often opens with the instruction the speaker
    /// gave last ("Add these to the board…" above the list), which moves those values ahead of the items' own.
    private static func openingMovedLast(_ answer: String) -> String {
        let lines = answer.components(separatedBy: "\n")
        guard let first = lines.firstIndex(where: { EvalMetrics.listItemCount($0) == 1 }), first > 0 else { return answer }
        return (lines[first...] + lines[..<first]).joined(separator: "\n")
    }

    private static func itemsHeld(by answer: String) -> Int {
        let lines = answer.components(separatedBy: "\n")
        let isItem = { (line: String) in EvalMetrics.listItemCount(line) == 1 }
        let prose = lines.filter { !isItem($0) }.joined(separator: " ")
        let pieces = Regex.replace(prose, "[^.!?;]*:\\s*", with: " ")
            .components(separatedBy: CharacterSet(charactersIn: ".!?;"))
            .flatMap { $0.components(separatedBy: ", and ") }
            .filter { $0.contains(where: \.isLetter) }
        return lines.filter(isItem).count + pieces.count
    }

    /// The answer's list lines without their "1." or bullet, when it has two list lines or more.
    static func withoutMarkers(_ answer: String) -> String {
        guard EvalMetrics.listItemCount(answer) >= 2 else { return answer }
        return Regex.replace(answer, "(?m)^[ \\t]*(?:\\d+[.)]|[-\u{2022}*])[ \\t]+", with: "")
    }

    /// The draft without the words of its counters, or nil when it has fewer than two.
    static func removingCounters(from draft: String) -> String? { counters(in: draft)?.draft }

    /// The draft without its counters and how many items they count (the last counter), or nil with fewer than two.
    private static func counters(in draft: String) -> (draft: String, items: Int)? {
        let tokens = draft.split(whereSeparator: \.isWhitespace).map(String.init)
        let keys = tokens.map { $0.trimmingCharacters(in: .punctuationCharacters).lowercased() }
        var removed = Set<Int>()
        var last = 0
        for index in keys.indices {
            guard let value = counterValue(keys[index]) else { continue }
            let next = value == last + 1
            let again = value == last && last > 0 && keys[max(0, index - cueWindow)..<index].contains(where: cues.contains)
            guard next || again, let found = counterStart(at: index, keys: keys, inList: last >= 1) else { continue }
            // A counter that only the word before it argues against ("for the version seven the pill …") counts when the
            // list goes on with the next counter after it.
            if found.soft, !continues(after: index, value: value, keys: keys) { continue }
            let start = found.start
            removed.formUnion(start...index)
            last = value
        }
        guard last >= 2 else { return nil }
        return (tokens.indices.filter { !removed.contains($0) }.map { tokens[$0] }.joined(separator: " "), last)
    }

    /// The first word of the counter at `index` ("number" before it goes with it), or nil when it is no counter there.
    /// `inList`: a list is under way, so a number that ends the item before ("… three times out of ten two the dark mode …")
    /// does not keep the next counter from being one.
    private static func counterStart(at index: Int, keys: [String], inList: Bool) -> (start: Int, soft: Bool)? {
        guard keys.indices.contains(index + 1) else { return nil }
        let after = keys[index + 1]
        guard !after.isEmpty, !isNumber(after), !notItems.contains(after) else { return nil }
        var start = index
        if index > 0, prefixes.contains(keys[index - 1]) { start = index - 1 }
        guard start > 0 else { return (start, false) }
        let before = keys[start - 1]
        // "twenty two" and "hundred two" are one number, whatever the list: never a counter after a word it joins.
        if isNumber(before), !inList || InverseTextNormalizer.parseCardinal(before + " " + keys[index]) != nil
            || Int(before) != nil && Int(keys[index]) != nil { return nil }
        let isOrdinal = Int(keys[index]) == nil && InverseTextNormalizer.parseCardinal(keys[index]) == nil
        if start == index, !isOrdinal, valueWords.contains(before) { return nil }
        return (start, start == index && !isOrdinal && determiners.contains(before))
    }

    /// The next counter of the list (`value` + 1) stands somewhere after `index`, on its own and not argued against.
    private static func continues(after index: Int, value: Int, keys: [String]) -> Bool {
        keys.indices.dropFirst(index + 1).contains { later in
            counterValue(keys[later]) == value + 1 && counterStart(at: later, keys: keys, inList: true).map { !$0.soft } == true
        }
    }

    private static func counterValue(_ key: String) -> Int? {
        if let digits = Int(key) { return (1...largestCounter).contains(digits) && !key.hasPrefix("0") ? digits : nil }
        guard !key.contains("-"), let cardinal = SpokenNumberRuns.isNumberWord(key) ? cardinalWord(key) : nil,
              let value = InverseTextNormalizer.parseCardinal(cardinal), (1...largestCounter).contains(value) else { return nil }
        return value
    }

    /// "fifth" as "five", "twentieth" as "twenty", "three" as itself.
    private static func cardinalWord(_ word: String) -> String? {
        if InverseTextNormalizer.parseCardinal(word) != nil { return word }
        let irregular = ["first": "one", "second": "two", "third": "three", "fifth": "five", "eighth": "eight", "ninth": "nine",
                         "twelfth": "twelve"]
        if let cardinal = irregular[word] { return cardinal }
        if word.hasSuffix("ieth") { return String(word.dropLast(4)) + "y" }
        if word.hasSuffix("th") { return String(word.dropLast(2)) }
        return nil
    }

    private static func isNumber(_ word: String) -> Bool {
        word.contains(where: \.isNumber) || SpokenNumberRuns.isNumberWord(word)
    }
}
