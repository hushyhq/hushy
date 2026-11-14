import Foundation

/// Seeded, deterministic perturbations of a known-good cleanup (a golden `reference`) that each
/// introduce exactly one known fault, so a judge's answer can be scored against a label that
/// doesn't depend on any judge. Pure string functions — unit-tested in
/// `Tests/MurmurEvalTests/JudgeCalibrationTests.swift`. Each returns nil when the text offers no
/// place to apply the fault (e.g. no number to drop), so the builder simply skips that case.
enum JudgePerturbations {
    // MARK: Numbers

    private static let numberPattern = try! NSRegularExpression(
        pattern: "\\$?\\d+(?:[,.:]\\d+)*(?:%|(?:st|nd|rd|th)\\b|\\s?(?:am|pm)\\b|\\b)", options: [.caseInsensitive])

    /// Removes the first number (with its currency sign, percent, or am/pm).
    static func dropNumber(_ text: String) -> String? {
        let range = NSRange(text.startIndex..., in: text)
        guard let match = numberPattern.firstMatch(in: text, range: range),
              let swiftRange = Range(match.range, in: text) else { return nil }
        var result = text
        result.removeSubrange(swiftRange)
        return tidy(result)
    }

    // MARK: Negation

    private static let negationFlips: [(String, String)] = [
        ("don't", "do"), ("doesn't", "does"), ("didn't", "did"), ("can't", "can"), ("won't", "will"),
        ("isn't", "is"), ("aren't", "are"), ("wasn't", "was"), ("shouldn't", "should"), ("couldn't", "could"),
        ("wouldn't", "would"), ("haven't", "have"), ("hasn't", "has"), ("not", ""), ("never", "always"),
        ("is", "is not"), ("are", "are not"), ("will", "won't"), ("can", "can't"), ("should", "shouldn't"),
        ("need to", "don't need to"), ("was", "wasn't"), ("works", "doesn't work"),
    ]

    /// Adds or removes the first negation it can (removal preferred), keeping capitalization.
    static func flipNegation(_ text: String) -> String? {
        for (from, to) in negationFlips {
            if let flipped = replaceFirstWord(from, with: to, in: text) { return tidy(flipped) }
        }
        return nil
    }

    // MARK: Fillers

    private static let fillers = ["um,", "uh,", "like,", "you know,"]

    /// Inserts one filler at a position chosen from `seed`, after the first word at the earliest.
    static func insertFiller(_ text: String, seed: Int) -> String? {
        var words = text.split(separator: " ", omittingEmptySubsequences: false).map(String.init)
        guard words.count >= 3 else { return nil }
        let filler = fillers[abs(seed) % fillers.count]
        let position = 1 + abs(seed / 7) % max(1, words.count - 2)
        words.insert(filler, at: position)
        return words.joined(separator: " ")
    }

    // MARK: Over-editing (Clean must keep the speaker's words)

    private static let synonyms: [(String, String)] = [
        ("need to", "must"), ("want", "would like"), ("make sure", "ensure"), ("tell", "inform"),
        ("get", "obtain"), ("help", "assist"), ("buy", "purchase"), ("about", "regarding"), ("fix", "resolve"),
        ("show", "demonstrate"), ("send", "forward"), ("try", "attempt"), ("maybe", "perhaps"), ("check", "verify"),
        ("use", "utilize"), ("think", "believe"), ("start", "commence"), ("let's", "let us"), ("I'm", "I am"),
        ("it's", "it is"), ("we're", "we are"), ("I'll", "I will"), ("big", "substantial"), ("just", "merely"),
        ("really", "truly"), ("go with", "select"), ("a lot of", "numerous"), ("okay", "acceptable"),
    ]

    /// Swaps in formal synonyms / expands contractions; needs at least `minimum` swaps so the
    /// change is unambiguous over-editing rather than one arguable word.
    static func overEdit(_ text: String, minimum: Int = 2) -> String? {
        var result = text
        var swaps = 0
        for (from, to) in synonyms {
            if let replaced = replaceFirstWord(from, with: to, in: result) {
                result = replaced
                swaps += 1
            }
        }
        return swaps >= minimum ? result : nil
    }

    // MARK: Meaning change

    private static let weekdays = ["Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday", "Sunday"]
    private static let months = ["January", "February", "March", "April", "May", "June", "July", "August",
                                 "September", "October", "November", "December"]
    private static let swapNames: [(String, String)] = [
        ("Priya", "Marcus"), ("Maria", "Karen"), ("Devon", "Omar"), ("Sam", "Ben"), ("Lisa", "Nina"),
        ("Kris", "Alex"), ("Sarah", "Emma"), ("John", "Peter"), ("Noah", "Liam"), ("Jen", "Tom"),
        ("Raj", "Ivan"), ("Mike", "Dan"), ("Anna", "Rosa"), ("David", "Carl"),
    ]

