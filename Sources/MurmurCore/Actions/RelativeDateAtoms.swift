import Foundation

/// Which day a phrase names, before it is resolved against a `DateContext`.
enum DaySpec: Sendable, Equatable {
    /// Days from today: today 0, tomorrow 1, day after tomorrow 2, "in 3 days" 3.
    case offset(Int)
    /// Calendar weekday (1 = Sunday). `minimumAhead` 0 = "this friday" (today counts),
    /// 1 = "friday" / "next friday" / "on friday" (the next one after today).
    case weekday(Int, minimumAhead: Int)
    /// "on the 10th": the next such day of the month, today included.
    case dayOfMonth(Int)
    /// "october 20th", "3rd november", "12/10": year optional (next occurrence when missing).
    case monthDay(month: Int, day: Int, year: Int?)
    /// "12/10" as spoken: which number is the day depends on the locale.
    case numeric(first: Int, second: Int, year: Int?)
    /// "next week": the coming Monday.
    case nextWeek
    /// "this weekend": today if it is the weekend, else the coming Saturday.
    case weekend
    /// "end of the week", "eow": the coming Friday, end of day.
    case endOfWeek
}

/// A spoken clock time; `isPM` nil means no am/pm was said.
struct ClockTime: Sendable, Equatable {
    var hour: Int
    var minute: Int
    var isPM: Bool?
}

/// A part of the day spoken instead of (or alongside) a clock time.
enum DayPeriod: String, Sendable, Equatable {
    case morning, afternoon, evening, night, tonight
    case endOfDay, beforeBed, afterLunch, beforeLunch, lunch, firstThing, midnight, sameTime

    /// Whether an unmarked hour in this period is after noon ("evening 7" → 19:00).
    var isAfternoonish: Bool {
        switch self {
        case .afternoon, .evening, .night, .tonight, .beforeBed, .afterLunch, .endOfDay: true
        default: false
        }
    }
}

extension RelativeDateParser {
    // MARK: Days

    static func day(_ tokens: [DateToken], _ index: Int) -> Atom? {
        let lead = ["on", "by", "till", "until", "before", "from", "for"].contains(tokens[index].text) ? index + 1 : index
        guard lead < tokens.count else { return nil }
        let matchers: [([DateToken], Int) -> (DaySpec, Int, Bool)?] = [relativeDay, namedWeekday, weekPhrase, monthAndDay, numericDate, ordinalDay]
        for matcher in matchers {
            if let (spec, end, isWeak) = matcher(tokens, lead) {
                return Atom(kind: .day(spec), range: index..<end, isWeak: isWeak && lead == index)
            }
        }
        return nil
    }

    private static func words(_ tokens: [DateToken], _ index: Int, _ count: Int) -> [String] {
        guard index + count <= tokens.count else { return [] }
        return tokens[index..<index + count].map(\.text)
    }

    private static func relativeDay(_ tokens: [DateToken], _ index: Int) -> (DaySpec, Int, Bool)? {
        var start = index
        if tokens[start].text == "the", words(tokens, start + 1, 3) == ["day", "after", "tomorrow"] { start += 1 }
        if words(tokens, start, 3) == ["day", "after", "tomorrow"] { return (.offset(2), start + 3, false) }
        switch tokens[start].text {
        case "today": return (.offset(0), start + 1, false)
        case "tomorrow", "tmrw", "tomorow", "tommorow", "tommorrow": return (.offset(1), start + 1, false)
        case "overmorrow": return (.offset(2), start + 1, false)
        default: return nil
        }
    }

    private static func namedWeekday(_ tokens: [DateToken], _ index: Int) -> (DaySpec, Int, Bool)? {
        var cursor = index
        var minimumAhead = 1
        while cursor < tokens.count, ["this", "next", "coming", "upcoming", "following", "the"].contains(tokens[cursor].text) {
            if tokens[cursor].text == "this" { minimumAhead = 0 }
            cursor += 1
        }
        guard cursor < tokens.count, let weekday = SpokenDateLexicon.weekdays[tokens[cursor].text] else { return nil }
        cursor += 1
        if words(tokens, cursor, 2) == ["after", "next"] {
            return (.weekday(weekday, minimumAhead: 8), cursor + 2, false)
        }
        return (.weekday(weekday, minimumAhead: minimumAhead), cursor, false)
    }

