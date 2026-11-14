import Foundation

/// The pieces of one spoken date phrase, grouped from adjacent atoms.
struct DatePhrase: Sendable, Equatable {
    var day: DaySpec?
    var clock: ClockTime?
    var clockEnd: ClockTime?
    var period: DayPeriod?
    var elapsed: TimeInterval?
    /// Token ranges the phrase came from (two when a time and a day were said apart).
    var spans: [Range<Int>] = []

    var isEmpty: Bool { day == nil && clock == nil && period == nil && elapsed == nil }

    /// The first phrase in the text. Atoms separated only by connectors ("tomorrow *at* 9")
    /// form one phrase; a day said elsewhere completes a time-only phrase ("at 5 to call mom
    /// tomorrow"), and an "at …" time said elsewhere completes a day-only one.
    static func primary(from atoms: [RelativeDateParser.Atom], tokens: [DateToken]) -> DatePhrase? {
        let clusters = group(atoms, tokens: tokens)
        guard var phrase = clusters.first else { return nil }
        // Self-corrections: a later phrase right after "no" / "i mean" / "actually" restates the
        // earlier one ("at 3 no 4", "tomorrow at 8 i mean 9", "tuesday sorry wednesday at 11").
        var used = 1
        while used < clusters.count, phrase.isCorrected(by: clusters[used], tokens: tokens) {
            phrase = phrase.corrected(by: clusters[used])
            used += 1
        }
        let rest = clusters.dropFirst(used)
        // "tonight" already names the day.
        if phrase.day == nil, phrase.elapsed == nil, phrase.period != .tonight,
           let dayOnly = rest.first(where: { $0.day != nil && $0.clock == nil && $0.period == nil && $0.elapsed == nil }) {
            phrase.day = dayOnly.day
            phrase.spans += dayOnly.spans
        }
        if phrase.clock == nil, phrase.period == nil, phrase.elapsed == nil,
           let timeOnly = rest.first(where: { $0.clock != nil && $0.day == nil && $0.elapsed == nil }),
           let first = timeOnly.spans.first, SpokenDateLexicon.leadIns.contains(tokens[first.lowerBound].text) {
            phrase.clock = timeOnly.clock
            phrase.clockEnd = timeOnly.clockEnd
            phrase.period = phrase.period ?? timeOnly.period
            phrase.spans += timeOnly.spans
        }
        phrase.spans.sort { $0.lowerBound < $1.lowerBound }
        return phrase
    }

    /// Whether `later` follows this phrase after a correction marker, within a few words.
    func isCorrected(by later: DatePhrase, tokens: [DateToken]) -> Bool {
        guard let end = spans.last?.upperBound, let start = later.spans.first?.lowerBound, start > end, start - end <= 4 else {
            return false
        }
        return (end..<start).contains { SpokenDateLexicon.correctionEnds(at: $0, in: tokens) }
    }

    /// This phrase with whatever `later` restates replaced; the rest is kept ("tomorrow at 8 i
    /// mean 9" keeps tomorrow). "same time" after a correction means the time already said.
    func corrected(by later: DatePhrase) -> DatePhrase {
        var merged = later.elapsed != nil ? later : self
        if later.elapsed == nil {
            merged.elapsed = nil
            if let day = later.day { merged.day = day }
            if let clock = later.clock {
                merged.clock = clock
                merged.clockEnd = later.clockEnd
            }
            if let period = later.period, !(period == .sameTime && clock != nil) { merged.period = period }
        }
        if let first = spans.first?.lowerBound, let last = later.spans.last?.upperBound {
            merged.spans = [first..<last]
        }
        return merged
    }

    private static func group(_ atoms: [RelativeDateParser.Atom], tokens: [DateToken]) -> [DatePhrase] {
        var phrases: [DatePhrase] = []
        var current = DatePhrase()
        var span: Range<Int>?
        for atom in atoms {
            let joins = span.map { previous in
                (previous.upperBound..<atom.range.lowerBound).allSatisfy { SpokenDateLexicon.connectors.contains(tokens[$0].text) }
            } ?? false
            if !joins || !current.accepts(atom.kind) {
                if let span { current.spans = [span]; phrases.append(current) }
                current = DatePhrase()
                span = nil
            }
            current.add(atom.kind)
            span = span.map { $0.lowerBound..<atom.range.upperBound } ?? atom.range
        }
        if let span { current.spans = [span]; phrases.append(current) }
        return phrases.filter { !$0.isEmpty }
    }

    private func accepts(_ kind: RelativeDateParser.Kind) -> Bool {
        switch kind {
        case .day: day == nil && elapsed == nil
        case .clock: clock == nil && elapsed == nil
        case .period: period == nil && elapsed == nil
        case .elapsed: isEmpty
        }
    }

