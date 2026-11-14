import Foundation

/// Converts spoken number words the ASR left as words into the written form a person would
/// actually type: "twenty-five minutes" -> "25 minutes", "at three thirty this afternoon" ->
/// "at 3:30 this afternoon", "two point three point one" -> "2.3.1", "fifteen percent" -> "15%".
///
/// This is conservative by design: dictation cannot be undone by the user the way a typo can be
/// noticed and fixed, so every rule here only fires on an unambiguous spoken pattern and leaves
/// anything else as words. When a rule is unsure, it does nothing.
///
/// Style convention (documented, not configurable): cardinal numbers ten and above become
/// digits in running prose ("twenty-five minutes" -> "25 minutes"), matching common style-guide
/// practice; one through nine stay as words in plain prose ("I have three cats") but always
/// become digits next to a unit, money, time, percent, version or measurement context, because
/// that is how those forms are actually written ("3 kg", "$3", "3:00", "3%", "v3"). Ordinal
/// dates are normalized to "Month D" (e.g. "March 23"), dropping the ordinal suffix, which is
/// the more common written convention for dates in running text.
///
/// Order matters: the most specific patterns (versions, money, clock times, percentages,
/// ordinal dates) run first, consuming their number words before the generic cardinal pass
/// would otherwise leave them as bare digits without their unit/symbol.
enum InverseTextNormalizer {
    static let clockTimeCuePattern = "(?:at|by|until|till|around|before|after)"
    /// `codeContext` lets `IdentifierNumbers` treat "colon" and "equals" as identifier nouns (ports and
    /// constants get no thousands separator); every other pass is unchanged and prose passes false.
    static func apply(_ text: String, codeContext: Bool = false) -> String {
        var out = text
        // Order matters: rules that need "point"/"dollars"/"percent" to still be words run
        // before the generic decimal/cardinal passes that would otherwise consume the same
        // number words first and leave nothing for the more specific rule to match.
        out = shareScaleInRange(out)
        out = convertVersions(out)
        out = convertMoney(out)
        out = convertPercentages(out)
        out = convertClockTimes(out)
        out = convertDottedClockTimes(out)
        out = convertOrdinalDates(out)
        out = convertYears(out)
        out = CompoundOrdinals.apply(out)
        out = convertDecimals(out)
        out = convertPhoneLikeSequences(out)
        out = IdentifierNumbers.apply(out, codeContext: codeContext)
        out = convertCardinals(out)
        out = unifyRangeNumerals(out)
        return out
    }

    /// "two to three hundred dollars" and "five or ten thousand people": the scale word closes the range, so it belongs to both
    /// ends. The first end takes it ("two hundred to three hundred"), and the later passes style both the same way.
    /// Only when the two ends are like magnitudes: the first end must be smaller than the second, and "one" never takes
    /// the scale ("one to one hundred" counts from 1; "one to two hundred" is 1 to 200).
    static func shareScaleInRange(_ text: String) -> String {
        let unit = "(?:one|two|three|four|five|six|seven|eight|nine)"
        let tens = "(?:twenty|thirty|forty|fifty|sixty|seventy|eighty|ninety)"
        let teen = "(?:ten|eleven|twelve|thirteen|fourteen|fifteen|sixteen|seventeen|eighteen|nineteen)"
        let small = "(?:\\b(?:\(tens)(?:[-\\s]\(unit))?|\(teen)|\(unit))\\b)"
        let pattern = "(?i)(?<![\\p{L}\\p{N}-])(\(small))(\\s+(?:to|or)\\s+)(\(small))(\\s+(?:hundred|thousand|million|billion)\\b)"
        return Regex.replace(text, pattern) { whole, groups in
            guard groups.count > 4 else { return whole }
            let first = smallValue(groups[1])
            let second = smallValue(groups[3])
            guard first > 1, first < second else { return whole }
            return groups[1] + groups[4] + groups[2] + groups[3] + groups[4]
        }
    }

    /// The value of a spoken number below one hundred ("twenty five", "twenty-five", "seven"); 0 when unreadable.
    private static func smallValue(_ words: String) -> Int {
        words.lowercased().split(whereSeparator: { $0 == " " || $0 == "-" }).reduce(0) { total, word in
            total + (ones[String(word)] ?? teens[String(word)] ?? tens[String(word)] ?? 0)
        }
    }

    private static let singleDigitWordPattern = "(?:zero|one|two|three|four|five|six|seven|eight|nine)"
    /// Words that make a following "one" a pronoun or determiner ("the one or 2 that..."), not a number.
    private static let oneIsNotANumber: Set<String> = [
        "the", "a", "an", "which", "this", "that", "no", "any", "every", "each", "another", "every", "whichever",
        "of", "for", "not", "just", "only", "at",
    ]