    private static func weekPhrase(_ tokens: [DateToken], _ index: Int) -> (DaySpec, Int, Bool)? {
        if words(tokens, index, 2) == ["next", "week"] { return (.nextWeek, index + 2, false) }
        for prefix in [["this", "weekend"], ["next", "weekend"], ["the", "weekend"], ["weekend"]] where words(tokens, index, prefix.count) == prefix {
            return (.weekend, index + prefix.count, false)
        }
        for phrase in [["end", "of", "the", "week"], ["end", "of", "week"], ["eow"]] where words(tokens, index, phrase.count) == phrase {
            return (.endOfWeek, index + phrase.count, false)
        }
        return nil
    }

    /// "october 20th", "oct 20 2026", "3rd november", "the 7th of november", "30 october".
    /// A month word only counts next to a day number, so "may" and "march" stay words.
    private static func monthAndDay(_ tokens: [DateToken], _ index: Int) -> (DaySpec, Int, Bool)? {
        if let month = SpokenDateLexicon.months[tokens[index].text] {
            var cursor = index + 1
            if cursor < tokens.count, tokens[cursor].text == "the" { cursor += 1 }
            guard let (day, next) = SpokenDateLexicon.ordinal(tokens, cursor) ?? dayNumber(tokens, cursor) else { return nil }
            let (year, end) = self.year(tokens, next)
            return (.monthDay(month: month, day: day, year: year), end, false)
        }
        let start = tokens[index].text == "the" ? index + 1 : index
        guard let (day, next) = SpokenDateLexicon.ordinal(tokens, start) ?? dayNumber(tokens, start) else { return nil }
        let cursor = next < tokens.count && tokens[next].text == "of" ? next + 1 : next
        guard cursor < tokens.count, let month = SpokenDateLexicon.months[tokens[cursor].text] else { return nil }
        let (year, end) = self.year(tokens, cursor + 1)
        return (.monthDay(month: month, day: day, year: year), end, false)
    }

    private static func dayNumber(_ tokens: [DateToken], _ index: Int) -> (Int, Int)? {
        guard index < tokens.count, tokens[index].text.allSatisfy(\.isNumber),
              let value = Int(tokens[index].text), (1...31).contains(value) else { return nil }
        return (value, index + 1)
    }

    private static func year(_ tokens: [DateToken], _ index: Int) -> (Int?, Int) {
        guard index < tokens.count, tokens[index].text.count == 4, let year = Int(tokens[index].text),
              (2000...2100).contains(year) else { return (nil, index) }
        return (year, index + 1)
    }

    /// "12/10", "25/10/2026", "2026-10-12". Day-first or month-first is decided when resolving,
    /// from the locale (`DateContext.prefersDayFirst`), so the spec keeps the spoken order.
    private static func numericDate(_ tokens: [DateToken], _ index: Int) -> (DaySpec, Int, Bool)? {
        let text = tokens[index].text
        let iso = text.split(separator: "-").compactMap { Int($0) }
        if iso.count == 3, text.count == 10, (1...12).contains(iso[1]), (1...31).contains(iso[2]) {
            return (.monthDay(month: iso[1], day: iso[2], year: iso[0]), index + 1, false)
        }
        let parts = text.split(separator: "/").map(String.init)
        guard (2...3).contains(parts.count), parts.allSatisfy({ !$0.isEmpty && $0.allSatisfy(\.isNumber) }),
              let first = Int(parts[0]), let second = Int(parts[1]) else { return nil }
        var year: Int?
        if parts.count == 3, let raw = Int(parts[2]) { year = raw < 100 ? 2000 + raw : raw }
        guard (1...31).contains(first), (1...31).contains(second) else { return nil }
        // "24/7" and fractions are not dates unless something marks them as one.
        let followedByTime = index + 1 < tokens.count && ["at", "by", "morning", "evening"].contains(tokens[index + 1].text)
        return (.numeric(first: first, second: second, year: year), index + 1, !followedByTime && parts.count == 2)
    }

