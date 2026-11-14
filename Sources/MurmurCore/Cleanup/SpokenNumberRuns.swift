import Foundation

/// The numbers a text says, read as runs of numbers that sit next to each other, so two forms of the same
/// number compare equal and a number made of pieces of two others does not (`CorrectionBound`).
///
/// A segment is one whole number as written or spoken: "27", "27th", "twenty seventh", "4,200" and "forty two
/// hundred" are one segment each, and so is the "20 sixth" the rules leave of "twenty sixth". A run is segments
/// with nothing between them ("forty forty four" is the run 40, 44; "4 1 6" is 4, 1, 6). Words that only join
/// number words ("and" after a hundred, "point", "dot", "colon") stay inside a run; any other word, a comma, a
/// full stop or a line break ends it. Digit groups joined by a dot or a colon ("2.4.9", "3:30") are one run. A
/// hyphen or a slash between digits ("10-15", "555-123-4567") keeps the run but marks a soft break: the run may
/// read as a whole or piece by piece. "dollars" (and "and") between two numbers keeps them in one run ("five
/// dollars fifty" is the run 5, 50, as "$5.50" is), so the amount reads the same either way.
///
/// Three forms are read by what they stand for and not by their digits: "half" (written 0.5, .5, 1/2), a month name
/// (written as its number in a slash or ISO date), and a one-digit number written with a leading zero.
///
/// What a run of the answer may be, in `CorrectionBound`: the digits of its segments, written one after the other,
/// are
/// - the digits of a stretch of one draft run: any form of the number, a regrouping ("555 123" for "five five five
///   one two three", "2024" for "twenty twenty four"), or a part left out; or
/// - the front of one draft run followed by the whole run after it, or that whole run followed by the end of the
///   run before it, when a correction cue stands between the two runs: the shapes a correction makes when its
///   replacement takes the place of the end or of the front of a number ("one dot forty two no sorry forty four" becomes "one dot forty four", "nine thirty no wait ten"
///   becomes "ten thirty"). The front and the end are proper parts: the earlier number is the one retracted, so
///   its whole is never put beside the other number ("room 4 no wait room 6" is not "room 46").
/// Anything else joins pieces the speaker never put together ("forty forty four" when they said "forty two" and,
/// after the correction, "forty four") and is a number they did not say.
struct SpokenNumberRuns {
    /// Each run as the digit string of each of its segments.
    let runs: [[String]]
    /// For each run, the segment indices where a hyphen or a slash starts a new piece.
    let softBreaks: [[Int]]
    /// For each run, whether a correction cue stands between it and the run before it.
    let cueBefore: [Bool]
    /// For each run, whether the speaker may have taken it back: a correction cue anywhere after it ("five
    /// hundred dollars, make it a hundred euros", "we need twelve licences … I mean we need sixty"), or "not" just
    /// before it ("not five, we need eight"). The replacement need not be a number.
    let retractable: [Bool]
    /// Digit strings the text stands for without writing them: "half", the number of a month name.
    let impliedReadings: Set<String>
    /// Whether the text says "half", which "1/2" writes.
    let saysHalf: Bool

    init(_ written: String) {
        // "half past ten" is 10:30 and "two point five million" 2,500,000: read spoken forms by value.
        // "on second thought" is a correction, not a count: read it as one.
        let text = SpokenValueForms.normalize(
            Regex.replace(written, "(?i)\\b(?:on\\s+)?second\\s+thoughts?\\b", with: "rather"))
        var builder = Builder()
        for line in text.split(whereSeparator: \.isNewline) {
            builder.add(line)
        }
        (runs, softBreaks, cueBefore, retractable) = builder.finish()

        impliedReadings = Self.implied(by: text)
        saysHalf = text.split(whereSeparator: { !$0.isLetter }).contains { $0.lowercased() == "half" }
    }

    private static func implied(by text: String) -> Set<String> {
        let words = text.split(whereSeparator: \.isWhitespace).map { $0.trimmingCharacters(in: .punctuationCharacters).lowercased() }
        func isNumber(_ index: Int) -> Bool {
            words.indices.contains(index) && (words[index].allSatisfy(\.isNumber) && !words[index].isEmpty || isNumberWord(words[index]))
        }
        var readings: Set<String> = []
        for (index, word) in words.enumerated() {
            if word == "half" { readings.formUnion(["5", "05"]) }
            // A month name stands for its number only beside a day: "March 6", "March the sixth", "the sixth of March".
            // "may I" and "march on" are not dates.
            guard let month = InverseTextNormalizer.months.firstIndex(where: { $0.lowercased() == word }) else { continue }
            let besideADay = isNumber(index + 1) || words.indices.contains(index + 1) && words[index + 1] == "the" && isNumber(index + 2)
                || isNumber(index - 1) || index >= 2 && words[index - 1] == "of" && isNumber(index - 2)
            if besideADay { readings.formUnion([String(month + 1), String(format: "%02d", month + 1)]) }
        }
        return readings
    }