    /// "five to 10 people" and "3 or four weeks" mix words and digits inside one range because each number is
    /// styled on its own (one to nine as words, ten and over as digits). Two numbers joined by "to" or "or" are
    /// one quantity, so the word side becomes digits: "5 to 10 people", "3 or 4 weeks".
    static func unifyRangeNumerals(_ text: String) -> String {
        func digit(_ word: String) -> String? { ones[word.lowercased()].map(String.init) }
        var out = text
        // "a hundred to 150": a scale word alone ("a hundred", "a thousand") stays a word in prose, but beside digits
        // in a range it is one side of the same quantity, so it takes the digits too.
        let scale = "(hundred|thousand|million|billion)"
        let scaleThenDigits = "(?i)(?<![\\p{L}\\p{N}])(?:an?\\s+)?\(scale)(\\s+(?:or|to)\\s+)(?:an?\\s+)?(\\d[\\d,]*)(?![\\p{L}\\p{N}])"
        let digitsThenScale = "(?i)(?<![\\p{L}\\p{N}])(\\d[\\d,]*)(\\s+(?:or|to)\\s+)(?:an?\\s+)?\(scale)(?![\\p{L}\\p{N}\\-])"
        func value(_ word: String) -> String { scales[word.lowercased()].map { $0 >= 1_000 ? groupedThousands($0) : String($0) } ?? word }
        out = Regex.replace(out, scaleThenDigits) { _, groups in
            guard groups.count > 3 else { return groups.first ?? "" }
            return value(groups[1]) + groups[2] + groups[3]
        }
        out = Regex.replace(out, digitsThenScale) { _, groups in
            guard groups.count > 3 else { return groups.first ?? "" }
            return groups[1] + groups[2] + value(groups[3])
        }
        let wordThenDigits = "(?<![\\p{L}\\p{N}])(\(singleDigitWordPattern))(\\s+(?:or|to)\\s+)(\\d[\\d,]*)(?![\\p{L}\\p{N}])"
        let digitsThenWord = "(?<![\\p{L}\\p{N}])(\\d[\\d,]*)(\\s+(?:or|to)\\s+)(\(singleDigitWordPattern))(?![\\p{L}\\p{N}])"
        for (pattern, wordGroup) in [(wordThenDigits, 1), (digitsThenWord, 3)] {
            guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { continue }
            let source = out as NSString
            var result = ""
            var cursor = 0
            for match in regex.matches(in: out, range: NSRange(location: 0, length: source.length)) {
                let whole = match.range
                result += source.substring(with: NSRange(location: cursor, length: whole.location - cursor))
                cursor = whole.location + whole.length
                let word = source.substring(with: match.range(at: wordGroup))
                let before = source.substring(to: whole.location).split(whereSeparator: \.isWhitespace).last.map { $0.lowercased() } ?? ""
                if word.lowercased() == "one", oneIsNotANumber.contains(before) || wordGroup == 3 && before == "one" {
                    result += source.substring(with: whole)
                    continue
                }
                guard let replacement = digit(word) else { result += source.substring(with: whole); continue }
                var parts = (1...3).map { source.substring(with: match.range(at: $0)) }
                parts[wordGroup - 1] = replacement
                result += parts.joined()
            }
            result += source.substring(from: cursor)
            out = result
        }
        // "$200 to $300": a range has one currency, so a bare number before "to $300" takes the symbol too.
        out = Regex.replace(out, "(?<![\\p{L}\\p{N}$\u{20AC}\u{00A3}\u{00A5},.])(\\d[\\d,]*)(\\s+(?:or|to)\\s+)\\$(\\d)") { _, groups in
            guard groups.count > 3 else { return groups.first ?? "" }
            return "$" + groups[1] + groups[2] + "$" + groups[3]
        }
        return out
    }

    // MARK: - Number word lexicon

    static let ones: [String: Int] = [
        "zero": 0, "one": 1, "two": 2, "three": 3, "four": 4, "five": 5,
        "six": 6, "seven": 7, "eight": 8, "nine": 9,
    ]
    static let teens: [String: Int] = [
        "ten": 10, "eleven": 11, "twelve": 12, "thirteen": 13, "fourteen": 14, "fifteen": 15,
        "sixteen": 16, "seventeen": 17, "eighteen": 18, "nineteen": 19,
    ]
    static let tens: [String: Int] = [
        "twenty": 20, "thirty": 30, "forty": 40, "fifty": 50,
        "sixty": 60, "seventy": 70, "eighty": 80, "ninety": 90,
    ]
    static let scales: [String: Int] = [
        "hundred": 100, "thousand": 1_000, "million": 1_000_000, "billion": 1_000_000_000,
    ]

    static var allDigitWords: Set<String> { Set(ones.keys).union(teens.keys).union(tens.keys) }

    /// Every word a cardinal-number phrase can be built from, including the joiner "and"
    /// ("four hundred and twelve") and scale words. Used to bound how far a match can extend.
    private static let numberWordPattern: String = {
        let words = Set(ones.keys).union(teens.keys).union(tens.keys).union(scales.keys)
        return "(?:\(words.sorted { $0.count > $1.count }.map(Regex.escape).joined(separator: "|")))"
    }()

