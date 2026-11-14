import Foundation

/// Numbers read the way people say them, for the whole-transcript value checks (`IntentOutputGuard`).
///
/// The guard ablation of 2026-10-28 found the value check right on 3 of the 18 answers it refused. The other 15 were
/// words read as values: "first", "second" and "no one" in ordinary speech, "zero room" written "no room", a range said
/// with one scale word ("two to three hundred dollars" written "$200 to $300"), and an ordinal that ran into the number
/// beside it ("the first hundred pages" read as 100, "twenty twenty two third" as one number). This is a second reading
/// of the same two texts; an answer the plain reading accepts is never refused by it, and it accepts only these forms:
/// - **An ordinal from first to tenth that stands alone is set aside.** It counts as a value only next to a unit ("the
///   first floor"), a date ("the first of May", "May first") or another number ("first 100 pages", "the first to the
///   third"). Set aside, it still binds: every value the answer sets aside must be one the draft set aside too, as often,
///   so "the second" written "the 3rd" is still refused. A counting "one" ("one more chair", "one pack") stays a value.
/// - **"one" as a pronoun is no number**: "no one", "the green one", "the second one" (`NumberValueGuard`'s reading).
/// - **"zero" and "no" are the same word before the same noun**, either way round ("zero room" written "no room"), and
///   "a day" may be written "one day". Only where both texts hold the pair, word for word; "one pack" written "a pack"
///   is still refused.
/// - **"not a hundred" takes a hundred back as "not a hundred" does**: an article between "not" and the number.
/// - **An ordinal ends a number**: "twenty twenty two third" is 2022 and 3, "first hundred" is 1 and 100. "twenty first" stays one.
/// - **A range said with one scale word** ("two to three hundred", "between twenty five and thirty thousand") reads its
///   first number with the scale too, but only when the answer writes it so (200, 25,000).
/// - **A range written with a dash** ("100–120", "$600-$700") is two numbers, as "100 or 120" is, and back
///   (`readings`). A chain of three or more numbers ("555-123-4567", "2026-10-28") keeps its plain reading.
/// What it never accepts: a changed digit, a value the draft does not say, two values merged into one ("eight or maybe
/// eight thirty" written "8:30"), or a value dropped that the speaker did not take back.
struct SpokenValueReading {
    /// The draft and the answer as the value checks compare them.
    let draft: String
    let answer: String
    /// The values of the lone ordinals set aside in each, in order.
    let draftAside: [String]
    let answerAside: [String]
    /// For each value the draft set aside, whether a correction cue follows it closely ("the first no wait the second"):
    /// the speaker may have taken it back, so the answer may not hold it.
    let draftAsideTakenBack: [Bool]

    init(answer: String, draft: String) {
        var draftText = Self.notArticle(Self.withoutPronounOne(draft)), answerText = Self.withoutPronounOne(answer)
        (draftText, answerText) = Self.pairing(draft: draftText, answer: answerText)
        (draftText, draftAside, draftAsideTakenBack) = Self.settingAside(Self.ordinalBreaks(draftText), isAnswer: false)
        (answerText, answerAside, _) = Self.settingAside(Self.ordinalBreaks(answerText), isAnswer: true)
        self.draft = Self.sharingScale(draftText, answer: answerText)
        self.answer = answerText
    }

    /// Every value the answer set aside is one the draft set aside too, as many times.
    var keepsAside: Bool {
        var left = zip(draftAside, draftAsideTakenBack).filter { !$0.1 }.map(\.0)
        for value in answerAside {
            guard let index = left.firstIndex(of: value) else { return false }
            left.remove(at: index)
        }
        return true
    }

    /// Every value the answer set aside is a value the draft says, set aside or not (`CorrectionBound`'s question).
    var asideIsSaid: Bool {
        let kept = zip(draftAside, draftAsideTakenBack).filter { !$0.1 }.map(\.0)
        let said = Set(kept + SpokenNumberRuns(draft).runs.flatMap { $0 })
        return answerAside.allSatisfy(said.contains)
    }

