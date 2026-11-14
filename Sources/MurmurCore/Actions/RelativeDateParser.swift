import Foundation

/// A deterministic parser for the spoken date/time phrases voice commands actually use, run
/// before `NSDataDetector` in `DateAnchor`. The detector misses most relative and spoken forms
/// ("in 3 hours", "at 4 15", "on the 10th", "by eod", "day after tomorrow", "evening 7",
/// "12/10" day-first) and can only resolve against the real clock; this parser resolves against
/// an injected `DateContext` (clock, zone, locale), so it is testable and DST-correct.
///
/// Shape: the text is split into tokens, scanned for *atoms* (a day, a clock time, a part of the
/// day, or an elapsed span), adjacent atoms are grouped into one phrase, and the phrase is
/// resolved by `RelativeDateResolver`. A bare number is only a time when something marks it as
/// one ("at 5", "5 pm", "5 o clock", "tomorrow 10", "evening 7"), so "buy 2 dozen eggs" never
/// gets a date. Ambiguity rules are documented on `RelativeDateResolver`.
enum RelativeDateParser {
    struct Result: Sendable, Equatable {
        let start: Date
        let end: Date?
        let sourcePhrase: String
    }

    /// The first date phrase in `text`, resolved against `context`; nil when there is none.
    static func parse(_ text: String, context: DateContext) -> Result? {
        let tokens = SpokenDateLexicon.tokens(in: text)
        guard !tokens.isEmpty else { return nil }
        let atoms = keptAtoms(scan(tokens), tokens: tokens)
        guard let phrase = DatePhrase.primary(from: atoms, tokens: tokens) else { return nil }
        guard let resolved = RelativeDateResolver.resolve(phrase, context: context) else { return nil }
        let source = phrase.spans.map { String(text[tokens[$0.lowerBound].range.lowerBound..<tokens[$0.upperBound - 1].range.upperBound]) }
        return Result(start: resolved.start, end: resolved.end, sourcePhrase: source.joined(separator: " "))
    }

    // MARK: Atoms

    struct Atom: Sendable, Equatable {
        let kind: Kind
        /// Token indexes, lead-in preposition included.
        let range: Range<Int>
        /// Needs a neighbouring atom (or the whole text being a date phrase) to count.
        var isWeak = false
    }

    enum Kind: Sendable, Equatable {
        case day(DaySpec)
        case clock(ClockTime, end: ClockTime?)
        case period(DayPeriod)
        case elapsed(seconds: TimeInterval)
    }

    static func scan(_ tokens: [DateToken]) -> [Atom] {
        var atoms: [Atom] = []
        var index = 0
        while index < tokens.count {
            // Parts of the day before days, so "first thing" isn't read as "the 1st".
            let match = elapsed(tokens, index) ?? period(tokens, index) ?? day(tokens, index) ?? clock(tokens, index)
            if let match {
                atoms.append(match)
                index = match.range.upperBound
            } else {
                index += 1
            }
        }
        return atoms
    }

    /// Drops weak atoms that stand alone, unless the whole text is one date phrase (the model's
    /// own `when` copy, e.g. just "4" or "the 13th").
    static func keptAtoms(_ atoms: [Atom], tokens: [DateToken]) -> [Atom] {
        var covered = Set<Int>()
        for atom in atoms { covered.formUnion(atom.range) }
        let wholePhrase = tokens.indices.allSatisfy { covered.contains($0) || SpokenDateLexicon.connectors.contains(tokens[$0].text) }
        if wholePhrase { return atoms }
        return atoms.enumerated().filter { offset, atom in
            guard atom.isWeak else { return true }
            // The corrected value after "no", "i mean", "actually": "at 3 no 4", "the 12th wait the 13th".
            if SpokenDateLexicon.correctionEnds(at: atom.range.lowerBound - 1, in: tokens) { return true }
            let before = offset > 0 && atoms[offset - 1].range.upperBound == atom.range.lowerBound && supports(atoms[offset - 1], atom)
            var after = offset + 1 < atoms.count && atoms[offset + 1].range.lowerBound == atom.range.upperBound && supports(atoms[offset + 1], atom)
            // A bare hour before a day is a count, not a time ("a 1 on 1 next tuesday"); with
            // minutes it is a time ("12 30 tomorrow").
            if after, case .clock(let time, nil) = atom.kind, time.minute == 0, case .day = atoms[offset + 1].kind { after = false }
            guard before || after else { return false }
            // "tomorrow 3 kids": a weak time must not run into an ordinary word.
            guard case .clock = atom.kind, atom.range.upperBound < tokens.count, !after else { return true }
            let next = tokens[atom.range.upperBound].text
            return SpokenDateLexicon.connectors.contains(next) || next == "to"
        }.map(\.element)
    }

