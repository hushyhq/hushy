import Foundation

/// The words that carry a meeting line's meaning, written one way however they were said or
/// typed: "4k/mo for Q1", "$4,000 a month for the first quarter" and "four thousand a month for
/// the first quarter" all become {4000, month, q1}. Shared by the moment locator (row → turn) and
/// the repeat check (the person's line → the model's restatement of it).
public enum MeetingWords {
    /// Content words of three letters or more minus common words, plus every number-like token
    /// whatever its length ("q1", "4000", "1"), stemmed so "sends" meets "send".
    public static func content(_ text: String) -> Set<String> {
        let tokens = canonicalTokens(text)
        return Set(tokens.filter { token in
            token.contains(where: \.isNumber) || (token.count >= 3 && !MeetingMomentLocator.stopWords.contains(token))
        }.map(MeetingMomentLocator.stem))
    }

    /// Whether `b` says the same as `a`: at least two shared meaning words, covering most of the
    /// shorter line. A one-word line never counts as a repeat, so "ship it" never swallows "ship
    /// the beta on Monday", and different numbers ("$4k" against "$5k") keep two lines apart.
    public static func restates(_ a: Set<String>, _ b: Set<String>) -> Bool {
        let shared = a.intersection(b).count
        let shorter = min(a.count, b.count)
        guard shared >= 2 else { return false }
        if a.contains(where: isNumeric) && b.contains(where: isNumeric),
           a.filter(isNumeric).isDisjoint(with: b.filter(isNumeric)) { return false }
        return Double(shared) >= 0.6 * Double(shorter)
    }

    /// Drops a line that says the same as an earlier one, so the person's own wording wins over
    /// the model's restatement of it.
    public static func withoutRepeats(_ lines: [String]) -> [String] {
        var kept: [(text: String, words: Set<String>)] = []
        for line in lines {
            let words = MeetingMomentLocator.contentWords(line)
            if !kept.contains(where: { restates($0.words, words) }) { kept.append((line, words)) }
        }
        return kept.map(\.text)
    }

    static func isNumeric(_ token: String) -> Bool { token.contains(where: \.isNumber) }

    /// Lowercased tokens with currency signs dropped, thousands separators removed, number words
    /// and "k"/"m" suffixes turned into digits, quarter names into "q1"…"q4", and period words
    /// into one form ("/mo", "monthly", "a month" → "month").
    static func canonicalTokens(_ text: String) -> [String] {
        var lower = text.lowercased()
        for (phrase, quarter) in quarterPhrases { lower = lower.replacingOccurrences(of: phrase, with: " \(quarter) ") }
        lower = lower.replacingOccurrences(of: #"(\d),(\d{3})"#, with: "$1$2", options: .regularExpression)
        let raw = lower.split { !$0.isLetter && !$0.isNumber }.map(String.init)
        var tokens: [String] = []
        for word in raw {
            if let value = scaled(word) {
                tokens.append(value)
            } else if let multiplier = multipliers[word], let last = tokens.last, let number = Int(last),
                      case let (product, overflow) = number.multipliedReportingOverflow(by: multiplier), !overflow {
                tokens[tokens.count - 1] = String(product)
            } else if let digit = numberWords[word] {
                tokens.append(String(digit))
            } else {
                tokens.append(periods[word] ?? word)
            }
        }
        return tokens
    }

    /// "4k" → "4000", "1.5m" → "1500000"; nil for anything else, including amounts too large
    /// for an Int, so a transcript's "1e40k" or a wall of nines stays as written.
    static func scaled(_ word: String) -> String? {
        guard let unit = word.last, let multiplier = ["k": 1_000, "m": 1_000_000][unit] else { return nil }
        let amount = word.dropLast()
        guard amount.wholeMatch(of: /\d+(\.\d+)?/) != nil, let value = Double(amount) else { return nil }
        let product = (value * Double(multiplier)).rounded()
        guard product.isFinite, let whole = Int(exactly: product) else { return nil }
        return String(whole)
    }

    static let quarterPhrases: [(String, String)] = [
        ("first quarter", "q1"), ("1st quarter", "q1"), ("second quarter", "q2"), ("2nd quarter", "q2"),
        ("third quarter", "q3"), ("3rd quarter", "q3"), ("fourth quarter", "q4"), ("4th quarter", "q4"),
    ]
    static let multipliers: [String: Int] = ["thousand": 1_000, "hundred": 100, "million": 1_000_000]
    static let numberWords: [String: Int] = [
        "one": 1, "two": 2, "three": 3, "four": 4, "five": 5, "six": 6, "seven": 7, "eight": 8, "nine": 9, "ten": 10,
        "eleven": 11, "twelve": 12, "fifteen": 15, "twenty": 20, "thirty": 30, "forty": 40, "fifty": 50,
    ]
    static let periods: [String: String] = [
        "mo": "month", "mos": "month", "months": "month", "monthly": "month",
        "wk": "week", "wks": "week", "weeks": "week", "weekly": "week",
        "yr": "year", "yrs": "year", "years": "year", "yearly": "year", "annual": "year", "annually": "year",
    ]
}
