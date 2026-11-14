import Foundation

/// Spoken command-line flags: "dash l a" -> `-la`, "dash dash short" -> `--short`, a bare
/// "dash dash" -> `--`. Works on the lowercased word tokens of a code line.
///
/// - Short flag: "dash" followed by one to four single spoken letters (`-rn`, `-d`). Anything after
///   the letters that is a word stays a separate argument ("dash d api" -> `-d api`).
/// - Long flag: "dash dash" followed by one word (`--mode`), or by a spelling from the closed table
///   `CodeSymbolWords.longFlagCompounds` (`--save-dev`, `--dry-run`). A compound the table does not
///   list is written as a one-word flag plus an argument; the speaker can say "kebab case" instead.
/// - Bare `--` ends the options: "dash dash dash dash mode" is `-- --mode`, and a "dash dash" that
///   ends the line or is followed by a path ("src slash parser dot ts") is the bare separator.
///
/// - Numeric flag: "dash" and a digit word after a command word is `-9`, `-2` ("kill dash nine").
///   Needs a word before it that is not a determiner or an adjective of the noun, and no counted unit
///   after the number ("a dash nine times", "the hundred meter dash two laps" are the race).
///
/// "dash" after a determiner or an adjective ("a dash of salt", "the em dash") is the noun.
enum CodeFlags {
    /// A counted unit right after the number: the number counts those things, it is not a flag value.
    private static let countedUnits: Set<String> = CodeSymbolWords.unitWords.union([
        "mile", "miles", "meter", "meters", "metre", "metres", "foot", "feet", "inch", "inches", "yard", "yards",
        "lap", "laps", "step", "steps", "point", "points", "degree", "degrees", "kilometers", "kilometres",
        "round", "rounds", "more", "of", "or", "and",
    ])

    private static let nounLeaders: Set<String> = CodeSymbolWords.determiners.union([
        "em", "en", "one", "quick", "little", "long", "short", "mad", "final", "last", "first", "big", "hundred",
    ])
    private static let maxShortFlagLetters = 4

    /// The flag text and how many tokens it consumed for a "dash" at `index`, or nil to leave it a word.
    static func flag(at index: Int, in lower: [String], previous: String?) -> (text: String, consumed: Int)? {
        guard lower[index] == "dash" else { return nil }
        if let previous, nounLeaders.contains(previous) { return nil }
        if index + 1 < lower.count, lower[index + 1] == "dash" {
            return doubleDash(Array(lower[(index + 2)...]))
        }
        if let numeric = numericFlag(lower, at: index, previous: previous) { return numeric }
        return shortFlag(lower, from: index + 1)
    }

    /// True when the words (after a leading "dash dash") begin with a known long-flag spelling.
    static func startsKnownFlag(_ words: [String]) -> Bool {
        compound(in: words) != nil
    }

    private static func doubleDash(_ rest: [String]) -> (text: String, consumed: Int)? {
        guard let first = rest.first else { return ("--", 2) }
        if first == "dash", rest.count > 1, rest[1] == "dash" { return ("--", 2) }
        if rest.count > 1, ["slash", "dot"].contains(rest[1]) { return ("--", 2) }
        if let words = compound(in: rest) {
            return ("--" + words.joined(separator: "-"), 2 + words.count)
        }
        if CodeSymbolWords.functionWords.contains(first) { return nil }
        if isFlagWord(first) { return ("--" + first, 3) }
        return CodeTokens.isPathLike(first) ? ("--", 2) : nil
    }

    /// "kill dash nine" -> `-9`: needs a word before the "dash" (a bare "dash nine" opens a sentence)
    /// and no counted unit after the digit.
    private static func numericFlag(_ lower: [String], at index: Int, previous: String?) -> (text: String, consumed: Int)? {
        guard previous != nil, index + 1 < lower.count else { return nil }
        let word = lower[index + 1]
        guard let digit = CodeSymbolWords.digitWords[word] ?? (word.count == 1 && CodeTokens.isDigits(word) ? word : nil)
        else { return nil }
        if index + 2 < lower.count, countedUnits.contains(lower[index + 2]) { return nil }
        return ("-" + digit, 2)
    }

    private static func shortFlag(_ lower: [String], from start: Int) -> (text: String, consumed: Int)? {
        var letters = ""
        var position = start
        while position < lower.count, letters.count < maxShortFlagLetters,
              lower[position].count == 1, lower[position].first?.isLetter == true {
            letters += lower[position]
            position += 1
        }
        guard !letters.isEmpty else { return nil }
        if position < lower.count, lower[position] == "of" { return nil }
        return ("-" + letters, 1 + letters.count)
    }

    private static func compound(in words: [String]) -> [String]? {
        CodeSymbolWords.longFlagCompounds.first { words.starts(with: $0) }
    }

    private static func isFlagWord(_ word: String) -> Bool {
        guard let first = word.first, first.isLetter, first.isASCII else { return false }
        return word.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber) }
    }
}