    /// True when every run of `self` reads as something `draft` said, as a whole or piece by piece.
    func isSaid(by draft: SpokenNumberRuns) -> Bool {
        let reference = Reference(draft)
        return runs.indices.allSatisfy { index in
            let run = runs[index]
            // "1/2" is half: the 1 and the 2 are pieces of a fraction, not numbers on their own.
            if draft.saysHalf, run == ["1", "2"], softBreaks[index] == [1] { return true }
            if reference.reads(run.joined()) { return true }
            let cuts = [0] + softBreaks[index] + [run.count]
            let pieces = zip(cuts, cuts.dropFirst()).map { run[$0..<$1].joined() }
            return pieces.count > 1 && pieces.allSatisfy(reference.reads)
        }
    }

    /// What a draft says, as the digit strings an answer's number may be made of.
    private struct Reference {
        /// Longest digit string kept as a reading; a longer one must be a part of a run's digits.
        static let longestReading = 24
        var readings: Set<String> = []
        var wholes: [String: [Int]] = [:]
        var fronts: [String: [Int]] = [:]
        var ends: [String: [Int]] = [:]
        var texts: [String] = []
        let cueBefore: [Bool]

        init(_ draft: SpokenNumberRuns) {
            cueBefore = draft.cueBefore
            readings = draft.impliedReadings
            for (index, run) in draft.runs.enumerated() {
                wholes[run.joined(), default: []].append(index)
                texts.append(run.joined())
                for start in run.indices {
                    var digits = ""
                    for segment in run[start...] {
                        digits += segment
                        guard digits.count <= Self.longestReading else { break }
                        readings.insert(digits)
                    }
                }
                if run.count == 1, run[0].count == 1 { readings.insert("0" + run[0]) }
                for cut in run.indices.dropLast() { fronts[run[...cut].joined(), default: []].append(index) }
                for cut in run.indices.dropFirst() { ends[run[cut...].joined(), default: []].append(index) }
            }
        }

        /// A front or end in run `earlier` and a whole run right after it, with a correction cue between the two.
        private func pairedAcrossACue(_ earlier: [Int]?, _ later: [Int]?) -> Bool {
            guard let earlier, let later else { return false }
            return earlier.contains { index in later.contains(index + 1) && cueBefore[index + 1] }
        }

        func reads(_ digits: String) -> Bool {
            if digits.count > Self.longestReading { return texts.contains { $0.contains(digits) } }
            if readings.contains(digits) { return true }
            return digits.indices.dropFirst().contains { split in
                let head = String(digits[..<split]), tail = String(digits[split...])
                return pairedAcrossACue(fronts[head], wholes[tail]) || pairedAcrossACue(ends[tail], wholes[head])
            }
        }
    }

    /// Whether `word` is a number word or an ordinal ("twenty", "eighth"), for callers that must not read it as a name.
    static func isNumberWord(_ word: String) -> Bool {
        let parts = word.lowercased().split(separator: "-").map(String.init)
        return !parts.isEmpty && parts.allSatisfy { Builder.cardinalWord($0) != nil }
    }
}

// MARK: - Reading a line

private extension SpokenNumberRuns {
    struct Token {
        enum Kind {
            /// Digit groups of one numeral; `joined` when they are one run ("2.4.9"), else each stands alone ("Q3").
            case digits([String], joined: Bool, decimal: String?)
            /// Number words as cardinals; `ordinalUnit` when the one word was an ordinal from first to ninth.
            case words([String], ordinalUnit: Bool)
            case spokenZero
            case joiner
            case currency
            case conjunction
            case other
        }

        let kind: Kind
        var text = ""
        let startsRun: Bool
        let endsRun: Bool
        var softBreakBefore = false

        var isNumber: Bool {
            switch kind {
            case .digits, .words: true
            default: false
            }
        }
    }

