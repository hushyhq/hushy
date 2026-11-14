import Foundation

/// The counters of a spoken list ("one update the readme two merge the prs three ..."), found so that a model which writes
/// the items as a sentence or as paragraphs, without the numbers, is not refused for "changing digits".
///
/// A run of counters is read from the transcript's words only, and is deliberately narrow:
/// - it starts at "one" (or "first") and goes on consecutively (two, three, ... or second, third, ...), at least two long;
/// - the counters are the words exactly as said: never the recogniser's "to", "too" or "for". In prose nothing proves a
///   "to" was a counter, and reading it as one hides two steps turned into one step with a purpose ("X to Y");
/// - a counter is a word on its own: it is not beside another number word or a digit ("twenty one", "one hundred"), is
///   not after a determiner ("the one"; "the first ... the second" is fine), and is not followed by a unit, a quantity word
///   or "of" ("two weeks", "one of", "the first of May");
/// - each counter is followed by item words: at least three before the next counter, at least two after the last.
/// Every other number stays in the draft, so a real value that is dropped or changed is still refused.
enum FoldedCounters {
    private static let cardinals = ["one", "two", "three", "four", "five", "six", "seven", "eight", "nine", "ten"]
    private static let ordinals = ["first", "second", "third", "fourth", "fifth", "sixth", "seventh", "eighth", "ninth", "tenth"]
    private static let determiners: Set<String> = [
        "the", "this", "that", "these", "those", "which", "another", "each", "every", "any", "a", "an", "my", "your", "our",
        "their", "his", "her", "its", "no", "only", "just", "number", "step", "item", "option", "point", "page", "chapter", "section",
    ]
    private static let notItems: Set<String> = [
        "of", "more", "other", "another", "thing", "things", "half", "hundred", "thousand", "million", "billion", "point",
        "second", "seconds", "minute", "minutes", "hour", "hours", "day", "days", "week", "weeks", "month", "months",
        "year", "years", "dollar", "dollars", "euro", "euros", "pound", "pounds", "cent", "cents", "percent", "times", "time",
        "mile", "miles", "kilometre", "kilometres", "kilometer", "kilometers", "metre", "metres", "meter", "meters",
        "gram", "grams", "kilo", "kilos", "kg", "km", "am", "pm", "oclock", "o'clock", "x", "per",
    ]
    private static let minimumItemWords = 3
    private static let minimumLastItemWords = 2

    /// The draft without the words of its counter run, or nil when it has none.
    static func removing(from draft: String) -> String? {
        let tokens = draft.split(whereSeparator: \.isWhitespace).map(String.init)
        let keys = tokens.map(key)
        var best: Set<Int> = []
        for family in [cardinals, ordinals] {
            for start in keys.indices where keys[start] == family[0] {
                let run = run(from: start, keys: keys, spoken: family)
                if run.count > best.count { best = run }
            }
        }
        guard best.count >= 2 else { return nil }
        return tokens.indices.filter { !best.contains($0) }.map { tokens[$0] }.joined(separator: " ")
    }

    private static func key(_ token: String) -> String {
        token.trimmingCharacters(in: .punctuationCharacters).lowercased()
    }

    private static func isNumber(_ word: String) -> Bool {
        word.contains(where: \.isNumber) || SpokenNumberRuns.isNumberWord(word)
    }

    private static func run(from start: Int, keys: [String], spoken: [String]) -> Set<Int> {
        var counted: Set<Int> = []
        var last = start
        let isOrdinal = spoken[0] == ordinals[0]
        guard isCounter(at: start, keys: keys, ordinal: isOrdinal) else { return [] }
        counted.insert(start)
        var number = 2
        while number <= spoken.count {
            guard let next = keys.indices.dropFirst(last + 1).first(where: { index in
                keys[index] == spoken[number - 1] && isCounter(at: index, keys: keys, ordinal: isOrdinal)
                    && index - last - 1 >= minimumItemWords
            }) else { break }
            counted.insert(next)
            last = next
            number += 1
        }
        // The last item needs words too, and a run of one counter is no list.
        while counted.count >= 2, let end = counted.max(), keys.count - end - 1 < minimumLastItemWords {
            counted.remove(end)
        }
        return counted.count >= 2 ? counted : []
    }

    /// A counter stands alone: no number beside it, no determiner before it, and an item word after it.
    private static func isCounter(at index: Int, keys: [String], ordinal: Bool) -> Bool {
        if index > 0, isNumber(keys[index - 1]) || !ordinal && determiners.contains(keys[index - 1]) { return false }
        guard keys.indices.contains(index + 1) else { return false }
        let after = keys[index + 1]
        return !after.isEmpty && !isNumber(after) && !notItems.contains(after)
    }
}