    /// `NumberValueGuard`'s verdict on what was said and the answer, read this way too when the plain reading refuses.
    /// A list counted aloud and laid out as a list is read without its counters and list numbers (`SpokenListCounters`).
    static func valueViolation(answer: String, draft: String, corrected: Bool) -> String? {
        guard let reason = readingViolation(answer: answer, draft: draft, corrected: corrected) else { return nil }
        if let list = SpokenListCounters.stripped(answer: answer, draft: draft),
           list.answers.contains(where: { readingViolation(answer: $0, draft: list.draft, corrected: corrected) == nil }) {
            return nil
        }
        return reason
    }

    private static func readingViolation(answer: String, draft: String, corrected: Bool) -> String? {
        func check(_ answer: String, _ draft: String, _ corrected: Bool) -> String? {
            corrected ? NumberValueGuard.violationWithCorrection(answer: answer, draft: draft)
                : NumberValueGuard.violation(answer: answer, draft: draft)
        }
        guard let reason = check(answer, draft, corrected) else { return nil }
        let reading = SpokenValueReading(answer: answer, draft: draft)
        guard reading.keepsAside else { return reason }
        // "not a hundred" read as "not hundred" can take a value back where the words as said did not.
        let takesBack = corrected || SpokenNumberRuns(reading.draft).retractable.contains(true)
        for spoken in readings(reading.draft) {
            for written in readings(reading.answer) where check(written, spoken, takesBack) == nil { return nil }
        }
        return reason
    }

    /// The text as written, and with a range written with a dash between two numbers read as two numbers.
    static func readings(_ text: String) -> [String] {
        let split = Regex.replace(
            text, "(?<![\\d][-\u{2013}\u{2014}])(?<![\\d])(\\d[\\d,.]*)\\s*[-\u{2013}\u{2014}]\\s*([$\u{20AC}\u{00A3}]?\\d[\\d,.]*)(?![-\u{2013}\u{2014}]\\d)(?![\\d])",
            with: "$1 to $2")
        return split == text ? [text] : [text, split]
    }

    // MARK: Words that are no number

    private static let ordinals = ["first", "second", "third", "fourth", "fifth", "sixth", "seventh", "eighth", "ninth", "tenth"]

    /// "no one", "the green one", and an ordinal's "one" ("the second one", "the last one").
    private static func withoutPronounOne(_ text: String) -> String {
        let ordinal = (ordinals + ["last", "next", "other"]).joined(separator: "|")
        return Regex.replace(
            NumberValueGuard.withoutPronounOne(text),
            "(?i)\\b(\(ordinal))\\s+one\\b(?!\\s+(?:hundred|thousand|million|billion|point|[0-9]))") { _, parts in parts[1] }
    }

    /// "not a hundred": the article between "not" and the number does not keep the number from being taken back.
    private static func notArticle(_ text: String) -> String {
        let number = (Array(InverseTextNormalizer.allDigitWords) + Array(InverseTextNormalizer.scales.keys)).joined(separator: "|")
        return Regex.replace(text, "(?i)\\bnot\\s+(?:a|an|the)\\s+(?=(?:\(number))\\b|\\d)", with: "not ")
    }

    /// "zero room" and "no room", "one day" and "a day": where one text has one form before a noun and the other text has
    /// the other form before the same noun, the number word is read as the article.
    private static func pairing(draft: String, answer: String) -> (String, String) {
        var draft = draft, answer = answer
        draft = paired(draft, number: "zero", article: "no", other: answer)
        for number in ["zero", "one", "1"] {
            answer = paired(answer, number: number, article: number == "zero" ? "no" : "a|an", other: draft)
        }
        return (draft, answer)
    }

    private static func paired(_ text: String, number: String, article: String, other: String) -> String {
        Regex.replace(text, "(?i)\\b\(number)\\s+([a-z][a-z'-]*)\\b") { original, parts in
            let noun = NSRegularExpression.escapedPattern(for: parts[1])
            guard Regex.firstMatch(other, "(?i)\\b(?:\(article))\\s+\(noun)\\b") != nil else { return original }
            return (number == "zero" ? "no " : "a ") + parts[1]
        }
    }

