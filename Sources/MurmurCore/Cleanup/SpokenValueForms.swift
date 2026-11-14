import Foundation

/// Spoken forms whose value is not the digits of their words, rewritten as the value they stand for so a
/// typed answer and the transcript compare by value (`SpokenNumberRuns`):
/// - clock times: "half past ten" is 10:30, the British "half seven" 7:30, "quarter to eight" 7:45, "twenty past four" 4:20 and, beside a
///   time cue, "ten to nine" 8:50 ("from ten to nine people" and "ten to twelve dollars" are ranges and stay);
/// - a quarter: "q three" is Q3, a label apart from the numbers after it;
/// - a decimal: "two point five" is 2.5, so "two point five million" is the 2,500,000 "2.5 million" is.
/// Digits written by the rules ("half past 10", "10 to 9") read the same way, so the draft and the answer
/// are rewritten alike.
enum SpokenValueForms {
    static func normalize(_ text: String) -> String {
        var result = years(halfAndQuarterHours(text))
        result = minutesPastHour(result)
        result = minutesToHour(result)
        result = Regex.replace(result, "\\bq(?:uarter)?\\s+(one|two|three|four|[1-4])\\b") { original, parts in
            guard let quarter = number(parts[1]) else { return original }
            return "Q\(quarter),"
        }
        return decimals(result)
    }

    /// "half seven" (7:30) is read as a time when the hour is a word, nothing in front makes it a fraction ("one and a half
    /// two", "a half two"), and no unit or amount follows it ("half two thirds", "half four hours").
    private static func britishHalfHours(_ text: String) -> String {
        let hours = "one|two|three|four|five|six|seven|eight|nine|ten|eleven|twelve"
        let notFraction = "(?<!\\band\\s)(?<!\\ba\\s)(?<!\\ban\\s)"
        let notAmount = "(?!\\s+(?:of|thirds?|quarters?|percent|per|dozen|hundred|thousand|million|billion|hours?|minutes?|days?|weeks?|months?|years?|times|inch|inches|point))"
        return Regex.replace(text, notFraction + "\\bhalf\\s+(\(hours))\\b(?![:.]\\d)" + notAmount) { original, parts in
            guard let hour = hour(parts[1]) else { return original }
            return clock(hour, 30)
        }
    }

    private static func halfAndQuarterHours(_ text: String) -> String {
        Regex.replace(britishHalfHours(text), "\\b(half past|quarter past|quarter to)\\s+(\(hourPattern))\\b(?![:.]\\d)") { original, parts in
            guard let hour = hour(parts[2]) else { return original }
            switch parts[1].lowercased() {
            case "half past": return clock(hour, 30)
            case "quarter past": return clock(hour, 15)
            default: return clock(previousHour(hour), 45)
            }
        }
    }

    /// A year said in two halves: "twenty eighteen" is 2018, "twenty twenty two" 2022, "nineteen ninety five" 1995 and
    /// "twenty oh five" 2005. The second half is a teen or a tens word (with its ones), or "oh" and a digit, so "twenty five"
    /// and "nineteen" on their own stay the numbers they are.
    private static func years(_ text: String) -> String {
        let ones = "one|two|three|four|five|six|seven|eight|nine"
        let teens = "ten|eleven|twelve|thirteen|fourteen|fifteen|sixteen|seventeen|eighteen|nineteen"
        let tens = "twenty|thirty|forty|fifty|sixty|seventy|eighty|ninety"
        let pattern = "(?<![\\w-])(nineteen|twenty)\\s+((?:\\b(?:\(teens))\\b)|(?:(?:\(tens))(?:[\\s-](?:\(ones)))?)|(?:oh\\s+(?:\(ones))))(?![\\w-])(?!\\s+(?:hundred|thousand|million|percent|dollars?|euros?|pounds?|people|items?))"
        return Regex.replace(text, pattern) { original, parts in
            let lead = parts[1].lowercased() == "nineteen" ? 19 : 20
            let tail = parts[2].lowercased().replacingOccurrences(of: "-", with: " ").split(separator: " ").map(String.init)
            let value: Int?
            if tail.first == "oh" {
                value = tail.last.flatMap { InverseTextNormalizer.parseCardinal($0) }
            } else {
                value = InverseTextNormalizer.parseCardinal(tail.joined(separator: " "))
            }
            guard let value, value < 100 else { return original }
            return String(format: "%d%02d", lead, value)
        }
    }

