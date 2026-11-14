import Foundation
import MurmurCore

/// Reads a timer length as spoken ("20 minutes", "twenty five mins", "an hour and a half",
/// "half an hour", "1 hour 30 minutes", "90 seconds") into seconds, so `set_timer.duration`
/// compares by value whatever form the backend returns (a phrase or whole seconds).
enum SpokenDuration {
    static func seconds(_ value: ToolArgumentValue) -> Int? {
        switch value {
        case .integer(let seconds): seconds > 0 ? seconds : nil
        case .string(let text): seconds(in: text)
        case .strings: nil
        }
    }

    private static let units: [String: Double] = [
        "second": 1, "seconds": 1, "sec": 1, "secs": 1, "s": 1,
        "minute": 60, "minutes": 60, "min": 60, "mins": 60, "m": 60,
        "hour": 3600, "hours": 3600, "hr": 3600, "hrs": 3600, "h": 3600,
    ]

    private static let ones: [String: Double] = [
        "a": 1, "an": 1, "one": 1, "two": 2, "three": 3, "four": 4, "five": 5, "six": 6, "seven": 7, "eight": 8,
        "nine": 9, "ten": 10, "eleven": 11, "twelve": 12, "thirteen": 13, "fourteen": 14, "fifteen": 15,
        "sixteen": 16, "seventeen": 17, "eighteen": 18, "nineteen": 19,
    ]
    private static let tens: [String: Double] = ["twenty": 20, "thirty": 30, "forty": 40, "fifty": 50, "sixty": 60, "ninety": 90]

    private static let phrases: [(String, String)] = [
        ("half an hour", "30 minutes"), ("half a minute", "30 seconds"), ("quarter of an hour", "15 minutes"),
        ("quarter hour", "15 minutes"), ("a couple of minutes", "2 minutes"), ("couple of minutes", "2 minutes"),
    ]

    static func seconds(in text: String) -> Int? {
        var normalized = " " + EvalText.normalize(text) + " "
        for (phrase, replacement) in phrases {
            normalized = normalized.replacingOccurrences(of: " \(phrase) ", with: " \(replacement) ")
        }
        var tokens = normalized.split(separator: " ").map(String.init)
        tokens = splitAttachedUnits(tokens)
        var total = 0.0
        var pending: Double?
        var lastUnit: Double?
        var index = 0
        while index < tokens.count {
            let token = tokens[index]
            if let unit = units[token], let value = pending {
                total += value * unit
                lastUnit = unit
                pending = nil
            } else if token == "half", index > 0, tokens[index - 1] == "a" || tokens[index - 1] == "and" {
                // "an hour and a half" (after the unit) or "one and a half hours" (before it).
                if pending != nil || index + 1 < tokens.count && units[tokens[index + 1]] != nil {
                    pending = (pending ?? 0) + 0.5
                } else if let lastUnit {
                    total += 0.5 * lastUnit
                }
            } else if let number = number(tokens, &index) {
                // "one and a half": keep the number, the "half" above adds to it.
                pending = (pending ?? 0) + number
                continue
            }
            index += 1
        }
        guard total > 0 else { return nil }
        return Int(total.rounded())
    }

    /// Reads one number starting at `index` ("25", "twenty five", "a") and advances past it.
    private static func number(_ tokens: [String], _ index: inout Int) -> Double? {
        let token = tokens[index]
        if let value = Double(token) {
            index += 1
            return value
        }
        if let ten = tens[token] {
            index += 1
            if index < tokens.count, let one = ones[tokens[index]], one < 10, tokens[index] != "a", tokens[index] != "an" {
                index += 1
                return ten + one
            }
            return ten
        }
        if let one = ones[token] {
            // "a"/"an" only count when a unit follows ("a minute"), not in "and a half".
            if token == "a" || token == "an" {
                guard index + 1 < tokens.count, units[tokens[index + 1]] != nil else { return nil }
            }
            index += 1
            return one
        }
        return nil
    }

    /// "20min" / "5m" / "1h" → ["20", "min"].
    private static func splitAttachedUnits(_ tokens: [String]) -> [String] {
        tokens.flatMap { token -> [String] in
            guard let firstLetter = token.firstIndex(where: \.isLetter), firstLetter != token.startIndex,
                  token[..<firstLetter].allSatisfy(\.isNumber), units[String(token[firstLetter...])] != nil
            else { return [token] }
            return [String(token[..<firstLetter]), String(token[firstLetter...])]
        }
    }
}
