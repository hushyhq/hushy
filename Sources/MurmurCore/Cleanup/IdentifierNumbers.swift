import Foundation

/// A number spoken right after a word that names an identifier ("build", "port", "pid", "exit
/// code", "http") is that identifier, not a quantity: "port eight thousand eighty" is `port 8080`
/// (never `8,080`, an identifier has no thousands separator) and "build four eighteen" is `build
/// 418` (digit groups read out one after another, which `InverseTextNormalizer.parseCardinal`
/// rightly refuses to read as one cardinal). Part of `InverseTextNormalizer`.
///
/// Both forms need the noun immediately before the number, and a number that is followed by a unit
/// or a count word ("port eight thousand people", "build three twelve hours") stays a quantity.
/// Anything this does not recognize is left for the cardinal pass exactly as before.
enum IdentifierNumbers {
    /// The words that mark the number after them as an identifier. Longest alternatives first.
    static let nouns: [String] = [
        "build", "port", "pid", "errno", "line", "http", "status",
        "exit code", "error code", "status code", "response code",
    ]

    /// A counted noun or unit right after the number: the number is a quantity, not an identifier.
    private static let quantityWords: Set<String> = [
        "second", "seconds", "minute", "minutes", "hour", "hours", "day", "days", "week", "weeks",
        "month", "months", "year", "years", "time", "times", "percent", "people", "users", "requests",
        "errors", "hits", "lines", "files", "commits", "ms", "milliseconds", "mb", "gb", "kb", "tb", "bytes",
        "dollars", "bucks", "more", "other", "another",
        // Units of length, weight, volume and money: "four eighteen foot shelves" is a size.
        "foot", "feet", "inch", "inches", "yard", "yards", "meter", "meters", "metre", "metres", "mile", "miles",
        "km", "cm", "mm", "kilometers", "kilometres", "pound", "pounds", "ounce", "ounces", "kilo", "kilos",
        "gram", "grams", "kilograms", "liter", "liters", "litre", "litres", "gallon", "gallons", "degree",
        "degrees", "cent", "cents", "euros", "rupees", "men", "women", "children",
    ]

    /// A determiner right before the noun makes it an ordinary noun ("at the port eight thousand
    /// passengers", "a build forty foot span"): with a plural-looking word after the number, the
    /// number counts those things. Without a plural word ("the port eight thousand eighty is
    /// taken") the number is still the identifier. A closed class, never a list of counted nouns.
    private static let determiners: Set<String> = [
        "the", "a", "an", "this", "that", "these", "those", "every", "each", "our", "my", "your", "their",
        "his", "her", "its", "another", "some", "any",
    ]

    /// Closed grammatical classes that put a following "build", "port" or "line" in verb position:
    /// modals, subject pronouns, "let's" and the semi-modals. "it" is left out ("it port" is rare, "it
    /// builds" is not this word), and so is a bare "to" (see `infinitiveLeaders`).
    private static let verbMarkers: Set<String> = [
        "will", "would", "can", "could", "shall", "should", "may", "might", "must", "cannot",
        "i", "we", "you", "they", "he", "she", "let's", "lets", "gonna", "wanna", "gotta",
        "don't", "doesn't", "didn't", "won't", "can't", "couldn't", "shouldn't", "wouldn't",
        "i'll", "we'll", "you'll", "they'll", "he'll", "she'll", "i'd", "we'd", "you'd", "they'd",
    ]

    /// A "to" is an infinitive marker after these ("we need to build ..."), but a preposition after
    /// anything else ("bind it to port 8080", "roll back to build 614"), so it only counts here.
    private static let infinitiveLeaders: Set<String> = [
        "need", "needs", "needed", "want", "wants", "wanted", "have", "has", "had", "going",
        "got", "try", "tries", "trying", "able", "supposed", "ought",
    ]

    private static let digitWords = InverseTextNormalizer.ones
    private static let teenWords = InverseTextNormalizer.teens
    private static let tensWords = InverseTextNormalizer.tens

    private static let numberRun: String = {
        let words = Set(digitWords.keys).union(teenWords.keys).union(tensWords.keys)
            .union(InverseTextNormalizer.scales.keys).union(["oh"])
        let alternatives = words.sorted { $0.count > $1.count }.map(Regex.escape).joined(separator: "|")
        return "(?:\(alternatives))(?:[\\s-]+(?:\(alternatives)))*"
    }()