    /// A run of number words/hyphens/"and", e.g. "four hundred and twelve" or "twenty-five".
    private static let cardinalPhrasePattern =
        "\(numberWordPattern)(?:[\\s-]+(?:and[\\s-]+)?\(numberWordPattern))*"

    /// Parses a cardinal phrase like "four hundred and twelve" or "twenty five" into an integer.
    /// Returns nil for phrases that don't parse as a single coherent number (defensive; the
    /// regex that finds candidates already constrains the shape considerably).
    /// A number word's grammatical slot, used to reject invalid sequences like "three thirty"
    /// (a ones-word can't be directly followed by a tens-word — that pair is two separate
    /// numbers, or a clock time, not one cardinal) while still accepting "twenty five",
    /// "four hundred and twelve" and "two thousand three".
    private enum Slot { case onesOrTeens, tens, hundred, scale }

    private static func slot(of word: String) -> Slot? {
        if ones[word] != nil || teens[word] != nil { return .onesOrTeens }
        if tens[word] != nil { return .tens }
        if word == "hundred" { return .hundred }
        if let value = scales[word], value >= 1_000 { return .scale }
        return nil
    }

    static func parseCardinal(_ phrase: String) -> Int? {
        let words = phrase.lowercased().split(whereSeparator: { !$0.isLetter }).map(String.init)
            .filter { $0 != "and" }
        guard !words.isEmpty else { return nil }

        var total = 0
        var current = 0
        var previous: Slot?
        var lastScale = Int.max
        for word in words {
            guard let currentSlot = slot(of: word) else { return nil }
            // A ones/teens word may start a group, or follow "hundred"/a scale word, or follow
            // a tens word ("twenty five" = 20 + 5). It may never directly follow another
            // ones/teens word — "three thirty" is not "3" + "30" as one cardinal.
            if currentSlot == .onesOrTeens, let previous, previous != .hundred, previous != .scale, previous != .tens {
                return nil
            }
            // A tens word may only start a group or follow "hundred"/a scale word.
            if currentSlot == .tens, let previous, previous != .hundred, previous != .scale {
                return nil
            }

            // Dictated text is untrusted: "hundred hundred hundred…" must never overflow (a
            // trap would crash the app mid-dictation). Anything beyond `maxCardinal` stays words.
            if let value = ones[word] ?? teens[word] ?? tens[word] {
                guard let sum = checkedAdd(current, value) else { return nil }
                current = sum
            } else if word == "hundred" {
                guard let product = checkedMultiply(max(current, 1), 100) else { return nil }
                current = product
            } else if let scale = scales[word] {
                // Scale words only ever decrease ("two million three thousand"); a repeat or
                // increase ("billion billion") isn't a number anyone dictates.
                guard scale < lastScale else { return nil }
                lastScale = scale
                guard let product = checkedMultiply(max(current, 1), scale),
                      let sum = checkedAdd(total, product) else { return nil }
                total = sum
                current = 0
            }
            previous = currentSlot
        }
        return checkedAdd(total, current)
    }

    /// Largest number converted to digits; larger spoken numbers are left as words.
    static let maxCardinal = 999_999_999_999_999

    private static func checkedAdd(_ lhs: Int, _ rhs: Int) -> Int? {
        let (result, overflow) = lhs.addingReportingOverflow(rhs)
        return overflow || result > maxCardinal ? nil : result
    }

    private static func checkedMultiply(_ lhs: Int, _ rhs: Int) -> Int? {
        let (result, overflow) = lhs.multipliedReportingOverflow(by: rhs)
        return overflow || result > maxCardinal ? nil : result
    }

    // MARK: - Versions: "version two point three point one" -> "version 2.3.1", "v two" -> "v2"

    private static func convertVersions(_ text: String) -> String {
        var out = text
        // "version/v two point three point one" (two or more dot-separated single digits).
        let dotted = "\\b(?:version|v)\\s+(\(digitWordPattern))((?:\\s+point\\s+\(digitWordPattern)){1,})\\b"
        out = Regex.replace(out, dotted) { whole, groups in
            guard let first = groups[safe: 1], let rest = groups[safe: 2],
                  let head = digitsForSingleNumberWord(first)
            else { return whole }
            let pointMatches = Regex.matches(rest, "point\\s+(\(digitWordPattern))")
            let parts = pointMatches.compactMap { match in match.string(at: 1, in: rest).flatMap(digitsForSingleNumberWord) }
            guard parts.count == pointMatches.count else { return whole }
            let prefix = whole.lowercased().hasPrefix("version") ? "version " : "v"
            return prefix + ([head] + parts).joined(separator: ".")
        }
        // "version two" (no dots) -> "version 2".
        // The whole spoken number is the version ("version four hundred six" -> "version 406"), not
        // just its first word. A run that is not one cardinal ("version four twelve") keeps the old
        // reading of its first word.
        out = Regex.replace(out, "\\bversion\\s+(\(cardinalPhrasePattern))\\b") { whole, groups in
            guard let phrase = groups[safe: 1] else { return whole }
            if let digits = digitsForSingleNumberWord(phrase) { return "version \(digits)" }
            guard let first = phrase.split(whereSeparator: { $0 == " " || $0 == "-" }).first.map(String.init),
                  let digits = digitsForSingleNumberWord(first) else { return whole }
            return "version \(digits)" + phrase.dropFirst(first.count)
        }
        return out
    }