    private mutating func add(_ kind: RelativeDateParser.Kind) {
        switch kind {
        case .day(let spec): day = spec
        case .clock(let time, let end): clock = time; clockEnd = end
        case .period(let part): period = part
        case .elapsed(let seconds): elapsed = seconds
        }
    }
}

/// Turns a `DatePhrase` into a start (and optional end) in the context's zone.
///
/// Defaults, chosen to match what people mean and documented in DECISIONS.md:
/// - Elapsed spans ("in 3 hours") are real elapsed time, so they stay right across DST changes;
///   day offsets keep the wall-clock time of day.
/// - "friday", "on friday", "next friday": the next Friday after today; "this friday": today
///   counts. "next week": the coming Monday.
/// - An hour without am/pm: 1–6 → afternoon, 7–11 → morning, 12 → noon, unless a part of the day
///   says otherwise ("evening 7", "9 tonight"). With no day, a time already past today moves to
///   tomorrow ("at 9" at 3 pm → 9 am tomorrow); with "today" said, the other half of the day is
///   tried first ("today at 9" at 3 pm → 9 pm).
/// - A day with no time: 9:00. Parts of the day: morning 9:00, afternoon 14:00, evening 18:00,
///   tonight 20:00, night 21:00, end of day 17:00, after lunch 14:00, before bed 22:00, midnight
///   23:59. A part of today that has already passed ("tonight" at 21:10) becomes the next half hour.
enum RelativeDateResolver {
    static func resolve(_ phrase: DatePhrase, context: DateContext) -> (start: Date, end: Date?)? {
        let calendar = context.calendar
        if let seconds = phrase.elapsed { return (context.now.addingTimeInterval(seconds), nil) }
        let today = calendar.startOfDay(for: context.now)
        var dayStart: Date?
        if let spec = phrase.day {
            guard let resolved = day(spec, today: today, context: context) else { return nil }
            dayStart = resolved
        }
        if phrase.day == .endOfWeek, phrase.clock == nil, phrase.period == nil {
            return at(dayStart ?? today, hour: 17, minute: 0, calendar).map { ($0, nil) }
        }
        guard let start = time(phrase, dayStart: dayStart, today: today, context: context) else { return nil }
        return (start, phrase.clockEnd.flatMap { endTime($0, after: start, period: phrase.period, calendar: calendar) })
    }

    // MARK: Days

    static func day(_ spec: DaySpec, today: Date, context: DateContext) -> Date? {
        let calendar = context.calendar
        switch spec {
        case .offset(let days):
            return calendar.date(byAdding: .day, value: days, to: today)
        case .weekday(let weekday, let minimumAhead):
            return next(weekday: weekday, minimumAhead: minimumAhead, from: today, calendar)
        case .nextWeek:
            return next(weekday: 2, minimumAhead: 1, from: today, calendar)
        case .weekend:
            let weekday = calendar.component(.weekday, from: today)
            return weekday == 1 || weekday == 7 ? today : next(weekday: 7, minimumAhead: 0, from: today, calendar)
        case .endOfWeek:
            return next(weekday: 6, minimumAhead: 0, from: today, calendar)
        case .dayOfMonth(let dayNumber):
            return nextOccurrence(month: nil, day: dayNumber, from: today, calendar)
        case .monthDay(let month, let dayNumber, let year):
            return date(year: year, month: month, day: dayNumber, from: today, calendar)
        case .numeric(let first, let second, let year):
            // A number above 12 can only be the day; otherwise the locale decides.
            let dayFirst = first > 12 ? true : (second > 12 ? false : context.prefersDayFirst)
            return date(year: year, month: dayFirst ? second : first, day: dayFirst ? first : second, from: today, calendar)
        }
    }

    private static func next(weekday: Int, minimumAhead: Int, from today: Date, _ calendar: Calendar) -> Date? {
        let current = calendar.component(.weekday, from: today)
        var delta = (weekday - current + 7) % 7
        if delta < minimumAhead % 7 { delta += 7 }
        if minimumAhead >= 7 { delta += 7 * (minimumAhead / 7) }
        return calendar.date(byAdding: .day, value: delta, to: today)
    }

    private static func date(year: Int?, month: Int, day: Int, from today: Date, _ calendar: Calendar) -> Date? {
        guard (1...12).contains(month) else { return nil }
        guard let year else { return nextOccurrence(month: month, day: day, from: today, calendar) }
        guard let date = calendar.date(from: DateComponents(year: year, month: month, day: day)),
              calendar.component(.day, from: date) == day else { return nil }
        return date
    }

