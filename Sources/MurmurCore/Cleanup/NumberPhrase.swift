import Foundation

/// Where a spoken number, date or time phrase runs across two adjacent words, so a long run-on
/// is never cut between them (`RunOnChunker`). Each group is cleaned on its own, so a cut inside
/// "two hundred | and twenty five" became "200, and 25" once each half had been converted to
/// digits (`InverseTextNormalizer`) and the seam repaired; a cut inside "March | twenty first" or
/// "four | fifteen" loses the date or time the same way.
///
/// Deliberately broad: a cut is only ever moved a word or two, so keeping two unrelated numbers
/// together ("three | twenty dollar bills") costs nothing, while splitting one number loses it.
enum NumberPhrase {
    /// True when cutting before `keys[index]` would split a number, date or time phrase.
    /// `keys` are `LegitDoubles.key` tokens (lowercased, edge punctuation stripped).
    static func isInside(_ keys: [String], cutBefore index: Int) -> Bool {
        guard index > 0, index < keys.count else { return false }
        let previous = keys[index - 1]
        let word = keys[index]
        let next = index + 1 < keys.count ? keys[index + 1] : ""
        // "two | hundred", "four | fifteen", "three point | five", "twenty five | percent"
        if isNumeric(keys, at: index - 1), isNumeric(keys, at: index) || units.contains(word) { return true }
        // "two hundred | and twenty five", "two hundred and | twenty five"
        if word == "and", scaleWords.contains(previous), isNumberWord(next) { return true }
        if previous == "and", index >= 2, scaleWords.contains(keys[index - 2]), isNumberWord(word) { return true }
        // "the | twenty first of March"
        if previous == "the", isNumberWord(word) { return true }
        // "March | twenty first", "March | the twenty first"
        if isMonth(previous), isNumberWord(word) || word == "the" && isNumberWord(next) { return true }
        // "the twenty first | of March", "the twenty first of | March"
        if word == "of", isNumberWord(previous), isMonth(next) { return true }
        if previous == "of", isMonth(word), index >= 2, isNumberWord(keys[index - 2]) { return true }
        return false
    }

    /// Words that finish a number phrase ("forty five percent", "nine thirty pm").
    private static let units: Set<String> = [
        "percent", "dollar", "dollars", "cent", "cents", "bucks", "am", "pm", "a.m", "p.m", "o'clock",
    ]
    private static let scaleWords = Set(InverseTextNormalizer.scales.keys)
    private static let lexicon: Set<String> = InverseTextNormalizer.allDigitWords
        .union(InverseTextNormalizer.scales.keys)
        .union(InverseTextNormalizer.ordinalWords.keys)
        .union(["point"])
    private static let monthNames = Set(InverseTextNormalizer.months.map { $0.lowercased() })

    /// A number word, ordinal, hyphenated compound ("twenty-five", "twenty-first") or digits.
    static func isNumberWord(_ key: String) -> Bool {
        if lexicon.contains(key) { return true }
        if let first = key.first, first.isNumber { return key.allSatisfy { $0.isNumber || $0 == "." || $0 == "," } }
        let parts = key.split(separator: "-")
        return parts.count > 1 && parts.allSatisfy { lexicon.contains(String($0)) }
    }

    /// A number word, or the "oh" of a clock time between two of them ("four oh five").
    private static func isNumeric(_ keys: [String], at index: Int) -> Bool {
        if isNumberWord(keys[index]) { return true }
        return keys[index] == "oh" && index > 0 && index + 1 < keys.count
            && isNumberWord(keys[index - 1]) && isNumberWord(keys[index + 1])
    }

    private static func isMonth(_ key: String) -> Bool { monthNames.contains(key) }
}
