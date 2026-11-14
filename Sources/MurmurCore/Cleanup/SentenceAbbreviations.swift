import Foundation

/// Abbreviations whose full stop does not end a sentence, so the word after them is not capitalized as a new
/// sentence ("at 2:45 p.m. on Thursday", "a tool, e.g. a screwdriver"). Used by `Punctuation.capitalizeSentences`.
///
/// Three kinds, because they differ in how sure the next word makes it:
/// - `continues` ("e.g.", "i.e.", "vs.", "cf.", "viz."): a sentence never ends on one, so the next word stays as it is.
/// - `time` ("a.m.", "p.m.", and "am."/"pm." after a digit): usually followed by "on Thursday", "at the office", "and ...",
///   but a sentence can end there too, so only a word that cannot open a sentence on its own (a preposition, a
///   conjunction, a day or a time word) is kept lower case. "p.m. We will start" still starts a sentence.
/// - `listEnd` ("etc."): the same, for a conjunction only ("etc. and so on").
///
/// Titles ("Dr.", "Mr.", "Mrs.", "Ms.", "Prof.") are followed by a name, which is capitalized anyway, so they need no
/// rule here.
enum SentenceAbbreviations {
    enum Kind { case continues, time, listEnd }

    private static let alwaysContinue: Set<String> = ["e.g.", "i.e.", "vs.", "cf.", "viz.", "ie.", "eg."]
    private static let meridiems: Set<String> = ["a.m.", "p.m.", "a.m", "p.m"]
    private static let bareMeridiems: Set<String> = ["am.", "pm."]

    /// Words that cannot open a sentence after a time ("6 p.m. on Thursday", "9 a.m. to 5 p.m. and then"). Weekdays
    /// are not here: they are capitalized wherever they stand.
    private static let timeContinuations: Set<String> = [
        "on", "at", "in", "to", "for", "from", "until", "till", "by", "and", "or", "but", "with", "so", "if", "because",
        "when", "which", "that", "tomorrow", "today", "tonight", "sharp", "every", "each",
    ]
    /// The ones a capital is taken off when a model wrote them after a time ("p.m. On Thursday"). A conjunction is
    /// left alone: "at 6 p.m. But we left" may be the model's own sentence break.
    private static let prepositions: Set<String> = ["on", "at", "in", "to", "for", "from", "until", "till", "by", "with"]
    private static let listContinuations: Set<String> = ["and", "or", "but"]

    /// The kind of abbreviation whose full stop is at `period` in `chars`, or nil when the word before it is not one.
    static func kind(endingAt period: Int, in chars: [Character]) -> Kind? {
        guard chars.indices.contains(period), chars[period] == "." else { return nil }
        var start = period
        while start > 0, chars[start - 1].isLetter || chars[start - 1] == "." { start -= 1 }
        let token = String(chars[start...period]).lowercased()
        if alwaysContinue.contains(token) { return .continues }
        if token == "etc." { return .listEnd }
        if meridiems.contains(token) { return .time }
        if bareMeridiems.contains(token) { return followsDigit(chars, tokenStart: start) ? .time : nil }
        // "p. m.": the second half closes a meridiem the recognizer spelled out with a space.
        if token == "m.", start >= 3, chars[start - 1] == " ", chars[start - 2] == ".",
           "ap".contains(Character(chars[start - 3].lowercased())) {
            return .time
        }
        return nil
    }

    /// "pm." is a time only straight after a number ("6 pm." / "6:30pm."); "I am. Then" is not.
    private static func followsDigit(_ chars: [Character], tokenStart: Int) -> Bool {
        var index = tokenStart - 1
        if index >= 0, chars[index] == " " { index -= 1 }
        return index >= 0 && chars[index].isNumber
    }

    /// Whether the word starting at `index` is not a new sentence after an abbreviation of this kind.
    static func keepsContinuing(_ kind: Kind, wordAt index: Int, in chars: [Character]) -> Bool {
        switch kind {
        case .continues: return true
        case .time: return timeContinuations.contains(word(at: index, in: chars))
        case .listEnd: return listContinuations.contains(word(at: index, in: chars))
        }
    }

    /// The second half of a spaced "p. m." is not a sentence start either ("p. m. on" stays "p. m. on").
    static func isSpacedMeridiemHalf(wordAt index: Int, in chars: [Character]) -> Bool {
        guard index >= 3, chars[index - 1] == " ", chars[index - 2] == ".", "ap".contains(Character(chars[index - 3].lowercased())) else {
            return false
        }
        return word(at: index, in: chars) == "m" && (index + 1 == chars.count || !chars[index + 1].isLetter)
    }

    private static func word(at index: Int, in chars: [Character]) -> String {
        var end = index
        while end < chars.count, chars[end].isLetter { end += 1 }
        return String(chars[index..<end]).lowercased()
    }

    /// Whether the word at `index` is a title-cased preposition ("On"), which a model wrote as a new sentence
    /// after a time and which is lower case here.
    static func isTitleCasedContinuation(wordAt index: Int, in chars: [Character]) -> Bool {
        guard chars[index].isUppercase else { return false }
        var end = index + 1
        while end < chars.count, chars[end].isLetter { if chars[end].isUppercase { return false }; end += 1 }
        return prepositions.contains(String(chars[index..<end]).lowercased())
    }
}

extension SentenceAbbreviations {
    private static let strayAfterTime = "(?:On|At|Until|Till|From)"

    /// "at 6 pm On Thursday" (no full stop at all): a capital preposition straight after a clock time is the model's
    /// sentence start gone wrong, not a new sentence. Only a time written with digits is touched.
    static func loweringStrayPrepositions(_ text: String) -> String {
        Regex.replace(text, "(\\d(?::\\d{2})?\\s?(?:am|pm|AM|PM|a\\.m\\.|p\\.m\\.|A\\.M\\.|P\\.M\\.))(\\s+)(\(strayAfterTime))\\b") { whole, groups in
            guard groups.count > 3 else { return whole }
            return groups[1] + groups[2] + groups[3].lowercased()
        }
    }
}
