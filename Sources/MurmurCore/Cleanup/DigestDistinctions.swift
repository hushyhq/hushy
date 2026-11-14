import Foundation

/// Facts that tell two meeting-note lines apart even when most of their words match: a person's or
/// company's name, a number, a date or a time, and what the line ends on. Word overlap alone merges
/// "Pay the invoice from Acme" with "Pay the invoice from Globex" (three of four words shared) and
/// silently loses one of the two tasks; a lost action item is worse than a repeated one, so
/// `NoteDigestMerge.similar` asks `conflict` first and never merges lines this finds different.
///
/// What counts as different:
/// - **Names**: a capitalised word that is not the first of its sentence and does not appear (in any
///   case) in the other line. Title-case lines are safe: their words appear in the other line.
///   Both directions count, so "Call Priya" and "Call Priya and Tom" stay apart. A name that opens
///   the line cannot be told from a capitalised verb and is not looked at.
/// - **Numbers**: the set of numbers differs ("2 copies" and "3 copies"; "two" and "2" are equal).
/// - **Dates and times**: each line has one the other lacks ("Monday" and "Tuesday", "3 pm" and
///   "3 am"). A line that only adds one is left alone ("3 pm" and "3 pm Friday"; a line with none),
///   because the due date often moves into the separate `due` field in a later reading of the task.
/// - **Ending**: each line ends on a word the other lacks ("...about pricing", "...about shipping").
///   This is the one rule beyond names and numbers: the task's object usually comes last, and a
///   different object is a different task. It never fires when one line only adds words.
enum DigestDistinctions {
    static func conflict(_ a: String, _ b: String) -> Bool {
        if namesDiffer(a, b) { return true }
        if numbers(in: a) != numbers(in: b) { return true }
        let datesA = dates(in: a), datesB = dates(in: b)
        if !datesA.isSubset(of: datesB), !datesB.isSubset(of: datesA) { return true }
        return endsDifferently(a, b)
    }

    // MARK: - Names

    private static func namesDiffer(_ a: String, _ b: String) -> Bool {
        let namesA = names(in: a), namesB = names(in: b)
        guard !namesA.isEmpty || !namesB.isEmpty else { return false }
        let wordsA = allWords(a), wordsB = allWords(b)
        return !namesA.isSubset(of: wordsB) || !namesB.isSubset(of: wordsA)
    }

    private static func allWords(_ text: String) -> Set<String> {
        Set(text.lowercased().components(separatedBy: CharacterSet.alphanumerics.inverted).filter { !$0.isEmpty })
    }

    private static func names(in text: String) -> Set<String> {
        Set(CapitalizedNameGuard.capitalizedNames(in: text, includingSentenceInitial: false).compactMap { token -> String? in
            var name = token
            for suffix in ["'s", "\u{2019}s"] where name.hasSuffix(suffix) { name = String(name.dropLast(suffix.count)) }
            guard !name.isEmpty, name.rangeOfCharacter(from: .decimalDigits) == nil, !dateWords.contains(name) else { return nil }
            return name
        })
    }

    // MARK: - Numbers

    private static let numberWords: [String: String] = [
        "two": "2", "three": "3", "four": "4", "five": "5", "six": "6", "seven": "7", "eight": "8", "nine": "9",
        "ten": "10", "eleven": "11", "twelve": "12", "thirteen": "13", "fourteen": "14", "fifteen": "15",
        "sixteen": "16", "seventeen": "17", "eighteen": "18", "nineteen": "19", "twenty": "20", "thirty": "30",
        "forty": "40", "fifty": "50", "sixty": "60", "seventy": "70", "eighty": "80", "ninety": "90",
        "hundred": "100", "thousand": "1000", "million": "1000000",
    ]

    /// "one" is left out on purpose: it is as often a pronoun ("the one we discussed") as a count.
    private static func numbers(in text: String) -> Set<String> {
        let plain = text.replacingOccurrences(of: #"(?<=\d),(?=\d{3})"#, with: "", options: .regularExpression)
        var found = Set<String>()
        var rest = plain[...]
        while let range = rest.range(of: #"\d+(?:\.\d+)?"#, options: .regularExpression) {
            found.insert(String(rest[range]))
            rest = rest[range.upperBound...]
        }
        for word in plain.lowercased().components(separatedBy: CharacterSet.letters.inverted) {
            if let digits = numberWords[word] { found.insert(digits) }
        }
        return found
    }

    // MARK: - Dates and times

    private static let weekdays: Set<String> = [
        "monday", "tuesday", "wednesday", "thursday", "friday", "saturday", "sunday", "tues", "thurs",
    ]
    private static let months: Set<String> = [
        "january", "february", "march", "april", "june", "july", "august", "september", "october", "november",
        "december", "jan", "feb", "aug", "sept", "oct", "nov", "dec",
    ]
    private static let relativeDays: Set<String> = [
        "today", "tomorrow", "yesterday", "tonight", "morning", "afternoon", "evening", "noon", "midnight",
        "eod", "eow", "eom", "am", "pm",
    ]
    private static let dateWords: Set<String> = weekdays.union(months).union(relativeDays)
    private static let periods: Set<String> = ["week", "weekend", "month", "quarter", "year"]
    private static let periodModifiers: Set<String> = ["next", "last", "this"]

    private static func dates(in text: String) -> Set<String> {
        // "3pm" / "10:30am": split the suffix off its digits so it reads as "pm" / "am".
        let spaced = text.lowercased().replacingOccurrences(of: #"(?<=\d)(?=[ap]\.?m\b)"#, with: " ", options: .regularExpression)
            .replacingOccurrences(of: ".", with: "")
        let words = spaced.components(separatedBy: CharacterSet.letters.inverted).filter { !$0.isEmpty }
        var found = Set<String>()
        for (index, word) in words.enumerated() {
            if dateWords.contains(word) { found.insert(word) }
            if periodModifiers.contains(word), words.indices.contains(index + 1), periods.contains(words[index + 1]) {
                found.insert("\(word) \(words[index + 1])")
            }
        }
        return found
    }

    // MARK: - Ending

    private static func endsDifferently(_ a: String, _ b: String) -> Bool {
        let wordsA = NoteDigestMerge.orderedContentWords(a).map(singular), wordsB = NoteDigestMerge.orderedContentWords(b).map(singular)
        guard let tailA = wordsA.last, let tailB = wordsB.last, tailA != tailB else { return false }
        return !wordsB.contains(tailA) && !wordsA.contains(tailB)
    }

    private static func singular(_ word: String) -> String {
        word.count > 3 && word.hasSuffix("s") ? String(word.dropLast()) : word
    }
}
