import Foundation

/// One word of a spoken date phrase with its position in the original text, so the parser can
/// hand back the exact source phrase it consumed.
struct DateToken: Sendable, Equatable {
    /// Lowercased, trailing dots dropped ("p.m." → "p.m").
    let text: String
    let range: Range<String.Index>
}

/// Words, numbers and names the spoken-date parser understands. Kept apart from the grammar
/// (`RelativeDateParser`) so the vocabulary is easy to read and extend.
enum SpokenDateLexicon {
    // MARK: Tokens

    /// Splits `text` into alphanumeric runs. ':' '/' '.' and '\'' stay inside a token when a
    /// letter or digit follows ("3:30", "12/10", "p.m", "o'clock"); '-' only between digits
    /// ("2026-10-12"), so "twenty-five" is two words.
    static func tokens(in text: String) -> [DateToken] {
        var tokens: [DateToken] = []
        var index = text.startIndex
        while index < text.endIndex {
            guard text[index].isLetter || text[index].isNumber else {
                index = text.index(after: index)
                continue
            }
            let start = index
            var end = text.index(after: index)
            while end < text.endIndex {
                let character = text[end]
                if character.isLetter || character.isNumber {
                    end = text.index(after: end)
                    continue
                }
                let next = text.index(after: end)
                guard next < text.endIndex, text[next].isLetter || text[next].isNumber else { break }
                let joins = ":/.'’".contains(character)
                    || (character == "-" && text[text.index(before: end)].isNumber && text[next].isNumber)
                guard joins else { break }
                end = next
            }
            tokens.append(DateToken(text: text[start..<end].lowercased(), range: start..<end))
            index = end
        }
        return tokens
    }

    // MARK: Numbers

    static let unitWords: [String: Int] = [
        "zero": 0, "oh": 0, "o": 0, "one": 1, "two": 2, "three": 3, "four": 4, "five": 5, "six": 6,
        "seven": 7, "eight": 8, "nine": 9, "ten": 10, "eleven": 11, "twelve": 12, "thirteen": 13,
        "fourteen": 14, "fifteen": 15, "sixteen": 16, "seventeen": 17, "eighteen": 18, "nineteen": 19,
    ]
    static let tensWords: [String: Int] = ["twenty": 20, "thirty": 30, "forty": 40, "fifty": 50, "sixty": 60, "ninety": 90]

    /// A whole number at `index` (digits, "nine", "twenty five"), with the index after it.
    /// "o"/"oh" only count as zero inside a clock minute ("four oh five"), never on their own.
    static func number(_ tokens: [DateToken], _ index: Int) -> (value: Int, next: Int)? {
        guard index < tokens.count else { return nil }
        let word = tokens[index].text
        if !word.isEmpty, word.allSatisfy(\.isNumber) { return Int(word).map { ($0, index + 1) } }
        if let tens = tensWords[word] {
            if index + 1 < tokens.count, let unit = unitWords[tokens[index + 1].text], (1...9).contains(unit),
               !["o", "oh"].contains(tokens[index + 1].text) {
                return (tens + unit, index + 2)
            }
            return (tens, index + 1)
        }
        if let unit = unitWords[word], !["o", "oh"].contains(word) { return (unit, index + 1) }
        return nil
    }

    // MARK: Ordinals

    static let ordinalWords: [String: Int] = [
        "first": 1, "second": 2, "third": 3, "fourth": 4, "fifth": 5, "sixth": 6, "seventh": 7, "eighth": 8,
        "ninth": 9, "tenth": 10, "eleventh": 11, "twelfth": 12, "thirteenth": 13, "fourteenth": 14,
        "fifteenth": 15, "sixteenth": 16, "seventeenth": 17, "eighteenth": 18, "nineteenth": 19,
        "twentieth": 20, "thirtieth": 30,
    ]

    /// A day-of-month ordinal at `index` ("10th", "22nd", "tenth", "twenty first").
    static func ordinal(_ tokens: [DateToken], _ index: Int) -> (value: Int, next: Int)? {
        guard index < tokens.count else { return nil }
        let word = tokens[index].text
        for suffix in ["st", "nd", "rd", "th"] where word.hasSuffix(suffix) {
            let digits = word.dropLast(2)
            if !digits.isEmpty, digits.allSatisfy(\.isNumber), let value = Int(digits), (1...31).contains(value) {
                return (value, index + 1)
            }
        }
        if let tens = tensWords[word], [20, 30].contains(tens), index + 1 < tokens.count,
           let unit = ordinalWords[tokens[index + 1].text], (1...9).contains(unit), tens + unit <= 31 {
            return (tens + unit, index + 2)
        }
        if let value = ordinalWords[word] { return (value, index + 1) }
        return nil
    }

    // MARK: Names

    static let months: [String: Int] = [
        "january": 1, "jan": 1, "february": 2, "feb": 2, "march": 3, "april": 4, "apr": 4, "may": 5,
        "june": 6, "jun": 6, "july": 7, "jul": 7, "august": 8, "aug": 8, "september": 9, "sep": 9,
        "sept": 9, "october": 10, "oct": 10, "november": 11, "nov": 11, "december": 12, "dec": 12,
    ]

    /// Calendar weekday numbers (1 = Sunday). Full names only: "sat", "sun", "wed" are words.
    static let weekdays: [String: Int] = [
        "sunday": 1, "monday": 2, "tuesday": 3, "wednesday": 4, "thursday": 5, "friday": 6, "saturday": 7,
    ]

    static let meridiems: [String: Bool] = ["am": false, "a.m": false, "pm": true, "p.m": true]

    // MARK: Glue

    /// Words that may sit between the pieces of one date phrase ("tomorrow *at* 9", "the 7th *of*
    /// november", "tomorrow *itself*") without breaking it.
    static let connectors: Set<String> = ["at", "on", "by", "the", "of", "around", "about", "itself", "only", "this", "in"]

    /// Prepositions a clock time may open with; kept in the source phrase ("at 5 pm", "by 5").
    /// Not "on": "on 1" is "a 1 on 1", not one o'clock.
    static let leadIns: Set<String> = ["at", "by", "around", "before", "till", "until", "from", "@"]

    // MARK: Self-corrections

    static let correctionWords: Set<String> = ["no", "sorry", "actually", "correction", "wait", "rather", "instead"]
    static let correctionPairs: [[String]] = [["i", "mean"], ["make", "it"], ["scratch", "that"], ["change", "it", "to"]]

    /// Whether a self-correction marker ends at token `index` ("at 3 *no* 4", "at 8 *i mean* 9").
    static func correctionEnds(at index: Int, in tokens: [DateToken]) -> Bool {
        guard tokens.indices.contains(index) else { return false }
        if correctionWords.contains(tokens[index].text) { return true }
        return correctionPairs.contains { pair in
            let start = index - pair.count + 1
            return start >= 0 && tokens[start...index].map(\.text) == pair
        }
    }
}
