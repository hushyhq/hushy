import Foundation
import MurmurCore

/// Tolerance rules for comparing a predicted tool argument with the expected one. Two levels:
///
/// - **exact**: the same value after trivial normalisation (case, punctuation, whitespace);
///   dates are the same instant (or the same day for a day-only expectation) or one of the
///   expected spoken phrases; lists are the same set; no argument the case didn't expect.
/// - **tolerant**: text compared by token F1 ≥ 0.7 after dropping fillers/articles and folding
///   number words and plurals; names by token containment; a date phrase that `DateAnchor`
///   resolves to the same moment as an expected phrase (or to the expected ISO time), or the
///   same words in another order; lists matched item by item under the same rules; enums
///   through synonyms (messages → imessage). Extra, unexpected arguments are ignored.
///
/// Every rule is argument-kind driven (`VoiceToolParameter.Kind`), so a new tool gets the right
/// comparison from its catalogue entry.
enum ToolArgumentMatcher {
    enum Mode: Sendable { case exact, tolerant }

    /// What the date rules need from the case.
    struct DateContext: Sendable {
        let now: Date
        let timeZone: TimeZone
        let spoken: [String]
        var locale = Locale(identifier: "en_US")
    }

    struct CallComparison: Equatable, Sendable {
        /// Per expected argument: (exact, tolerant).
        var slots: [String: (exact: Bool, tolerant: Bool)]
        /// Arguments the prediction added that the case didn't expect.
        var extras: [String]

        var exact: Bool { extras.isEmpty && slots.values.allSatisfy(\.exact) }
        var tolerant: Bool { slots.values.allSatisfy(\.tolerant) }

        static func == (lhs: Self, rhs: Self) -> Bool {
            lhs.extras == rhs.extras && lhs.slots.mapValues { [$0.exact, $0.tolerant] } == rhs.slots.mapValues { [$0.exact, $0.tolerant] }
        }
    }

    /// Compares arguments of two calls to the same tool.
    static func compare(
        expected: ToolCall, accept: [String: [ToolArgumentValue]] = [:], predicted: ToolCall, dates: DateContext
    ) -> CallComparison {
        let spec = VoiceToolCatalog.tool(named: expected.tool)
        var slots: [String: (exact: Bool, tolerant: Bool)] = [:]
        for (name, value) in expected.arguments {
            let kind = spec?.parameter(named: name)?.kind ?? .text
            let candidates = [value] + (accept[name] ?? [])
            let got = predicted.arguments[name]
            slots[name] = (
                candidates.contains { matches($0, got, kind: kind, mode: .exact, dates: dates) },
                candidates.contains { matches($0, got, kind: kind, mode: .tolerant, dates: dates) })
        }
        let extras = predicted.arguments.filter { !$0.value.isEmpty && expected.arguments[$0.key] == nil }.keys.sorted()
        return CallComparison(slots: slots, extras: extras)
    }

    static func matches(
        _ expected: ToolArgumentValue, _ predicted: ToolArgumentValue?, kind: VoiceToolParameter.Kind, mode: Mode,
        dates: DateContext
    ) -> Bool {
        guard let predicted, !predicted.isEmpty else { return false }
        switch kind {
        case .text: return textMatches(expected.text, predicted.text, mode)
        case .name: return nameMatches(expected.text, predicted.text, mode)
        case .enumeration: return enumMatches(expected.text, predicted.text, mode)
        case .dateTime: return dateMatches(expected.text, predicted.text, mode, dates)
        case .durationMinutes:
            if case .integer(let want) = expected, case .integer(let got) = predicted { return want == got }
            return false
        case .duration:
            guard let want = SpokenDuration.seconds(expected), let got = SpokenDuration.seconds(predicted) else { return false }
            return want == got
        case .nameList: return listMatches(expected.items, predicted.items, mode) { nameMatches($0, $1, mode) }
        case .textList: return listMatches(expected.items, predicted.items, mode) { textMatches($0, $1, mode) }
        }
    }

    // MARK: Text and names