    /// "twenty past four" is 4:20.
    private static func minutesPastHour(_ text: String) -> String {
        Regex.replace(text, "\\b(\(minutePattern))\\s+past\\s+(\(hourPattern))\\b(?![:.]\\d)") { original, parts in
            guard let minutes = minutes(parts[1]), let hour = hour(parts[2]) else { return original }
            return clock(hour, minutes)
        }
    }

    /// "at ten to nine" is 8:50. "To" also makes a range, so this reads as a time only after a time cue
    /// ("at", "by", "until", ...) and when what follows the hour is not a count or an amount.
    private static func minutesToHour(_ text: String) -> String {
        let cue = "\\b(\(InverseTextNormalizer.clockTimeCuePattern)|it's|it is)\\s+"
        let pattern = cue + "(\(minutePattern))\\s+to\\s+(\(hourPattern))\\b(?![:.]\\d)(?=\\s*$|\\s*[,.;!?)\\n]|\\s+(?:\(timeFollowers))\\b)"
        return Regex.replace(text, pattern) { original, parts in
            guard let minutes = minutes(parts[2]), let hour = hour(parts[3]) else { return original }
            return "\(parts[1]) \(clock(previousHour(hour), 60 - minutes))"
        }
    }

    /// "two point five" as 2.5, the whole part a cardinal and the fraction one or more digit words. Number words
    /// before the whole part that do not join it ("room two two point five") stay as they are.
    private static func decimals(_ text: String) -> String {
        let digit = "(?:zero|oh|one|two|three|four|five|six|seven|eight|nine)"
        let pattern = "\\b((?:\(cardinalPattern)\\s+){0,2}\(cardinalPattern))\\s+point\\s+(\(digit)(?:\\s+\(digit))*)\\b"
        return Regex.replace(text, pattern) { original, parts in
            let words = parts[1].lowercased().split(separator: " ").map(String.init)
            guard let start = words.indices.first(where: {
                InverseTextNormalizer.parseCardinal(words[$0...].joined(separator: " ")) != nil
            }), let whole = InverseTextNormalizer.parseCardinal(words[start...].joined(separator: " ")) else { return original }
            let fraction = parts[2].lowercased().split(separator: " ").compactMap { word in
                word == "oh" ? 0 : InverseTextNormalizer.ones[String(word)]
            }
            return (words[..<start] + ["\(whole)." + fraction.map(String.init).joined()]).joined(separator: " ")
        }
    }

    private static func clock(_ hour: Int, _ minutes: Int) -> String {
        "\(hour):" + String(format: "%02d", minutes)
    }

    private static func previousHour(_ hour: Int) -> Int { hour == 1 ? 12 : hour - 1 }

    private static func number(_ word: String) -> Int? {
        Int(word) ?? InverseTextNormalizer.parseCardinal(word.lowercased().replacingOccurrences(of: "-", with: " "))
    }

    private static func hour(_ word: String) -> Int? {
        number(word).flatMap { (1...12).contains($0) ? $0 : nil }
    }

    private static func minutes(_ word: String) -> Int? {
        number(word).flatMap { [5, 10, 20, 25].contains($0) ? $0 : nil }
    }

    private static let hourPattern = "one|two|three|four|five|six|seven|eight|nine|ten|eleven|twelve|1[0-2]|[1-9]"
    private static let minutePattern = "twenty[- ]five|five|ten|twenty|25|20|10|5"
    private static let cardinalPattern: String = {
        let words = InverseTextNormalizer.allDigitWords.union(InverseTextNormalizer.scales.keys)
        return "(?:" + words.sorted { $0.count > $1.count }.joined(separator: "|") + ")"
    }()
    /// Words that may follow a clock time; a noun or a unit after "ten to twelve" makes it a range.
    private static let timeFollowers = [
        "and", "or", "but", "so", "then", "tomorrow", "today", "tonight", "this", "in", "on", "sharp",
        "am", "pm", "a\\.m\\.", "p\\.m\\.", "every", "each", "if", "when", "because", "please", "at", "for",
    ].joined(separator: "|")
}