    /// "on the 10th", "by 20th", "the 13th" (weak: needs "on"/"by" or to stand as the phrase).
    private static func ordinalDay(_ tokens: [DateToken], _ index: Int) -> (DaySpec, Int, Bool)? {
        let start = tokens[index].text == "the" ? index + 1 : index
        guard let (day, end) = SpokenDateLexicon.ordinal(tokens, start) else { return nil }
        return (.dayOfMonth(day), end, true)
    }

    // MARK: Parts of the day

    static func period(_ tokens: [DateToken], _ index: Int) -> Atom? {
        let fixed: [([String], DayPeriod)] = [
            (["end", "of", "the", "day"], .endOfDay), (["end", "of", "day"], .endOfDay), (["end", "of", "business"], .endOfDay),
            (["close", "of", "business"], .endOfDay), (["eod"], .endOfDay), (["cob"], .endOfDay),
            (["first", "thing", "in", "the", "morning"], .firstThing), (["first", "thing"], .firstThing),
            (["before", "bed"], .beforeBed), (["before", "bedtime"], .beforeBed), (["bedtime"], .beforeBed),
            (["after", "lunch"], .afterLunch), (["before", "lunch"], .beforeLunch), (["lunchtime"], .lunch),
            (["lunch", "time"], .lunch), (["at", "lunch"], .lunch), (["tonight"], .tonight), (["tonite"], .tonight),
            (["midnight"], .midnight), (["same", "time"], .sameTime), (["at", "night"], .night),
        ]
        let lead = ["by", "at", "before", "around"].contains(tokens[index].text) && index + 1 < tokens.count ? index + 1 : index
        for (phrase, period) in fixed {
            for start in (lead == index ? [index] : [index, lead]) where words(tokens, start, phrase.count) == phrase {
                return Atom(kind: .period(period), range: index..<start + phrase.count)
            }
        }
        let parts: [String: DayPeriod] = ["morning": .morning, "afternoon": .afternoon, "evening": .evening, "night": .night]
        for prefix in [["in", "the"], ["this"], ["during", "the"], ["early"], ["late"]] {
            if words(tokens, index, prefix.count) == prefix, index + prefix.count < tokens.count,
               let period = parts[tokens[index + prefix.count].text] {
                return Atom(kind: .period(period), range: index..<index + prefix.count + 1)
            }
        }
        guard let period = parts[tokens[index].text] else { return nil }
        return Atom(kind: .period(period), range: index..<index + 1, isWeak: true)
    }

    // MARK: Clock times

    static func clock(_ tokens: [DateToken], _ index: Int) -> Atom? {
        let hasLead = SpokenDateLexicon.leadIns.contains(tokens[index].text) || words(tokens, index, 2) == ["at", "around"]
        let start = hasLead ? index + (words(tokens, index, 2) == ["at", "around"] ? 2 : 1) : index
        guard start < tokens.count, let (time, afterTime, isMarked) = clockTime(tokens, start) else { return nil }
        var end = afterTime
        var endTime: ClockTime?
        if end + 1 < tokens.count, ["to", "till", "until"].contains(tokens[end].text),
           let (second, afterSecond, _) = clockTime(tokens, end + 1) {
            endTime = second
            end = afterSecond
        }
        var first = time
        if first.isPM == nil, let second = endTime?.isPM {
            // "6 to 7 am", "2 to 3 pm": the second am/pm covers both, unless that runs backwards ("11 to 1 pm").
            first.isPM = (second && first.hour > (endTime?.hour ?? 0) && first.hour != 12) ? false : second
        }
        let marked = hasLead || isMarked || endTime?.isPM != nil
        return Atom(kind: .clock(first, end: endTime), range: index..<end, isWeak: !marked)
    }