    static func textMatches(_ expected: String, _ predicted: String, _ mode: Mode) -> Bool {
        if EvalText.normalize(expected) == EvalText.normalize(predicted) { return true }
        guard mode == .tolerant else { return false }
        return EvalText.tokenF1(EvalText.contentTokens(expected), EvalText.contentTokens(predicted)) >= 0.7
    }

    static func nameMatches(_ expected: String, _ predicted: String, _ mode: Mode) -> Bool {
        if EvalText.normalize(expected) == EvalText.normalize(predicted) { return true }
        guard mode == .tolerant else { return false }
        let want = EvalText.nameTokens(expected), got = EvalText.nameTokens(predicted)
        guard !want.isEmpty, !got.isEmpty else { return false }
        // "priya" vs "priya sharma", "groceries" vs "grocery list", "dr rao" vs "rao".
        return Set(want).isSubset(of: Set(got)) || Set(got).isSubset(of: Set(want))
    }

    static let enumSynonyms: [String: String] = [
        "messages": "imessage", "message": "imessage", "text": "imessage", "sms": "imessage", "i message": "imessage",
        "ms teams": "teams", "microsoft teams": "teams", "gh": "github", "git hub": "github",
    ]

    static func enumMatches(_ expected: String, _ predicted: String, _ mode: Mode) -> Bool {
        let want = EvalText.normalize(expected), got = EvalText.normalize(predicted)
        if want == got { return true }
        guard mode == .tolerant else { return false }
        return (enumSynonyms[got] ?? got) == (enumSynonyms[want] ?? want)
    }

    // MARK: Lists

    /// Lists compare as sets; tolerant mode first splits "eggs and milk" / "a, b" items and then
    /// needs a one-to-one pairing under the item rule (same count: no dropped, no invented item).
    static func listMatches(_ expected: [String], _ predicted: [String], _ mode: Mode, item: (String, String) -> Bool) -> Bool {
        if mode == .exact {
            return Set(expected.map(EvalText.normalize)) == Set(predicted.map(EvalText.normalize)) && expected.count == predicted.count
        }
        return [predicted, predicted.flatMap(EvalText.splitListItem)].contains { candidate in
            pairsOneToOne(expected, candidate, item: item)
        }
    }

    private static func pairsOneToOne(_ expected: [String], _ predicted: [String], item: (String, String) -> Bool) -> Bool {
        guard predicted.count == expected.count else { return false }
        var remaining = predicted
        for want in expected {
            guard let index = remaining.firstIndex(where: { item(want, $0) }) else { return false }
            remaining.remove(at: index)
        }
        return true
    }

    // MARK: Dates

    static func dateMatches(_ expected: String, _ predicted: String, _ mode: Mode, _ dates: DateContext) -> Bool {
        let dayOnly = isDayOnly(expected)
        if let got = ProposalFields.parseISO8601(predicted) ?? dayDate(predicted, dates.timeZone) {
            return sameMoment(expected, got, dayOnly: dayOnly, dates.timeZone)
        }
        let phrase = EvalText.normalize(predicted)
        let spoken = dates.spoken.map(EvalText.normalize)
        if spoken.contains(phrase) { return true }
        guard mode == .tolerant else { return false }
        // Same words in another order ("9 tomorrow" / "tomorrow at 9").
        let words = Set(EvalText.dateTokens(predicted))
        if spoken.contains(where: { Set(EvalText.dateTokens($0)) == words }) { return true }
        // Same resolver on both sides, so DateAnchor's own anchoring can't create a mismatch.
        guard let resolved = resolve(predicted, dates) else { return false }
        if spoken.contains(where: { resolve($0, dates).map { same(resolved, $0, dayOnly: dayOnly, dates.timeZone) } ?? false }) {
            return true
        }
        return sameMoment(expected, resolved, dayOnly: dayOnly, dates.timeZone)
    }

    static func isDayOnly(_ value: String) -> Bool {
        value.count == 10 && value.filter { $0 == "-" }.count == 2 && value.allSatisfy { $0.isNumber || $0 == "-" }
    }

    private static func dayDate(_ value: String, _ zone: TimeZone) -> Date? {
        guard isDayOnly(value) else { return nil }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = zone
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.date(from: value)
    }

