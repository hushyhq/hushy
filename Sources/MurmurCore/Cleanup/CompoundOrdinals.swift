import Foundation

/// A tens word and an ordinal unit spoken together, "twenty eighth" or "thirty first", are one ordinal number.
/// The cardinal pass read them as two ("the 20 eighth", "20 sixth"), which handed the model a number nobody said.
/// Only a date shaped "the twenty third of March" or "March the twenty third" was joined
/// (`InverseTextNormalizer.convertOrdinalDates`). The rule here: a compound ordinal, with "one hundred and" or another
/// hundreds before it ("one hundred and twenty third" is 123rd), is one number when it names a day or a place in
/// an order, and is left exactly as the rules wrote it when it may name something else. It is a date after a month
/// or before "of" a month ("March 28"); it is written with its suffix ("the 26th", "finished 26th") after "the" or
/// a possessive, before a singular noun or no noun at all. It is left alone when it is a fraction (a number word,
/// "a" or "an" in front and "of" after: "one twenty fifth of the budget"), when it is a count of things named by
/// an ordinal (no "the" or possessive and a plural noun after: "twenty first graders"), and when "second" could be
/// a unit of time ("a twenty second timeout"), where "second" joins only after a month or before "of".
/// A plural is recognised by its ending, so a verb in "-s" right after a bare compound ("twenty sixth starts") is
/// read as a plural and left alone. Ordinals above 999 are not joined.
enum CompoundOrdinals {
    static func apply(_ text: String) -> String {
        let months = InverseTextNormalizer.months.map(Regex.escape).joined(separator: "|")
        var out = rewrite(text, "\\b(\(months))\\s+(?:the\\s+)?(\(compound))\\b") { groups, _, _ in
            date(month: groups[safe: 1], ordinal: groups[safe: 2])
        }
        out = rewrite(out, "\\b(?:the\\s+)?(\(compound))\\s+of\\s+(\(months))\\b") { groups, _, _ in
            date(month: groups[safe: 2], ordinal: groups[safe: 1])
        }
        let lead = "(?:(the|my|our|your|his|her|their|its)\\s+)?"
        return rewrite(out, "\\b\(lead)(\(hundreds)?\(compound))\\b") { groups, before, after in
            written(ordinal: groups[safe: 2], lead: groups[safe: 1] ?? "", before: before, after: after)
        }
    }

    private static let tens = "(?:twenty|thirty|forty|fifty|sixty|seventy|eighty|ninety)"
    private static let units = "(?:first|second|third|fourth|fifth|sixth|seventh|eighth|ninth)"
    private static let compound = "(?:\(tens)[\\s-]+\(units))"
    private static let hundreds = "(?:(?:a|one|two|three|four|five|six|seven|eight|nine)\\s+hundred(?:\\s+and)?\\s+)"

    /// Replaces each match of `pattern` with `transform(groups, wordBefore, wordAfter)`, or leaves it when that is nil.
    private static func rewrite(
        _ text: String, _ pattern: String, _ transform: ([String], String, String) -> String?
    ) -> String {
        guard let regex = RegexCache.compiled(pattern, caseInsensitive: true) else { return text }
        let source = text as NSString
        var result = ""
        var cursor = 0
        for match in regex.matches(in: text, range: NSRange(location: 0, length: source.length)) {
            let groups = (0..<match.numberOfRanges).map { index -> String in
                let range = match.range(at: index)
                return range.location == NSNotFound ? "" : source.substring(with: range)
            }
            let before = lastWord(of: source.substring(to: match.range.location))
            let after = firstWord(of: source.substring(from: match.range.location + match.range.length))
            result += source.substring(with: NSRange(location: cursor, length: match.range.location - cursor))
            result += transform(groups, before, after) ?? groups[0]
            cursor = match.range.location + match.range.length
        }
        return result + source.substring(from: cursor)
    }

    private static func lastWord(of text: String) -> String { clean(text.split(whereSeparator: \.isWhitespace).last) }
    private static func firstWord(of text: String) -> String { clean(text.split(whereSeparator: \.isWhitespace).first) }
    private static func clean(_ word: Substring?) -> String {
        word.map { $0.lowercased().trimmingCharacters(in: .punctuationCharacters) } ?? ""
    }

    /// "Month D", the form the other ordinal dates take.
    private static func date(month: String?, ordinal: String?) -> String? {
        guard let month, let ordinal, let value = value(of: ordinal),
              let name = InverseTextNormalizer.months.first(where: { $0.lowercased() == month.lowercased() })
        else { return nil }
        return "\(name) \(value)"
    }

    /// "the 26th": the number with its suffix, keeping the determiner that led it; nil where the phrase is left alone.
    private static func written(ordinal: String?, lead: String, before: String, after: String) -> String? {
        guard let ordinal, let value = value(of: ordinal) else { return nil }
        let isFraction = lead.isEmpty && after == "of" && (["a", "an"].contains(before) || NumberPhrase.isNumberWord(before))
        if isFraction { return nil }
        if lead.isEmpty, looksPlural(after) { return nil }
        if value % 10 == 2, after != "of" { return nil }
        let leading = lead.isEmpty ? "" : lead + " "
        return leading + "\(value)\(suffix(of: value))"
    }

    private static func looksPlural(_ word: String) -> Bool {
        guard word.count > 3, word.hasSuffix("s"), !["ss", "us", "is"].contains(where: word.hasSuffix) else { return false }
        return !TokenLexicon.functionWords.contains(word)
    }

    /// The value of "twenty eighth" or "one hundred and twenty eighth"; nil when it cannot be read.
    private static func value(of ordinal: String) -> Int? {
        let words = ordinal.lowercased().split(whereSeparator: { !$0.isLetter }).map(String.init)
        guard words.count >= 2, let tensValue = InverseTextNormalizer.tens[words[words.count - 2]],
              let unit = InverseTextNormalizer.ordinalWords[words[words.count - 1]], unit < 10
        else { return nil }
        let prefix = words.dropLast(2).filter { $0 != "and" }
        guard !prefix.isEmpty else { return tensValue + unit }
        let hundred = prefix == ["a", "hundred"] ? 100 : InverseTextNormalizer.parseCardinal(prefix.joined(separator: " "))
        guard let hundred, hundred % 100 == 0 else { return nil }
        return hundred + tensValue + unit
    }

    static func suffix(of value: Int) -> String {
        if (11...13).contains(value % 100) { return "th" }
        switch value % 10 {
        case 1: return "st"
        case 2: return "nd"
        case 3: return "rd"
        default: return "th"
        }
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