    /// A strong neighbour supports a weak atom; a bare part of the day and a bare hour support
    /// each other ("evening 7", "morning 9" — common Indian-English order).
    private static func supports(_ neighbour: Atom, _ atom: Atom) -> Bool {
        if !neighbour.isWeak { return true }
        switch (neighbour.kind, atom.kind) {
        case (.period, .clock), (.clock, .period): return true
        default: return false
        }
    }

    // MARK: Elapsed spans ("in 20 minutes", "after 2 hours", "in 3 days", "an hour from now")

    private static func elapsed(_ tokens: [DateToken], _ index: Int) -> Atom? {
        let hasLead = ["in", "after", "within"].contains(tokens[index].text)
        var cursor = hasLead ? index + 1 : index
        guard let (amount, afterAmount) = elapsedAmount(tokens, cursor) else { return nil }
        cursor = afterAmount
        guard cursor < tokens.count, let unit = elapsedUnit(tokens[cursor].text) else { return nil }
        cursor += 1
        var total = amount
        if cursor + 2 < tokens.count, tokens[cursor].text == "and", tokens[cursor + 1].text == "a", tokens[cursor + 2].text == "half" {
            total += 0.5
            cursor += 3
        }
        var trailing = false
        if cursor + 1 < tokens.count, tokens[cursor].text == "from", ["now", "today"].contains(tokens[cursor + 1].text) {
            cursor += 2
            trailing = true
        } else if cursor < tokens.count, tokens[cursor].text == "later" {
            cursor += 1
            trailing = true
        }
        // "in 30 minutes no an hour": the corrected span needs no "in" of its own.
        guard hasLead || trailing || SpokenDateLexicon.correctionEnds(at: index - 1, in: tokens) else { return nil }
        let range = index..<cursor
        switch unit {
        case .minute: return Atom(kind: .elapsed(seconds: total * 60), range: range)
        case .hour: return Atom(kind: .elapsed(seconds: total * 3_600), range: range)
        case .day, .week:
            let days = total * (unit == .week ? 7 : 1)
            guard days == days.rounded() else { return nil }
            return Atom(kind: .day(.offset(Int(days))), range: range)
        }
    }

    private enum ElapsedUnit { case minute, hour, day, week }

    private static func elapsedUnit(_ word: String) -> ElapsedUnit? {
        switch word {
        case "minute", "minutes", "min", "mins": .minute
        case "hour", "hours", "hr", "hrs": .hour
        case "day", "days": .day
        case "week", "weeks": .week
        default: nil
        }
    }

    private static func elapsedAmount(_ tokens: [DateToken], _ index: Int) -> (Double, Int)? {
        guard index < tokens.count else { return nil }
        let word = tokens[index].text
        let next = index + 1 < tokens.count ? tokens[index + 1].text : ""
        if word == "half", ["an", "a"].contains(next) { return (0.5, index + 2) }
        // "a couple of hours", "couple of hours", "a couple hours".
        if (word == "a" && next == "couple") || word == "couple" {
            var cursor = index + (word == "a" ? 2 : 1)
            if cursor < tokens.count, tokens[cursor].text == "of" { cursor += 1 }
            return (2, cursor)
        }
        if ["a", "an"].contains(word) { return (1, index + 1) }
        guard let (value, after) = SpokenDateLexicon.number(tokens, index) else { return nil }
        if after + 2 < tokens.count, tokens[after].text == "and", tokens[after + 1].text == "a", tokens[after + 2].text == "half" {
            return (Double(value) + 0.5, after + 3)
        }
        return (Double(value), after)
    }
}