    private static func sameMoment(_ expected: String, _ got: Date, dayOnly: Bool, _ zone: TimeZone) -> Bool {
        guard let want = ProposalFields.parseISO8601(expected) ?? dayDate(expected, zone) else { return false }
        return same(want, got, dayOnly: dayOnly, zone)
    }

    private static func same(_ a: Date, _ b: Date, dayOnly: Bool, _ zone: TimeZone) -> Bool {
        if dayOnly {
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = zone
            return calendar.isDate(a, inSameDayAs: b)
        }
        return abs(a.timeIntervalSince(b)) < 60
    }

    private static func resolve(_ phrase: String, _ dates: DateContext) -> Date? {
        DateAnchor.firstDate(in: phrase, context: MurmurCore.DateContext(now: dates.now, timeZone: dates.timeZone, locale: dates.locale))?.start
    }
}

private extension ToolArgumentValue {
    var text: String {
        switch self {
        case .string(let value): value
        case .integer(let value): String(value)
        case .strings(let values): values.joined(separator: ", ")
        }
    }

    var items: [String] {
        switch self {
        case .strings(let values): values
        case .string(let value): [value]
        case .integer(let value): [String(value)]
        }
    }
}

/// Text normalisation shared by the tolerance rules.
enum EvalText {
    static func normalize(_ text: String) -> String {
        let mapped = text.lowercased().unicodeScalars.map { CharacterSet.alphanumerics.contains($0) ? Character($0) : " " }
        return String(mapped).split(separator: " ").joined(separator: " ")
    }

    static let fillers: Set<String> = ["a", "an", "the", "my", "our", "please", "uh", "um", "umm", "erm", "hmm", "to", "of", "some", "kindly"]
    static let honorifics: Set<String> = ["mr", "mrs", "ms", "dr", "ji", "sir", "madam", "list", "app", "shortcut", "calendar", "channel"]
    static let dateFillers: Set<String> = ["at", "on", "by", "the", "for", "o", "clock", "oclock"]

    static let numberWords: [String: String] = [
        "zero": "0", "one": "1", "two": "2", "three": "3", "four": "4", "five": "5", "six": "6", "seven": "7",
        "eight": "8", "nine": "9", "ten": "10", "eleven": "11", "twelve": "12", "fifteen": "15", "twenty": "20",
        "thirty": "30", "forty": "40", "fifty": "50", "sixty": "60", "ninety": "90",
    ]

    static func fold(_ token: String) -> String {
        if let digit = numberWords[token] { return digit }
        if token.count > 4, token.hasSuffix("ies") { return String(token.dropLast(3)) + "y" }
        if token.count > 3, token.hasSuffix("s"), !token.hasSuffix("ss") { return String(token.dropLast()) }
        return token
    }

    static func contentTokens(_ text: String) -> [String] {
        normalize(text).split(separator: " ").map(String.init).filter { !fillers.contains($0) }.map(fold)
    }

    static func nameTokens(_ text: String) -> [String] {
        contentTokens(text).filter { !honorifics.contains($0) }
    }

    static func dateTokens(_ text: String) -> [String] {
        normalize(text).split(separator: " ").map(String.init).filter { !dateFillers.contains($0) }.map(fold)
    }

    /// Token-multiset F1 (1 when both are empty).
    static func tokenF1(_ expected: [String], _ predicted: [String]) -> Double {
        if expected.isEmpty && predicted.isEmpty { return 1 }
        guard !expected.isEmpty, !predicted.isEmpty else { return 0 }
        var pool = expected
        var overlap = 0
        for token in predicted {
            if let index = pool.firstIndex(of: token) {
                pool.remove(at: index)
                overlap += 1
            }
        }
        guard overlap > 0 else { return 0 }
        let precision = Double(overlap) / Double(predicted.count)
        let recall = Double(overlap) / Double(expected.count)
        return 2 * precision * recall / (precision + recall)
    }

    /// "eggs, milk and bread" → ["eggs", "milk", "bread"].
    static func splitListItem(_ item: String) -> [String] {
        item.replacingOccurrences(of: " and ", with: ",").replacingOccurrences(of: " & ", with: ",")
            .split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }
}