    /// A single version component: one cardinal phrase ("three", "twenty five") converted to
    /// its digit string.
    private static func digitsForSingleNumberWord(_ phrase: String) -> String? {
        parseCardinal(phrase).map(String.init)
    }

    /// A single digit word (0-9) — the unit "point" is followed by when reading digits one at a
    /// time ("point zero five" = digits 0, 5), which is how decimals and versions are spoken.
    private static let digitWordPattern =
        "(?:\(InverseTextNormalizer.ones.keys.map(Regex.escape).joined(separator: "|")))"

    /// Converts a run of single digit words after "point" ("zero five", "one four") into a
    /// concatenated digit string ("05", "14"), the way decimals are actually read aloud: each
    /// digit spoken individually, not summed as one cardinal.
    private static func digitsForDecimalTail(_ phrase: String) -> String? {
        let words = phrase.lowercased().split(whereSeparator: { !$0.isLetter }).map(String.init)
        guard !words.isEmpty else { return nil }
        let digits = words.compactMap { ones[$0] }
        guard digits.count == words.count else { return nil }
        return digits.map(String.init).joined()
    }

    // MARK: - Decimals: "three point five" -> "3.5", "zero point zero five" -> "0.05"

    private static func convertDecimals(_ text: String) -> String {
        let pattern = "\\b(\(numberWordPattern))\\s+point((?:\\s+\(digitWordPattern))+)\\b"
        return Regex.replace(text, pattern) { whole, groups in
            guard let head = groups[safe: 1], let headDigits = digitsForSingleNumberWord(head),
                  let tail = groups[safe: 2], let tailDigits = digitsForDecimalTail(tail)
            else { return whole }
            return "\(headDigits).\(tailDigits)"
        }
    }

    // MARK: - Clock times

    /// "at 3.30 on Thursday" -> "at 3:30 on Thursday". Parakeet writes some clock times with a
    /// period (British style; 3 of 3 clock times in the US dictation proxy). Only fires with a
    /// time preposition before and an explicit time cue after (am/pm, a day part, today/tomorrow/
    /// tonight, "on <weekday>"), so prices ("closed at 3.30"), versions and decimals stay put.
    static func convertDottedClockTimes(_ text: String) -> String {
        let weekdays = "Monday|Tuesday|Wednesday|Thursday|Friday|Saturday|Sunday"
        let cue = "\\s*(?:am|pm|a\\.m\\.|p\\.m\\.)(?=\\s|[,.!?]|$)|\\s+(?:this\\s+|in the\\s+)(?:morning|afternoon|evening)\\b"
            + "|\\s+(?:tonight|today|tomorrow)\\b|\\s+on\\s+(?:\(weekdays))\\b"
        let pattern = "\\b(at|by|until|till|from|around|before|after)\\s+(\\d{1,2})\\.([0-5]\\d)(?=\(cue))"
        return Regex.replace(text, pattern) { whole, groups in
            guard let preposition = groups[safe: 1], let hour = groups[safe: 2].flatMap({ Int($0) }),
                  (1...12).contains(hour), let minutes = groups[safe: 3]
            else { return whole }
            return "\(preposition) \(hour):\(minutes)"
        }
    }