    /// The first `day` (of `month`, when given) on or after today, skipping months without it.
    private static func nextOccurrence(month: Int?, day: Int, from today: Date, _ calendar: Calendar) -> Date? {
        let components = calendar.dateComponents([.year, .month], from: today)
        guard let year = components.year, let thisMonth = components.month else { return nil }
        for step in 0..<(month == nil ? 13 : 3) {
            let candidateYear = month == nil ? year + (thisMonth - 1 + step) / 12 : year + step
            let candidateMonth = month ?? ((thisMonth - 1 + step) % 12 + 1)
            guard let date = calendar.date(from: DateComponents(year: candidateYear, month: candidateMonth, day: day)),
                  calendar.component(.day, from: date) == day, date >= today else { continue }
            return date
        }
        return nil
    }

    // MARK: Times

    private static func time(_ phrase: DatePhrase, dayStart: Date?, today: Date, context: DateContext) -> Date? {
        let calendar = context.calendar
        let now = context.now
        if let clock = phrase.clock {
            let (hour, isAmbiguous) = hour24(clock, period: phrase.period)
            let base = dayStart ?? today
            guard let preferred = at(base, hour: hour, minute: clock.minute, calendar) else { return nil }
            if dayStart == nil {
                return preferred > now ? preferred : calendar.date(byAdding: .day, value: 1, to: preferred)
            }
            // "today at 9" at 3 pm: the other half of the day, if that is still ahead.
            if isAmbiguous, preferred <= now, calendar.isDate(base, inSameDayAs: now),
               let other = at(base, hour: (hour + 12) % 24, minute: clock.minute, calendar), other > now {
                return other
            }
            return preferred
        }
        guard let period = phrase.period else {
            return dayStart.flatMap { at($0, hour: 9, minute: 0, calendar) }
        }
        let (hour, minute) = defaultTime(period, now: now, calendar: calendar)
        guard let candidate = at(dayStart ?? today, hour: hour, minute: minute, calendar) else { return nil }
        guard candidate <= now, calendar.isDate(candidate, inSameDayAs: now) else { return candidate }
        if dayStart == nil, [.morning, .firstThing, .sameTime].contains(period) {
            return calendar.date(byAdding: .day, value: 1, to: candidate)
        }
        return nextHalfHour(after: now, calendar)
    }

    /// The 24-hour hour for a spoken clock time, and whether am/pm was a guess.
    static func hour24(_ clock: ClockTime, period: DayPeriod?) -> (Int, Bool) {
        if let isPM = clock.isPM { return (clock.hour % 12 + (isPM ? 12 : 0), false) }
        if clock.hour == 0 || clock.hour > 12 { return (clock.hour, false) }
        if let period {
            if period == .morning || period == .firstThing { return (clock.hour % 12, false) }
            if period.isAfternoonish { return (clock.hour == 12 ? 12 : clock.hour + 12, false) }
        }
        switch clock.hour {
        case 12: return (12, true)
        case 1...6: return (clock.hour + 12, true)
        default: return (clock.hour, true)
        }
    }

    private static func defaultTime(_ period: DayPeriod, now: Date, calendar: Calendar) -> (Int, Int) {
        switch period {
        case .morning, .firstThing: (9, 0)
        case .afternoon, .afterLunch: (14, 0)
        case .evening: (18, 0)
        case .tonight: (20, 0)
        case .night: (21, 0)
        case .endOfDay: (17, 0)
        case .beforeBed: (22, 0)
        case .beforeLunch: (11, 30)
        case .lunch: (12, 30)
        case .midnight: (23, 59)
        case .sameTime: (calendar.component(.hour, from: now), calendar.component(.minute, from: now))
        }
    }

    private static func endTime(_ clock: ClockTime, after start: Date, period: DayPeriod?, calendar: Calendar) -> Date? {
        let (hour, isAmbiguous) = hour24(clock, period: period)
        guard var end = at(start, hour: hour, minute: clock.minute, calendar) else { return nil }
        if end <= start, isAmbiguous, let later = at(start, hour: (hour + 12) % 24, minute: clock.minute, calendar), later > start {
            end = later
        }
        if end <= start { end = calendar.date(byAdding: .day, value: 1, to: end) ?? end }
        return end
    }

    /// `hour:minute` on the day of `day`, in the calendar's zone (a DST gap moves forward).
    static func at(_ day: Date, hour: Int, minute: Int, _ calendar: Calendar) -> Date? {
        var components = calendar.dateComponents([.year, .month, .day], from: day)
        components.hour = hour
        components.minute = minute
        components.second = 0
        return calendar.date(from: components)
    }

    private static func nextHalfHour(after now: Date, _ calendar: Calendar) -> Date? {
        let wholeMinute = Date(timeIntervalSinceReferenceDate: (now.timeIntervalSinceReferenceDate / 60).rounded(.down) * 60)
        let minute = calendar.component(.minute, from: wholeMinute)
        return wholeMinute.addingTimeInterval(TimeInterval((minute < 30 ? 30 - minute : 60 - minute) * 60))
    }
}