    struct Builder {
        private var runs: [[String]] = []
        private var breaks: [[Int]] = []
        private var run: [String] = []
        private var runBreaks: [Int] = []
        /// The last two segments are the whole and fraction of one decimal numeral ("2.5") a scale word may multiply.
        private var lastDecimal: String?
        private var words: [String] = []
        /// The last segment came from a plain integer numeral, so a scale word or an ordinal unit can join it.
        private var lastIsPlainNumeral = false
        private var cues: [Bool] = []
        private var retracts: [Bool] = []
        /// "not" stood just before the run now being built.
        private var startNot = false
        /// The words since the last run, and whether a cue was among them when the run now being built began.
        private var gap: [String] = []
        private var startCue = false
        /// A "dollars" just kept a run open, so an "and" before the cents belongs to it.
        private var bridgeAnd = false

        mutating func add(_ line: Substring) {
            markRetractedByGap()
            gap = []
            let tokens = line.split(whereSeparator: \.isWhitespace).flatMap(Self.tokens)
            for (index, token) in tokens.enumerated() {
                let next = index + 1 < tokens.count ? tokens[index + 1] : nil
                if token.startsRun { endRun() }
                if token.softBreakBefore {
                    flushWords()
                    if !run.isEmpty { runBreaks.append(run.count) }
                }
                add(token, previous: index > 0 ? tokens[index - 1] : nil, next: next)
                if token.endsRun { endRun() }
            }
            endRun()
        }

        mutating func finish() -> (runs: [[String]], softBreaks: [[Int]], cueBefore: [Bool], retractable: [Bool]) {
            endRun()
            markRetractedByGap()
            gap = []
            // A cue after a later run comes after this one too.
            var cueLater = false
            var retractable = retracts
            for index in retractable.indices.reversed() {
                cueLater = cueLater || cueAfter[index]
                retractable[index] = retractable[index] || cueLater
            }
            return (runs, breaks, cues, retractable)
        }

        /// Whether the words after each run, up to the next, hold a correction cue.
        private var cueAfter: [Bool] = []

        /// The words after the last run hold a correction cue: the speaker may have taken it back.
        private mutating func markRetractedByGap() {
            guard !cueAfter.isEmpty, Self.hasCueAhead(gap) else { return }
            cueAfter[cueAfter.count - 1] = true
        }

        /// More ways to take back what was just said: "strike that", "let me correct that", "that's not right", "I misspoke".
        private static let spokenRetractions = [
            "strike that", "correct that", "not right", "that's wrong", "that is wrong", "i misspoke", "mean to say", "meant to say",
            "disregard that", "ignore that",
        ]

        private static func hasCueAhead(_ words: [String]) -> Bool {
            let text = words.joined(separator: " ").lowercased()
            return (ModelHints.correctionCues + ["my mistake", "my bad", "hold on", "make it", "let's say", "or rather", "second thought", "second thoughts"]
                + Self.spokenRetractions)
                .contains { cue in
                    text.range(of: "\\b\(NSRegularExpression.escapedPattern(for: cue))\\b", options: .regularExpression) != nil
                }
        }

        private mutating func add(_ token: Token, previous: Token?, next: Token?) {
            let bridged = bridgeAnd
            bridgeAnd = false
            if run.isEmpty, words.isEmpty, token.isNumber {
                startCue = Self.hasCue(gap)
                markRetractedByGap()
                startNot = gap.last?.lowercased().trimmingCharacters(in: .punctuationCharacters) == "not"
                gap = []
            }
            switch token.kind {
            case .digits(let groups, let joined, let decimal):
                addDigits(groups, joined: joined, decimal: decimal)
            case .words(let list, let ordinalUnit):
                addWords(list, ordinalUnit: ordinalUnit)
            case .spokenZero:
                // "four oh five": the "oh" is a zero only between two numbers.
                // "four oh five", and the "oh" after a "point" ("three point oh").
                let afterNumber = previous?.isNumber == true && previous?.endsRun == false && next?.isNumber == true
                let afterPoint = previous.map { if case .joiner = $0.kind { return !run.isEmpty } else { return false } } == true
                if afterNumber || afterPoint {
                    addWords(["zero"], ordinalUnit: false)
                } else {
                    end(token)
                }
            case .currency:
                let andFollows = next.map { if case .conjunction = $0.kind { return true } else { return false } } == true
                if !(run.isEmpty && words.isEmpty), next?.isNumber == true || andFollows {
                    flushWords()
                    bridgeAnd = andFollows
                } else {
                    end(token)
                }
            case .joiner:
                let numberFollows = next?.isNumber == true || next.map { if case .spokenZero = $0.kind { return true } else { return false } } == true
                if !(run.isEmpty && words.isEmpty), numberFollows { flushWords() } else { end(token) }
            case .conjunction:
                // "two hundred and twenty": the "and" belongs to the number.
                if next?.isNumber == true, bridged || words.last.map(Self.scaleWords.contains) == true { return }
                end(token)
            case .other:
                end(token)
            }
        }