    private static func convertClockTimes(_ text: String) -> String {
        var out = text
        let hourWords = "(?:\(ones.keys.filter { $0 != "zero" }.map(Regex.escape).joined(separator: "|"))|\(teens.keys.map(Regex.escape).joined(separator: "|")))"
        let unit = "(?:one|two|three|four|five|six|seven|eight|nine)"
        let minuteWord = "(?:oh\\s+\(unit)|\(teens.keys.map(Regex.escape).joined(separator: "|"))|(?:twenty|thirty|forty|fifty)(?:[\\s-]+\(unit))?|ten|zero)"
        let markedMinute = "(?:\(minuteWord)|\(unit))"
        // At sentence end the abbreviation's final dot also closes the sentence.
        // Leave it outside the replacement so converting "a.m." does not erase it.
        let meridiemSuffix = "\\s*(am|pm|[ap]\\.m(?=\\.\\s*$)|[ap]\\.m\\.)(?=\\s|[,.!?]|$)"
        let cue = clockTimeCuePattern
        let weekday = "(?:Monday|Tuesday|Wednesday|Thursday|Friday|Saturday|Sunday)"
        let month = "(?:\(months.map(Regex.escape).joined(separator: "|")))"
        let ordinal = "(?:\\d{1,2}(?:st|nd|rd|th))"
        let calendarDate = "(?:the\\s+\(ordinal)|\(month)\\s+\(ordinal))"
        let daypart = "(?:this|in\\s+the)\\s+(?:morning|afternoon|evening)"
        let temporal = "(?:today|tonight|tomorrow|yesterday|sharp|\(daypart)|(?:(?:on|this)\\s+)?\(weekday)|on\\s+\(calendarDate))"
        let temporalAfter = "(?=\\s+\(temporal)\\b)"

        func clock(_ hourWord: String, _ minuteWord: String) -> String? {
            guard let hour = parseCardinal(hourWord), (1...12).contains(hour) else { return nil }
            let rest = minuteWord.replacingOccurrences(
                of: "^oh\\s+", with: "", options: [.regularExpression, .caseInsensitive])
            guard let minute = parseCardinal(rest), (0...59).contains(minute) else { return nil }
            return String(format: "%d:%02d", hour, minute)
        }

        func idiomClock(_ idiom: String, hourWord: String) -> String? {
            guard let hour = parseCardinal(hourWord), (1...12).contains(hour) else { return nil }
            switch idiom.lowercased() {
            case "half past": return String(format: "%d:30", hour)
            case "quarter past": return String(format: "%d:15", hour)
            case "quarter to":
                let previous = hour == 1 ? 12 : hour - 1
                return String(format: "%d:45", previous)
            default: return nil
            }
        }

        let idiomMeridiem = "\\b(half past|quarter past|quarter to)\\s+(\(hourWords))\(meridiemSuffix)"
        out = Regex.replace(out, idiomMeridiem) { whole, groups in
            guard let phrase = groups[safe: 1], let hour = groups[safe: 2],
                  let written = idiomClock(phrase, hourWord: hour) else { return whole }
            let meridiem = groups[safe: 3]?.replacingOccurrences(of: ".", with: "").lowercased() ?? ""
            return written + meridiem
        }

        let idiomAfterCue = "\\b(\(cue))\\s+(half past|quarter past|quarter to)\\s+(\(hourWords))\\b\(temporalAfter)"
        out = Regex.replace(out, idiomAfterCue) { whole, groups in
            guard let lead = groups[safe: 1], let phrase = groups[safe: 2], let hour = groups[safe: 3],
                  let written = idiomClock(phrase, hourWord: hour) else { return whole }
            return "\(lead) \(written)"
        }

        let idiomBareTemporal = "\\b(half past|quarter past|quarter to)\\s+(\(hourWords))\\b\(temporalAfter)"
        out = Regex.replace(out, idiomBareTemporal) { whole, groups in
            guard let phrase = groups[safe: 1], let hour = groups[safe: 2],
                  let written = idiomClock(phrase, hourWord: hour) else { return whole }
            return written
        }

        let oclockMeridiem = "\\b(\(hourWords))\\s+o'clock\(meridiemSuffix)"
        out = Regex.replace(out, oclockMeridiem) { whole, groups in
            guard let hour = groups[safe: 1], let h = parseCardinal(hour), (1...12).contains(h),
                  let meridiem = groups[safe: 2]
            else { return whole }
            return "\(h):00" + meridiem.replacingOccurrences(of: ".", with: "").lowercased()
        }

        let oclockAfterCue = "\\b(\(cue))\\s+(\(hourWords))\\s+o'clock\\b"
        out = Regex.replace(out, oclockAfterCue) { whole, groups in
            guard let lead = groups[safe: 1], let hour = groups[safe: 2],
                  let h = parseCardinal(hour), (1...12).contains(h) else { return whole }
            return "\(lead) \(h):00"
        }

        let oclockTemporal = "\\b(\(hourWords))\\s+o'clock\\b\(temporalAfter)"
        out = Regex.replace(out, oclockTemporal) { whole, groups in
            guard let hour = groups[safe: 1], let h = parseCardinal(hour), (1...12).contains(h) else { return whole }
            return "\(h):00"
        }

        // A meridiem immediately after the pair is sufficient evidence, with or without a cue.
        let withMeridiem = "\\b(\(hourWords))\\s+(\(markedMinute))\(meridiemSuffix)"
        out = Regex.replace(out, withMeridiem) { whole, groups in
            guard let hour = groups[safe: 1], let minute = groups[safe: 2],
                  let written = clock(hour, minute) else { return whole }
            let meridiem = groups[safe: 3]?.replacingOccurrences(of: ".", with: "").lowercased() ?? ""
            return written + meridiem
        }

        // The distinctive "oh" minute is safe after a cue without a following time word.
        let ohMinute = "\\b(\(cue))\\s+(\(hourWords))\\s+(oh\\s+\(unit))\\b"
        out = Regex.replace(out, ohMinute) { whole, groups in
            guard let lead = groups[safe: 1], let hour = groups[safe: 2],
                  let minute = groups[safe: 3], let written = clock(hour, minute) else { return whole }
            return "\(lead) \(written)"
        }

        // A from-to pair shares the temporal word after its second, time-shaped end.
        let range = "\\b(from)\\s+(\(hourWords))\\s+(\(minuteWord))\\s+(to)\\s+(\(hourWords))\\s+(\(minuteWord))\\b\(temporalAfter)"
        out = Regex.replace(out, range) { whole, groups in
            guard let lead = groups[safe: 1], let firstHour = groups[safe: 2],
                  let firstMinute = groups[safe: 3], let joiner = groups[safe: 4],
                  let secondHour = groups[safe: 5], let secondMinute = groups[safe: 6],
                  let first = clock(firstHour, firstMinute), let second = clock(secondHour, secondMinute)
            else { return whole }
            return "\(lead) \(first) \(joiner) \(second)"
        }

        // Ordinary hour-and-minute pairs need both a preceding cue and a following time word.
        let preceded = "\\b(\(cue))\\s+(\(hourWords))\\s+(\(minuteWord))\\b\(temporalAfter)"
        out = Regex.replace(out, preceded) { whole, groups in
            guard let lead = groups[safe: 1], let hour = groups[safe: 2],
                  let minute = groups[safe: 3], let written = clock(hour, minute) else { return whole }
            return "\(lead) \(written)"
        }

        // "moved to nine fifteen in the morning": "to" and "for" are too loose a cue before a bare pair
        // (a price, a count), so only a day part right after the pair lets them count.
        let strictDaypart = "(?:(?:this|in\\s+the)\\s+(?:morning|afternoon|evening)|tonight)"
        let toDaypart = "\\b(to|for)\\s+(\(hourWords))\\s+(\(minuteWord))\\b(?=\\s+\(strictDaypart)\\b)"
        out = Regex.replace(out, toDaypart) { whole, groups in
            guard let lead = groups[safe: 1], let hour = groups[safe: 2],
                  let minute = groups[safe: 3], let written = clock(hour, minute) else { return whole }
            return "\(lead) \(written)"
        }

        // "ten am" / "nine p.m." — an hour word directly followed by am/pm, with no minute.
        // The meridiem is mandatory here since a bare hour word alone is not distinctively a time.
        let hourOnly = "\\b(\(hourWords)|\(numberWordPattern))\(meridiemSuffix)(?=\\s|[,.!?]|$)"
        out = Regex.replace(out, hourOnly) { whole, groups in
            guard let hourWord = groups[safe: 1], let hour = parseCardinal(hourWord), (1...12).contains(hour),
                  let meridiem = groups[safe: 2], !meridiem.isEmpty
            else { return whole }
            return "\(hour):00" + meridiem.replacingOccurrences(of: ".", with: "").lowercased()
        }
        return out
    }