    // MARK: Ordinals

    /// A comma between an ordinal and a number beside it, so each is read alone: "twenty twenty two third" is 2022 and 3,
    /// "first hundred" is 1 and 100. A tens word and an ordinal ("twenty first") stay one number.
    private static func ordinalBreaks(_ text: String) -> String {
        var tokens = text.split(whereSeparator: \.isWhitespace).map(String.init)
        guard tokens.count > 1 else { return text }
        for index in tokens.indices where ordinals.contains(core(tokens[index])) {
            if index > 0, !endsWithPunctuation(tokens[index - 1]), isNumber(core(tokens[index - 1])),
               InverseTextNormalizer.tens[core(tokens[index - 1])] == nil {
                tokens[index - 1] += ","
            }
            if index + 1 < tokens.count, !endsWithPunctuation(tokens[index]), isNumber(core(tokens[index + 1])) {
                tokens[index] += ","
            }
        }
        return tokens.joined(separator: " ")
    }

    /// The text with every lone ordinal put out of the way, and their values. On the answer side a written ordinal ("the
    /// 1st") is read the same way; a list number at the start of a line is layout and stays.
    private static func settingAside(_ text: String, isAnswer: Bool) -> (String, [String], [Bool]) {
        var aside: [String] = []
        var takenBack: [Bool] = []
        let lines = text.components(separatedBy: "\n").map { line -> String in
            var tokens = line.split(separator: " ", omittingEmptySubsequences: false).map(String.init)
            let cores = tokens.map(core)
            for index in tokens.indices {
                guard let value = asideValue(cores[index], isAnswer: isAnswer),
                      !(isAnswer && isListMarker(tokens, at: index)),
                      !bindsToAValue(cores, at: index) else { continue }
                aside.append(value)
                takenBack.append(cueFollows(cores, after: index))
                tokens[index] = "_" + trailingPunctuation(tokens[index])
            }
            return tokens.joined(separator: " ")
        }
        return (lines.joined(separator: "\n"), aside, takenBack)
    }

    /// The words that take something back (`ModelHints.correctionCues`) within the six words after `index`.
    private static func cueFollows(_ cores: [String], after index: Int) -> Bool {
        let window = " " + cores[(index + 1)...].prefix(6).joined(separator: " ") + " "
        return ModelHints.correctionCues.contains { window.contains(" \($0) ") }
    }

    private static func asideValue(_ word: String, isAnswer: Bool) -> String? {
        if let index = ordinals.firstIndex(of: word) { return String(index + 1) }
        guard isAnswer else { return nil }
        guard let match = Regex.firstMatch(word, "^(10|[1-9])(?:st|nd|rd|th)$"), let digits = match.string(at: 1, in: word) else { return nil }
        return digits
    }

    private static func isListMarker(_ tokens: [String], at index: Int) -> Bool {
        tokens[..<index].allSatisfy { $0.isEmpty } && Regex.firstMatch(tokens[index], "^\\d+[.)]$") != nil
    }

    /// Next to a unit, a date or another number, an ordinal is a value: "the first floor", "the first
    /// of May", "May first", "the first to the third", "first 100 pages".
    private static func bindsToAValue(_ cores: [String], at index: Int) -> Bool {
        func word(_ offset: Int) -> String? {
            let at = index + offset
            return cores.indices.contains(at) ? cores[at] : nil
        }
        for side in [-1, 1] {
            guard let near = word(side) else { continue }
            if isNumber(near) || units.contains(near) || CorrectionBound.calendarNames.contains(near) { return true }
            // "one or two", "the first to third": a range connector and a number behind it.
            if rangeConnectors.contains(near), let far = word(2 * side), isNumber(far) { return true }
            // "the first of May", "the first of the month", "Monday the first".
            if near == "of", let far = word(2 * side), isDate(far) || far == "the" && word(3 * side).map(isDate) == true { return true }
            if near == "the", let far = word(2 * side), side < 0, CorrectionBound.calendarNames.contains(far) { return true }
        }
        return false
    }