        /// A word that is not part of a number ends the run and counts toward the gap before the next one.
        private mutating func end(_ token: Token) {
            endRun()
            gap.append(token.text)
        }

        private static func hasCue(_ words: [String]) -> Bool {
            let text = words.suffix(8).joined(separator: " ")
            return (ModelHints.correctionCues + ["my mistake", "my bad", "hold on"] + Self.spokenRetractions).contains { cue in
                text.range(of: "\\b\(NSRegularExpression.escapedPattern(for: cue))\\b", options: .regularExpression) != nil
            }
        }

        private mutating func addDigits(_ groups: [String], joined: Bool, decimal: String?) {
            flushWords()
            if joined {
                run += groups
                lastIsPlainNumeral = groups.count == 1
                lastDecimal = decimal
            } else {
                endRun()
                for group in groups {
                    runs.append([group])
                    breaks.append([])
                    cues.append(startCue)
                    retracts.append(startNot)
                    cueAfter.append(false)
                    startCue = false
                    startNot = false
                }
            }
        }

        private mutating func addWords(_ list: [String], ordinalUnit: Bool) {
            // The rules turn "twenty sixth" into "20 sixth": a tens numeral and an ordinal unit are one number.
            if ordinalUnit, words.isEmpty, lastIsPlainNumeral, let tens = run.last.flatMap(Int.init),
               tens >= 20, tens <= 90, tens % 10 == 0, let unit = list.first.flatMap({ InverseTextNormalizer.ones[$0] }) {
                run[run.count - 1] = String(tens + unit)
                lastIsPlainNumeral = false
                return
            }
            for word in list {
                if !words.isEmpty, InverseTextNormalizer.parseCardinal((words + [word]).joined(separator: " ")) == nil {
                    flushWords()
                }
                words.append(word)
            }
        }

        private mutating func flushWords() {
            defer { words = [] }
            guard !words.isEmpty, let value = InverseTextNormalizer.parseCardinal(words.joined(separator: " ")) else { return }
            // "25 thousand": a scale word right after a plain numeral multiplies it.
            if words.count == 1, Self.scaleWords.contains(words[0]), lastIsPlainNumeral,
               let base = run.last.flatMap(Int.init), let scale = InverseTextNormalizer.scales[words[0]] {
                let (product, overflow) = base.multipliedReportingOverflow(by: scale)
                if !overflow {
                    run[run.count - 1] = String(product)
                    lastIsPlainNumeral = false
                    return
                }
            }
            if words.count == 1, Self.scaleWords.contains(words[0]), let decimal = lastDecimal, run.count >= 2,
               let scale = InverseTextNormalizer.scales[words[0]], let product = Self.wholeProduct(decimal, scale) {
                run.removeLast(2)
                run.append(product)
                lastDecimal = nil
                return
            }
            run.append(String(value))
            lastIsPlainNumeral = false
            lastDecimal = nil
        }

        /// "2.5" times a million as "2500000", or nil when the product is not a whole number.
        private static func wholeProduct(_ decimal: String, _ scale: Int) -> String? {
            guard let number = Decimal(string: decimal) else { return nil }
            let product = number * Decimal(scale)
            var rounded = Decimal(), exact = product
            NSDecimalRound(&rounded, &exact, 0, .plain)
            guard rounded == product, product < Decimal(InverseTextNormalizer.maxCardinal) else { return nil }
            return NSDecimalNumber(decimal: product).stringValue
        }

        private mutating func endRun() {
            flushWords()
            if !run.isEmpty {
                runs.append(run)
                breaks.append(runBreaks.filter { $0 > 0 && $0 < run.count })
                cues.append(startCue)
                retracts.append(startNot)
                cueAfter.append(false)
            }
            startCue = false
            startNot = false
            run = []
            runBreaks = []
            lastIsPlainNumeral = false
            lastDecimal = nil
        }

        private static let scaleWords = Set(InverseTextNormalizer.scales.keys)
    }
}

// MARK: - Tokens

private extension SpokenNumberRuns.Builder {
    static let currencySymbols: Set<Character> = ["$", "\u{20AC}", "\u{00A3}", "\u{00A5}"]
    static let openers = CharacterSet(charactersIn: "\"'\u{201C}\u{2018}([{<#~+")
    static let closers = CharacterSet(charactersIn: "\"'\u{201D}\u{2019})]}>.,;:!?%")
    static let separators = CharacterSet(charactersIn: "-\u{2013}\u{2014}/")
    static let joiners: Set<String> = ["point", "dot", "colon"]