    /// Swaps a weekday, month or known first name for a different one — a changed fact that
    /// keeps the sentence perfectly fluent.
    static func changeFact(_ text: String) -> String? {
        for day in weekdays where text.contains(day) {
            let next = weekdays[(weekdays.firstIndex(of: day)! + 2) % weekdays.count]
            return text.replacingOccurrences(of: day, with: next)
        }
        for month in months where replaceFirstWord(month, with: month, in: text) != nil {
            let next = months[(months.firstIndex(of: month)! + 3) % months.count]
            return replaceFirstWord(month, with: next, in: text)
        }
        for (name, other) in swapNames where replaceFirstWord(other, with: other, in: text) == nil {
            if let swapped = replaceFirstWord(name, with: other, in: text) { return swapped }
        }
        return nil
    }

    // MARK: Dropped content

    /// Drops the last sentence (if there are ≥ 2 and it has ≥ 3 words), else the last
    /// "and …" clause with ≥ 3 words after "and".
    static func dropClause(_ text: String) -> String? {
        let sentences = splitSentences(text)
        if sentences.count >= 2, let last = sentences.last, last.split(separator: " ").count >= 3 {
            return sentences.dropLast().joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
        }
        guard let range = text.range(of: " and ", options: .backwards) else { return nil }
        let tail = text[range.upperBound...]
        guard tail.split(separator: " ").count >= 3 else { return nil }
        let head = text[..<range.lowerBound].trimmingCharacters(in: CharacterSet(charactersIn: " ,"))
        guard head.split(separator: " ").count >= 3 else { return nil }
        return head + "."
    }

    // MARK: Lists

    /// Flattens a bulleted/numbered list ("Header:\n- a\n- b") into one prose sentence.
    static func flattenList(_ text: String) -> String? {
        let lines = text.components(separatedBy: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
        let itemPattern = try! NSRegularExpression(pattern: "^(- |\\* |• |\\d+[.)] )")
        var header: [String] = []
        var items: [String] = []
        for line in lines where !line.isEmpty {
            let range = NSRange(line.startIndex..., in: line)
            if let match = itemPattern.firstMatch(in: line, range: range), let r = Range(match.range, in: line) {
                items.append(String(line[r.upperBound...]).trimmingCharacters(in: CharacterSet(charactersIn: " .")))
            } else if items.isEmpty {
                header.append(line)
            }
        }
        guard items.count >= 2 else { return nil }
        let joined = items.dropLast().joined(separator: ", ") + " and " + items.last!
        let lead = header.joined(separator: " ").trimmingCharacters(in: CharacterSet(charactersIn: " :"))
        return lead.isEmpty ? joined.prefix(1).uppercased() + joined.dropFirst() + "." : "\(lead): \(joined)."
    }

    // MARK: Over-cleaning a negative (text that must stay unchanged)

    /// A naive "disfluency stripper" of the kind the reformat negatives exist to catch: drops a
    /// doubled word, a leading "No,", and "actually"/"like"/"I mean". Nil if nothing changed.
    static func overClean(_ text: String) -> String? {
        var words = text.split(separator: " ").map(String.init)
        var changed = false
        var index = 1
        while index < words.count {
            if normalized(words[index]) == normalized(words[index - 1]) && !normalized(words[index]).isEmpty {
                words.remove(at: index)
                changed = true
            } else {
                index += 1
            }
        }
        if let first = words.first, first.lowercased() == "no," {
            words.removeFirst()
            if let head = words.first { words[0] = head.prefix(1).uppercased() + head.dropFirst() }
            changed = true
        }
        let dropped = words.filter { !["actually", "actually,", "like", "like,"].contains($0.lowercased()) }
        if dropped.count != words.count { changed = true }
        guard changed, !dropped.isEmpty else { return nil }
        return tidy(dropped.joined(separator: " "))
    }

    // MARK: Helpers

    static func normalized(_ word: String) -> String {
        word.lowercased().trimmingCharacters(in: .punctuationCharacters)
    }

    static func splitSentences(_ text: String) -> [String] {
        let regex = try! NSRegularExpression(pattern: "[^.!?]+[.!?]+(\\s+|$)")
        let matches = regex.matches(in: text, range: NSRange(text.startIndex..., in: text))
        let parts = matches.compactMap { Range($0.range, in: text).map { String(text[$0]).trimmingCharacters(in: .whitespacesAndNewlines) } }
        return parts.joined().count >= text.filter { !$0.isWhitespace }.count - 1 ? parts : [text]
    }

    /// Replaces the first whole-word, case-insensitive match of `word`, keeping a leading capital.
    static func replaceFirstWord(_ word: String, with replacement: String, in text: String) -> String? {
        let pattern = "(?<![\\w'])" + NSRegularExpression.escapedPattern(for: word) + "(?![\\w'])"
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let range = Range(match.range, in: text) else { return nil }
        let original = text[range]
        var value = replacement
        if let first = original.first, first.isUppercase, !value.isEmpty {
            value = value.prefix(1).uppercased() + value.dropFirst()
        }
        return text.replacingCharacters(in: range, with: value)
    }

    /// Collapses double spaces and space-before-punctuation left by a removal.
    static func tidy(_ text: String) -> String {
        var result = text
        while result.contains("  ") { result = result.replacingOccurrences(of: "  ", with: " ") }
        for mark in [" ,", " .", " ?", " !"] {
            result = result.replacingOccurrences(of: mark, with: String(mark.dropFirst()))
        }
        result = result.replacingOccurrences(of: ",,", with: ",")
        return result.trimmingCharacters(in: .whitespaces)
    }
}