    // MARK: - Money: "$" prefix or "N dollars (and M cents)"

    private static func convertMoney(_ text: String) -> String {
        var out = convertDigitScaleMoney(text)
        // "four hundred and twelve dollars" -> "$412"; "three dollars and fifty cents" -> "$3.50".
        let dollarsAndCents =
            "\\b(\(cardinalPhrasePattern))\\s+dollars?(?:\\s+and\\s+(\(cardinalPhrasePattern))\\s+cents?)?\\b"
        out = Regex.replace(out, dollarsAndCents) { whole, groups in
            guard let dollarsWord = groups[safe: 1], let dollars = parseCardinal(dollarsWord) else { return whole }
            if let centsWord = groups[safe: 2], !centsWord.isEmpty, let cents = parseCardinal(centsWord), cents < 100 {
                return "$\(groupedThousands(dollars)).\(String(format: "%02d", cents))"
            }
            return "$\(groupedThousands(dollars))"
        }
        return out
    }

    /// "18 thousand dollars" -> "$18,000", "1.5 million dollars" -> "$1,500,000": the recognizer
    /// often writes the number as digits and the scale as a word. The word-only pattern below
    /// would otherwise read just "thousand dollars" and leave "18 $1,000". Only a whole-dollar
    /// result is written; anything else stays as spoken.
    private static func convertDigitScaleMoney(_ text: String) -> String {
        let scaleWords = scales.keys.map(Regex.escape).joined(separator: "|")
        return Regex.replace(text, "\\b(\\d+(?:\\.\\d+)?)\\s+(\(scaleWords))\\s+dollars?\\b") { whole, groups in
            guard let number = groups[safe: 1].flatMap({ Decimal(string: $0) }),
                  let scale = groups[safe: 2].flatMap({ scales[$0.lowercased()] })
            else { return whole }
            let amount = number * Decimal(scale)
            var rounded = Decimal()
            var exact = amount
            NSDecimalRound(&rounded, &exact, 0, .plain)
            guard rounded == amount, amount <= Decimal(maxCardinal) else { return whole }
            return "$" + groupedThousands(NSDecimalNumber(decimal: amount).intValue)
        }
    }