    /// One whitespace-separated piece of text as tokens: "10-15" is two, with a soft break between them.
    static func tokens(_ raw: Substring) -> [SpokenNumberRuns.Token] {
        var core = String(raw)
        let startsRun = core.first.map(currencySymbols.contains) ?? false
        core = core.trimmingCharacters(in: openers).trimmingCharacters(in: CharacterSet(charactersIn: String(currencySymbols)))
        let trimmed = core.trimmingCharacters(in: closers)
        let endsRun = trimmed.count != core.count
        core = trimmed
        guard !core.isEmpty else { return [] }
        let hasDigit = core.contains(where: \.isNumber)
        let pieces = core.components(separatedBy: separators).filter { !$0.isEmpty }
        if !hasDigit {
            let word = core.lowercased()
            // "one-to-one", "third-floor", "ten-minute": the number words of a hyphenated word are read as the numbers they
            // are, and the rest as words, as when they stand apart. "twenty-one" is one number and stays whole.
            let parts = word.split(separator: "-").map(String.init)
            if parts.count > 1, !parts.allSatisfy({ cardinalWord($0) != nil }) {
                return parts.enumerated().map { index, part in
                    SpokenNumberRuns.Token(kind: kind(ofWords: part), text: part, startsRun: startsRun && index == 0,
                                           endsRun: endsRun && index == parts.count - 1)
                }
            }
            return [SpokenNumberRuns.Token(kind: kind(ofWords: word), text: word, startsRun: startsRun, endsRun: endsRun)]
        }
        return pieces.enumerated().map { index, piece in
            var token = SpokenNumberRuns.Token(
                kind: piece.contains(where: \.isNumber) ? kind(ofNumeral: piece) : kind(ofWords: piece.lowercased()),
                text: piece.lowercased(), startsRun: startsRun && index == 0, endsRun: endsRun && index == pieces.count - 1)
            token.softBreakBefore = index > 0
            return token
        }
    }

    static func kind(ofWords word: String) -> SpokenNumberRuns.Token.Kind {
        if joiners.contains(word) { return .joiner }
        if word == "dollar" || word == "dollars" { return .currency }
        if word == "and" { return .conjunction }
        if word == "oh" { return .spokenZero }
        let parts = word.split(separator: "-").map(String.init)
        let cardinals = parts.compactMap(cardinalWord)
        guard !cardinals.isEmpty, cardinals.count == parts.count else { return .other }
        return .words(cardinals, ordinalUnit: parts.count == 1 && ordinalUnits.contains(word))
    }

    /// "27th", "4,200", "2.4.9", "3:30pm" are numerals; "Q3", "mp3", "v2b" hold digits but are not.
    static func kind(ofNumeral piece: String) -> SpokenNumberRuns.Token.Kind {
        var groups = Regex.matches(piece, "\\d+(?:,\\d{3})*").compactMap { $0.string(at: 0, in: piece) }
            .map { $0.replacingOccurrences(of: ",", with: "") }
        let pure = Regex.firstMatch(
            piece, "^\\d+(?:,\\d{3})*(?:[.:]\\d+(?:,\\d{3})*)*(?:st|nd|rd|th|s|x|am|pm)?$") != nil
        // ":00" and ".00" at the end of "2:00 pm" and "$5.00" say nothing the whole number did not.
        if pure, groups.count > 1, groups.last == "00" { groups.removeLast() }
        let decimal = Regex.firstMatch(piece, "^\\d+(?:,\\d{3})*\\.\\d+$") != nil
            ? piece.replacingOccurrences(of: ",", with: "") : nil
        return .digits(groups, joined: pure, decimal: decimal)
    }

    static let ordinalUnits: Set<String> = ["first", "second", "third", "fourth", "fifth", "sixth", "seventh", "eighth", "ninth"]
    private static let irregularOrdinals = [
        "first": "one", "second": "two", "third": "three", "fifth": "five", "eighth": "eight", "ninth": "nine",
        "twelfth": "twelve",
    ]

    /// The cardinal a number word stands for ("seventh" -> "seven", "twentieth" -> "twenty"), or nil.
    static func cardinalWord(_ word: String) -> String? {
        let cardinals = InverseTextNormalizer.allDigitWords.union(InverseTextNormalizer.scales.keys)
        if cardinals.contains(word) { return word }
        if let irregular = irregularOrdinals[word] { return irregular }
        if word.hasSuffix("ieth"), cardinals.contains(String(word.dropLast(4)) + "y") { return String(word.dropLast(4)) + "y" }
        if word.hasSuffix("th"), cardinals.contains(String(word.dropLast(2))) { return String(word.dropLast(2)) }
        return nil
    }
}