    /// One clock time at `index`: (time, index after it, whether am/pm/o'clock/colon marked it).
    static func clockTime(_ tokens: [DateToken], _ index: Int) -> (ClockTime, Int, Bool)? {
        guard index < tokens.count else { return nil }
        if ["noon", "midday"].contains(tokens[index].text) { return (ClockTime(hour: 12, minute: 0, isPM: true), index + 1, true) }
        if let quarter = quarterForm(tokens, index) { return quarter }
        guard var (time, cursor, marked) = hourAndMinute(tokens, index) else { return nil }
        if words(tokens, cursor, 2) == ["o", "clock"] {
            cursor += 2
            marked = true
        } else if cursor < tokens.count, ["oclock", "o'clock", "o’clock"].contains(tokens[cursor].text) {
            cursor += 1
            marked = true
        } else if cursor < tokens.count, tokens[cursor].text == "noon", time.hour == 12 {
            cursor += 1
            marked = true
        }
        if time.isPM == nil, cursor < tokens.count, let isPM = SpokenDateLexicon.meridiems[tokens[cursor].text] {
            time.isPM = isPM
            cursor += 1
            marked = true
        } else if time.isPM == nil, ["a", "p"].contains(word(tokens, cursor)), word(tokens, cursor + 1) == "m" {
            time.isPM = tokens[cursor].text == "p"
            cursor += 2
            marked = true
        }
        guard time.isPM == nil || (1...12).contains(time.hour), (0...23).contains(time.hour) else { return nil }
        return (time, cursor, marked)
    }

    /// "3", "3:30", "3pm", "3:30pm", "four fifteen", "4 15", "4 o 5".
    private static func hourAndMinute(_ tokens: [DateToken], _ index: Int) -> (ClockTime, Int, Bool)? {
        let text = tokens[index].text
        var isPM: Bool?
        var body = Substring(text)
        for (suffix, pm) in [("am", false), ("pm", true), ("a.m", false), ("p.m", true)] where text.hasSuffix(suffix) && text.count > suffix.count {
            let head = text.dropLast(suffix.count)
            if head.first?.isNumber == true { body = head; isPM = pm }
        }
        let pieces = body.split(separator: ":", omittingEmptySubsequences: false)
        if pieces.count == 2, let hour = Int(pieces[0]), pieces[1].count == 2, let minute = Int(pieces[1]), (0...59).contains(minute) {
            return (ClockTime(hour: hour, minute: minute, isPM: isPM), index + 1, true)
        }
        if isPM != nil, let hour = Int(body) { return (ClockTime(hour: hour, minute: 0, isPM: isPM), index + 1, true) }
        guard let (hour, afterHour) = SpokenDateLexicon.number(tokens, index), (0...23).contains(hour) else { return nil }
        guard let (minute, afterMinute) = clockMinute(tokens, afterHour) else {
            return (ClockTime(hour: hour, minute: 0, isPM: nil), afterHour, false)
        }
        return (ClockTime(hour: hour, minute: minute, isPM: nil), afterMinute, false)
    }

    /// The minutes after a spoken hour: "15", "05", "fifteen", "forty five", "oh five".
    private static func clockMinute(_ tokens: [DateToken], _ index: Int) -> (Int, Int)? {
        guard index < tokens.count else { return nil }
        let text = tokens[index].text
        if text.count == 2, text.allSatisfy(\.isNumber), let minute = Int(text), (0...59).contains(minute) { return (minute, index + 1) }
        if ["o", "oh"].contains(text), let (unit, next) = SpokenDateLexicon.number(tokens, index + 1), (1...9).contains(unit) {
            return (unit, next)
        }
        guard text.first?.isNumber == false, let (minute, next) = SpokenDateLexicon.number(tokens, index), (10...59).contains(minute) else { return nil }
        return (minute, next)
    }

    /// "half past 6", "quarter past 4", "quarter to 5".
    private static func quarterForm(_ tokens: [DateToken], _ index: Int) -> (ClockTime, Int, Bool)? {
        var cursor = index
        if tokens[cursor].text == "a" { cursor += 1 }
        guard let offset = ["half": 30, "quarter": 15][word(tokens, cursor)],
              case let relation = word(tokens, cursor + 1), ["past", "to"].contains(relation),
              let (hour, next) = SpokenDateLexicon.number(tokens, cursor + 2), (1...12).contains(hour) else { return nil }
        if relation == "past" { return (ClockTime(hour: hour, minute: offset, isPM: nil), next, true) }
        guard offset == 15 else { return nil }
        return (ClockTime(hour: hour == 1 ? 12 : hour - 1, minute: 45, isPM: nil), next, true)
    }

    /// The token text at `index`, or "" past either end.
    static func word(_ tokens: [DateToken], _ index: Int) -> String {
        tokens.indices.contains(index) ? tokens[index].text : ""
    }
}