    private static func isDate(_ word: String) -> Bool {
        CorrectionBound.calendarNames.contains(word) || ["month", "year", "week", "quarter"].contains(word)
    }

    /// A word that is a number beside an ordinal: digits, or a number word that is not itself an ordinal or "one".
    private static func isNumber(_ word: String) -> Bool {
        if word.contains(where: \.isNumber) { return Regex.firstMatch(word, "^[$\u{20AC}\u{00A3}]?\\d") != nil }
        guard word != "one", !ordinals.contains(word) else { return false }
        return SpokenNumberRuns.isNumberWord(word) && InverseTextNormalizer.parseCardinal(word) != nil
            || InverseTextNormalizer.scales[word] != nil
    }

    private static let rangeConnectors: Set<String> = ["or", "to", "and", "through", "till", "until"]

    /// Nouns a spoken count or ordinal is a value of.
    private static let units: Set<String> = [
        "second", "seconds", "minute", "minutes", "hour", "hours", "day", "days", "night", "nights", "week", "weeks",
        "month", "months", "year", "years", "quarter", "quarters", "half", "time", "times", "percent", "dollar", "dollars",
        "euro", "euros", "pound", "pounds", "cent", "cents", "buck", "bucks", "floor", "place", "page", "pages", "chapter",
        "row", "round", "grade", "lap", "inning", "mile", "miles", "kilometer", "kilometers", "kilo", "kilos", "meter",
        "meters", "gig", "gigs", "person", "people", "hundred", "thousand", "million", "billion",
    ]

    // MARK: Ranges said with one scale word

    /// "two to three hundred dollars" as "two hundred, to three hundred dollars" when the answer writes 200; likewise
    /// "between twenty five and thirty thousand" when it writes 25,000. The comma keeps "and" from joining the two.
    private static func sharingScale(_ draft: String, answer: String) -> String {
        var tokens = draft.split(separator: " ", omittingEmptySubsequences: false).map(String.init)
        let cores = tokens.map(core)
        let written = Set(SpokenNumberRuns(answer).runs.flatMap { $0 })
        for scaleIndex in cores.indices {
            guard let scale = InverseTextNormalizer.scales[cores[scaleIndex]] else { continue }
            let second = numberWords(endingBefore: scaleIndex, in: cores, tokens: tokens)
            guard let secondStart = second, secondStart >= 2, rangeConnectors.contains(cores[secondStart - 1]),
                  !endsWithPunctuation(tokens[secondStart - 1]),
                  let firstStart = numberWords(endingBefore: secondStart - 1, in: cores, tokens: tokens),
                  let first = InverseTextNormalizer.parseCardinal(cores[firstStart..<(secondStart - 1)].joined(separator: " ")),
                  let last = InverseTextNormalizer.parseCardinal(cores[secondStart..<scaleIndex].joined(separator: " ")),
                  first < last, last < 1_000 else { continue }
            let (product, overflow) = first.multipliedReportingOverflow(by: scale)
            guard !overflow, written.contains(String(product)) else { continue }
            tokens[secondStart - 2] += " " + cores[scaleIndex] + ","
        }
        return tokens.joined(separator: " ")
    }

    /// The start of the number words (no scale word, nothing between them) that end right before `end`, or nil.
    private static func numberWords(endingBefore end: Int, in cores: [String], tokens: [String]) -> Int? {
        var start = end
        while start > 0, InverseTextNormalizer.allDigitWords.contains(cores[start - 1]), !endsWithPunctuation(tokens[start - 1]) {
            start -= 1
        }
        return start < end ? start : nil
    }

    // MARK: Tokens

    private static func core(_ token: String) -> String {
        token.trimmingCharacters(in: .punctuationCharacters.subtracting(CharacterSet(charactersIn: "$\u{20AC}\u{00A3}"))).lowercased()
    }

    private static func endsWithPunctuation(_ token: String) -> Bool {
        token.last.map { ",.;:!?)".contains($0) } ?? false
    }

    private static func trailingPunctuation(_ token: String) -> String {
        String(token.reversed().prefix { ",.;:!?)\"'".contains($0) }.reversed())
    }
}