    /// US-style thousands separators for a whole dollar amount ("45000" -> "45,000") — a long
    /// dictation about a budget or quote routinely crosses four digits, and leaving it ungrouped
    /// reads like a formatting bug rather than a stylistic choice; ordinary written English (and
    /// this codebase's own goldens) always group amounts this way once they cross 1,000.
    private static func groupedThousands(_ value: Int) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.groupingSeparator = ","
        return formatter.string(from: NSNumber(value: value)) ?? String(value)
    }

    // MARK: - Percentages: "fifteen percent" -> "15%"

    private static func convertPercentages(_ text: String) -> String {
        let pattern = "\\b(\(cardinalPhrasePattern)(?:\\s+point\\s+\(numberWordPattern))?)\\s+percent\\b"
        return Regex.replace(text, pattern) { whole, groups in
            guard let phrase = groups[safe: 1] else { return whole }
            if let dotRange = phrase.range(of: "\\s+point\\s+", options: .regularExpression) {
                let head = String(phrase[phrase.startIndex..<dotRange.lowerBound])
                let tail = String(phrase[dotRange.upperBound...])
                guard let headValue = parseCardinal(head), let tailDigit = digitsForSingleNumberWord(tail) else {
                    return whole
                }
                return "\(headValue).\(tailDigit)%"
            }
            guard let value = parseCardinal(phrase) else { return whole }
            return "\(value)%"
        }
    }

    // MARK: - Ordinal dates: "the twenty third of March" / "March the twenty third" -> "March 23"

    static let ordinalWords: [String: Int] = [
        "first": 1, "second": 2, "third": 3, "fourth": 4, "fifth": 5, "sixth": 6, "seventh": 7,
        "eighth": 8, "ninth": 9, "tenth": 10, "eleventh": 11, "twelfth": 12, "thirteenth": 13,
        "fourteenth": 14, "fifteenth": 15, "sixteenth": 16, "seventeenth": 17, "eighteenth": 18,
        "nineteenth": 19, "twentieth": 20, "thirtieth": 30, "thirty-first": 31,
    ]
    private static let ordinalTens: [String: Int] = [
        "twenty": 20, "thirty": 30,
    ]
    static let months = [
        "January", "February", "March", "April", "May", "June",
        "July", "August", "September", "October", "November", "December",
    ]

    /// Year-style pairs need calendar evidence before and a grammatical continuation after.
    /// An unknown word after the pair may be a counted noun, unit or name, so it stays spoken.
    private static func convertYears(_ text: String) -> String {
        let unit = "(?:one|two|three|four|five|six|seven|eight|nine)"
        let lastTwo = "(?:ten|eleven|twelve|thirteen|fourteen|fifteen|sixteen|seventeen|eighteen|nineteen|(?:twenty|thirty|forty|fifty|sixty|seventy|eighty|ninety)(?:[\\s-]+\(unit))?)"
        let month = months.map(Regex.escape).joined(separator: "|")
        let quarter = "(?:Q[1-4]|(?:first|second|third|fourth)\\s+quarter|quarter\\s+(?:one|two|three|four|[1-4]))"
        let season = "(?:spring|summer|autumn|fall|winter)"
        let day = "(?:[1-9]|[12]\\d|3[01])"
        let context = "(?:in|since|(?:\(month))(?:\\s+\(day),?)?|\(quarter)|\(season))"
        let calendarEnd = "(?=\\s*(?:[,.!?;:]|$)|\\s+(?:on|for|and|or|so|because|in|with|by|if|but|when|while|as|I|you|he|she|it|we|they|was|were|is|are|will|would|should|could|can|may|might|must|has|have|had|today|tomorrow)\\b)"
        let pattern = "\\b(\(context))\\s+(nineteen|twenty)\\s+(\(lastTwo))\\b\(calendarEnd)"
        return Regex.replace(text, pattern) { whole, groups in
            guard let lead = groups[safe: 1], let century = groups[safe: 2],
                  let end = groups[safe: 3], let twoDigits = parseCardinal(end),
                  (10...99).contains(twoDigits) else { return whole }
            let year = (century.lowercased() == "nineteen" ? 1900 : 2000) + twoDigits
            // An ordinal date has already become "Month D"; add the conventional comma
            // before its year, while retaining a comma that was already dictated.
            let dateLead = Regex.firstMatch(lead, "\\b(?:\(month))\\s+\(day),?$") != nil
            return "\(lead)\(dateLead && !lead.hasSuffix(",") ? "," : "") \(year)"
        }
    }

    private static func convertOrdinalDates(_ text: String) -> String {
        var out = text
        let ordinalPhrase = "(?:(?:\(ordinalTens.keys.map(Regex.escape).joined(separator: "|")))[\\s-]+)?(?:\(ordinalWords.keys.sorted { $0.count > $1.count }.map(Regex.escape).joined(separator: "|")))"
        let monthPattern = months.map(Regex.escape).joined(separator: "|")

        // "the twenty third of March" -> "March 23"
        out = Regex.replace(out, "\\bthe\\s+(\(ordinalPhrase))\\s+of\\s+(\(monthPattern))\\b") { whole, groups in
            guard let ordinal = groups[safe: 1], let month = groups[safe: 2],
                  let day = parseOrdinal(ordinal), let canonicalMonth = canonicalMonth(month)
            else { return whole }
            return "\(canonicalMonth) \(day)"
        }
        // "March the twenty third" -> "March 23"
        out = Regex.replace(out, "\\b(\(monthPattern))\\s+the\\s+(\(ordinalPhrase))\\b") { whole, groups in
            guard let month = groups[safe: 1], let ordinal = groups[safe: 2],
                  let day = parseOrdinal(ordinal), let canonicalMonth = canonicalMonth(month)
            else { return whole }
            return "\(canonicalMonth) \(day)"
        }
        return out
    }

    private static func canonicalMonth(_ word: String) -> String? {
        months.first { $0.lowercased() == word.lowercased() }
    }

    private static func parseOrdinal(_ phrase: String) -> Int? {
        let words = phrase.lowercased().split(whereSeparator: { !$0.isLetter && $0 != "-" }).map(String.init)
        guard !words.isEmpty else { return nil }
        if words.count == 1, let value = ordinalWords[words[0]] { return value }
        if words.count == 2, let tensValue = ordinalTens[words[0]], let onesValue = ordinalWords[words[1]], onesValue < 10 {
            return tensValue + onesValue
        }
        return nil
    }

    // MARK: - Phone-number-like digit strings: "five five five one two three four five six seven"

    /// Only fires on a long, unbroken run of single digit words (7+), which is not a plausible
    /// plain-prose cardinal — real sentences don't say "five five five" as a quantity. Renders
    /// as a hyphenated group when it looks like a US-style 10-digit number, otherwise as spaced
    /// digits, matching how such sequences are conventionally written for reading back.
    private static func convertPhoneLikeSequences(_ text: String) -> String {
        let digitWord = "(?:\(ones.keys.map(Regex.escape).joined(separator: "|")))"
        let pattern = "\\b(\(digitWord)(?:[\\s-]+\(digitWord)){6,})\\b"
        return Regex.replace(text, pattern) { whole, groups in
            guard let phrase = groups[safe: 1] else { return whole }
            let words = phrase.lowercased().split(whereSeparator: { !$0.isLetter }).map(String.init)
            let digits = words.compactMap { ones[$0] }
            guard digits.count == words.count else { return whole }
            let digitString = digits.map(String.init).joined()
            if digitString.count == 10 {
                let area = digitString.prefix(3)
                let exchange = digitString.dropFirst(3).prefix(3)
                let line = digitString.dropFirst(6)
                return "\(area)-\(exchange)-\(line)"
            }
            return digits.map(String.init).joined(separator: "-")
        }
    }

    // MARK: - Plain cardinals: numbers ten and above become digits in running prose

    /// One through nine stay as words in plain prose (the common style-guide convention);
    /// ten and above become digits. Numbers already consumed by a more specific rule above
    /// (money, times, percentages, versions, dates, phone-like runs) never reach this pass
    /// because those rules already replaced their number words with digits.
    /// "a hundred times better/worse/more/less/faster/..." is a fixed comparative idiom, not a
    /// literal count — it reads naturally as words and a reader would not expect digits there.
    private static let comparative =
        "(?:better|worse|more|less|faster|slower|harder|easier|bigger|smaller|safer|stronger)"

    private static func convertCardinals(_ text: String) -> String {
        // A bare clock-shaped range was deliberately left spoken by the clock rule. Consume
        // the whole span here so its hour-only end cannot become a cardinal on its own.
        let hour = "(?:one|two|three|four|five|six|seven|eight|nine|ten|eleven|twelve)"
        let minute = "(?:oh\\s+(?:one|two|three|four|five|six|seven|eight|nine)|ten|eleven|twelve|thirteen|fourteen|fifteen|sixteen|seventeen|eighteen|nineteen|twenty|thirty|forty|fifty)(?:[\\s-]+(?:one|two|three|four|five|six|seven|eight|nine))?"
        let spokenRange = "\(hour)\\s+\(minute)\\s+(?:to|or)\\s+\(hour)(?:\\s+\(minute))?"
        let pattern = "\\b(?:(\(spokenRange))|(\(cardinalPhrasePattern)))\\b(?!\\s+times\\s+\(comparative)\\b)"
        return Regex.replace(text, pattern) { whole, groups in
            guard groups[safe: 1]?.isEmpty == true,
                  let phrase = groups[safe: 2], let value = parseCardinal(phrase) else { return whole }
            // A scale word on its own is a word, not a number: "$4.5 million" (the recognizer
            // already wrote the digits), "a thousand thanks", "millions". Converting it produced
            // "$4.5 1,000,000" (US dictation proxy, us-numbers-12).
            let hasCountWord = phrase.lowercased().split(whereSeparator: { !$0.isLetter })
                .contains { ones[String($0)] != nil || teens[String($0)] != nil || tens[String($0)] != nil }
            guard hasCountWord else { return whole }
            // Leave small counts as words in plain prose; only ten-and-up (or any phrase using
            // a scale word like "hundred") switches to digits.
            let usesScaleWord = Regex.firstMatch(phrase, "\\b(?:hundred|thousand|million|billion)\\b") != nil
            guard value >= 10 || usesScaleWord else { return whole }
            // 1,000+ gets US-style thousands separators, same as money amounts — "twenty two
            // thousand" reads as "22,000", not the harder-to-parse "22000".
            return value >= 1_000 ? groupedThousands(value) : String(value)
        }
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