    /// Nouns that name an identifier only where a code editor or terminal is the target: the number
    /// after "colon" is a port or a YAML value ("localhost colon eight thousand eighty"), the number
    /// after "equals" a constant ("max equals one thousand"). In prose "colon" and "equals" take
    /// ordinary quantities, so these are added only when `codeContext` is true.
    static let codeNouns: [String] = ["colon", "equals"]

    static func apply(_ text: String, codeContext: Bool = false) -> String {
        let nounPattern = (codeContext ? nouns + codeNouns : nouns).sorted { $0.count > $1.count }
            .map { $0.split(separator: " ").map { Regex.escape(String($0)) }.joined(separator: "\\s+") }
            .joined(separator: "|")
        // The word after the number is read in a lookahead so it stays in the text.
        // Up to two words before the noun are captured only to tell a verb from an identifier.
        let leading = "(?:\\b([A-Za-z'\u{2019}]+)\\s+)?(?:\\b([A-Za-z'\u{2019}]+)\\s+)?"
        let pattern = "\(leading)\\b(\(nounPattern))(\\s+number)?\\s+(\(numberRun))\\b(?=(?:\\s+([A-Za-z']+))?)"
        return Regex.replace(text, pattern) { whole, groups in
            guard groups.count > 6, let value = digits(for: groups[5]) else { return whole }
            if quantityWords.contains(groups[6].lowercased()) { return whole }
            if isCountedAfterDeterminer(first: groups[1], second: groups[2], next: groups[6]) { return whole }
            if isVerbPosition(first: groups[1], second: groups[2]) { return whole }
            return String(whole.dropLast(groups[5].count)) + value
        }
    }

    /// "the port eight thousand passengers": a determiner before the noun and a plural-looking
    /// word (not a function word or an auxiliary) after the number.
    private static func isCountedAfterDeterminer(first: String, second: String, next: String) -> Bool {
        let nearest = (second.isEmpty ? first : second).lowercased()
        let following = next.lowercased()
        guard determiners.contains(nearest), following.count > 2, following.hasSuffix("s"), !following.hasSuffix("ss")
        else { return false }
        return !TokenLexicon.functionWords.contains(following)
    }

    /// The noun is a verb when the word right before it is a verb marker, or an infinitive "to" that
    /// follows a word that takes one. `first` and `second` are the two words before the noun in
    /// order; `second` is empty when only one word precedes it.
    private static func isVerbPosition(first: String, second: String) -> Bool {
        func key(_ word: String) -> String { word.lowercased().replacingOccurrences(of: "\u{2019}", with: "'") }
        let nearest = key(second.isEmpty ? first : second)
        if verbMarkers.contains(nearest) { return true }
        return nearest == "to" && infinitiveLeaders.contains(key(second.isEmpty ? "" : first))
    }

    /// The identifier digits for a number run, or nil when the plain cardinal pass should decide.
    private static func digits(for phrase: String) -> String? {
        let words = phrase.lowercased().split(whereSeparator: { !$0.isLetter }).map(String.init)
        if let value = InverseTextNormalizer.parseCardinal(phrase) {
            // Single cardinals below 1,000 are already handled (and are not separated); at 1,000 and up
            // the identifier form drops the separator the cardinal pass would add.
            return value >= 1_000 ? String(value) : nil
        }
        return digitGroups(words)
    }

    /// "four eighteen" -> 418, "five oh seven" -> 507, "twenty twenty four" -> 2024. Needs two or
    /// more groups; a scale word (hundred, thousand) never takes part in a digit-group run.
    private static func digitGroups(_ words: [String]) -> String? {
        var index = 0
        var groups: [String] = []
        while index < words.count {
            let word = words[index]
            if word == "oh" {
                guard index + 1 < words.count, let digit = digitWords[words[index + 1]], digit > 0 else { return nil }
                groups.append("0\(digit)")
                index += 2
            } else if let teen = teenWords[word] {
                groups.append(String(teen))
                index += 1
            } else if let ten = tensWords[word] {
                if index + 1 < words.count, let digit = digitWords[words[index + 1]], digit > 0 {
                    groups.append(String(ten + digit))
                    index += 2
                } else {
                    groups.append(String(ten))
                    index += 1
                }
            } else if let digit = digitWords[word] {
                groups.append(String(digit))
                index += 1
            } else {
                return nil
            }
        }
        guard groups.count >= 2, groups.count <= 4 else { return nil }
        let joined = groups.joined()
        return joined.count <= 8 ? joined : nil
    }
}
