import Foundation

/// Word handling shared by meeting memory: one normaliser, one crude stemmer, one stop list, so
/// "sent the updated quote" and "Send the revised quote" meet on "send" and "quot".
enum MemoryText {
    /// Lowercased words, punctuation and "$" dropped, hyphens split ("go-live" → "go live").
    static func words(_ text: String) -> [String] {
        let lowered = text.lowercased().replacingOccurrences(of: "’", with: "'")
        var result: [String] = []
        var current = ""
        for scalar in lowered.unicodeScalars {
            if CharacterSet.alphanumerics.contains(scalar) || scalar == "'" || (scalar == "-" && !current.isEmpty) {
                current.unicodeScalars.append(scalar)
            } else if !current.isEmpty {
                result.append(current)
                current = ""
            }
        }
        if !current.isEmpty { result.append(current) }
        return result.flatMap { word -> [String] in
            var trimmed = word.trimmingCharacters(in: CharacterSet(charactersIn: "'-"))
            if trimmed.hasSuffix("'s") { trimmed = String(trimmed.dropLast(2)) }
            // "go-live" and "sign-on" are one word; "forty-five" stays two number words.
            let parts = trimmed.split(separator: "-").map(String.init)
            guard parts.count > 1 else { return [trimmed] }
            return parts.allSatisfy { numberWords.contains($0) } ? parts : [parts.joined()]
        }.filter { !$0.isEmpty }
    }

    static let irregular: [String: String] = [
        "sent": "send", "wrote": "write", "written": "write", "made": "make", "got": "get", "gotten": "get",
        "built": "build", "did": "do", "done": "do", "took": "take", "taken": "take", "gave": "give",
        "given": "give", "met": "meet", "ran": "run", "paid": "pay", "spoke": "speak", "spoken": "speak",
        "told": "tell", "said": "say", "found": "find", "brought": "bring", "bought": "buy", "thought": "think",
        "kept": "keep", "left": "leave", "chose": "choose", "chosen": "choose", "drew": "draw", "drawn": "draw",
        "went": "go", "gone": "go", "set": "set", "put": "put", "shut": "shut", "led": "lead", "held": "hold",
        "signed": "sign", "children": "child", "people": "person",
    ]

    /// A crude stem: irregular verbs mapped, then -ing/-ed/-es/-s/-e stripped while at least three
    /// letters remain. Numbers stay as written.
    static func stem(_ word: String) -> String {
        if let mapped = irregular[word] { return mapped }
        guard word.count > 3, word.rangeOfCharacter(from: .decimalDigits) == nil else { return word }
        var stem = word
        for suffix in ["ions", "ion", "ing", "ed", "es", "s", "e"] where stem.hasSuffix(suffix) && stem.count - suffix.count >= 3 {
            stem = String(stem.dropLast(suffix.count))
            break
        }
        if stem.hasSuffix("i"), stem.count > 3 { stem = String(stem.dropLast()) + "y" }
        return stem
    }

    static let stopWords: Set<String> = [
        "a", "an", "the", "and", "or", "but", "of", "to", "in", "on", "at", "for", "with", "about", "from", "by",
        "is", "are", "was", "were", "be", "been", "being", "do", "does", "did", "have", "has", "had", "i", "my",
        "me", "we", "our", "us", "you", "your", "it", "its", "this", "that", "these", "those", "what", "when",
        "where", "which", "who", "whom", "how", "any", "there", "here", "so", "just", "like", "some", "then",
        "than", "as", "not", "no", "yes", "into", "out", "over", "up", "off", "will", "would", "could", "should",
        "can", "shall", "may", "might", "must", "i'll", "we'll", "you'll", "i'm", "we're", "it's", "that's",
        "let's", "don't", "doesn't", "didn't", "won't", "can't", "isn't", "okay", "ok", "yeah", "um", "uh",
        "also", "all", "if", "he", "she", "they", "them", "their", "his", "her", "him", "one", "get", "go",
        "going", "gonna", "make", "sure", "think", "know", "need", "want", "well", "right", "really", "very",
        "now", "still", "yet", "again", "too", "per", "each", "more", "much", "many", "lot", "thing", "things",
        "say", "tell", "let", "see", "look", "come", "take", "put", "give", "got",
    ]

    /// Stemmed content words, in order, without repeats.
    static func contentStems(_ text: String) -> [String] {
        var seen = Set<String>()
        return words(text).compactMap { word in
            guard !stopWords.contains(word) else { return nil }
            let stem = stem(word)
            guard !stopWords.contains(stem), stem.count > 1, seen.insert(stem).inserted else { return nil }
            return stem
        }
    }

    static let monthAndDayWords: Set<String> = [
        "january", "february", "march", "april", "june", "july", "august", "september", "october", "november",
        "december", "jan", "feb", "mar", "apr", "jun", "jul", "aug", "sep", "sept", "oct", "nov", "dec", "monday",
        "tuesday", "wednesday", "thursday", "friday", "saturday", "sunday", "today", "tomorrow", "week", "month",
    ]

    static let numberWords: Set<String> = [
        "zero", "one", "two", "three", "four", "five", "six", "seven", "eight", "nine", "ten", "eleven", "twelve",
        "fifteen", "twenty", "thirty", "forty", "fifty", "sixty", "seventy", "eighty", "ninety", "hundred",
        "thousand", "million", "half", "k",
    ]

    /// Verbs that say a value moved, not what it is about ("go-live moved to", "price drops to").
    static let changeVerbs: Set<String> = Set([
        "move", "push", "shift", "change", "slip", "bump", "become", "stay", "update", "set", "revise", "raise", "lower",
        "increase", "decrease", "cut", "extend", "delay", "postpone", "drop", "now", "new", "still", "instead", "reduce",
        "go", "goe", "land", "end", "start",
    ].map { stem($0) })

    enum ValueKind: Int, Comparable {
        case number, date, percent, money
        static func < (lhs: ValueKind, rhs: ValueKind) -> Bool { lhs.rawValue < rhs.rawValue }
    }

    /// The main kind of value a decision sets: money beats a percentage beats a date beats a count.
    static func valueKind(_ text: String) -> ValueKind? {
        let lowered = text.lowercased()
        let words = Set(self.words(text))
        if lowered.contains("$") || lowered.contains("€") || lowered.contains("£") || !words.isDisjoint(with: ["dollar", "dollars", "euro", "euros", "pound"]) { return .money }
        if lowered.contains("%") || words.contains("percent") { return .percent }
        if !words.isDisjoint(with: monthAndDayWords) { return .date }
        if lowered.rangeOfCharacter(from: .decimalDigits) != nil || !words.isDisjoint(with: numberWords) { return .number }
        return nil
    }

    /// Content stems that name the subject, not a value: numbers and dates dropped, so "price is
    /// 45" and "price is 40" have the same subject.
    static func subjectStems(_ text: String) -> Set<String> {
        Set(words(text).compactMap { word -> String? in
            guard !stopWords.contains(word), !monthAndDayWords.contains(word), !numberWords.contains(word),
                  word.rangeOfCharacter(from: .decimalDigits) == nil else { return nil }
            let stem = stem(word)
            return stopWords.contains(stem) || changeVerbs.contains(stem) || stem.count < 2 ? nil : stem
        })
    }

    /// Letters and digits only, lowercased: "Brightmoor Freight" and "brightmoorfreight" meet.
    static func squashed(_ text: String) -> String {
        String(text.lowercased().unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) })
    }

    /// Share of `needle`'s stems found in `haystack`'s.
    static func coverage(of needle: [String], in haystack: Set<String>) -> Double {
        guard !needle.isEmpty else { return 0 }
        return Double(needle.filter(haystack.contains).count) / Double(needle.count)
    }

    static func jaccard(_ lhs: Set<String>, _ rhs: Set<String>) -> Double {
        let union = lhs.union(rhs)
        return union.isEmpty ? 0 : Double(lhs.intersection(rhs).count) / Double(union.count)
    }

    /// The FTS5 query for "any of these words", each quoted so no word is read as syntax.
    static func ftsAny(_ stems: [String]) -> String? {
        let terms = stems.filter { !$0.isEmpty }.prefix(24).map { "\"\($0.replacingOccurrences(of: "\"", with: ""))\"" }
        return terms.isEmpty ? nil : terms.joined(separator: " OR ")
    }

    /// The first word, for "Priya Raman" → "priya".
    static func firstName(_ name: String) -> String { words(name).first ?? "" }
}

/// How much each stem tells one moment from another in these meetings (inverse document frequency
/// over turns, decisions and items). "printer minimum" carries "Check whether the printer minimum can
/// go lower"; "check" and "lower" barely do. Built from the user's own meetings, so it needs no word list.
struct StemWeights: Sendable {
    let frequency: [String: Int]
    let documents: Int

    init(documents: [[String]]) {
        var frequency: [String: Int] = [:]
        for document in documents { for stem in Set(document) { frequency[stem, default: 0] += 1 } }
        self.frequency = frequency
        self.documents = documents.count
    }

    func weight(_ stem: String) -> Double {
        log(Double(documents + 2) / Double((frequency[stem] ?? 0) + 1))
    }

    /// Weighted share of `needle` found in `haystack`.
    func coverage(of needle: [String], in haystack: Set<String>) -> Double {
        let total = needle.reduce(0) { $0 + weight($1) }
        guard total > 0 else { return 0 }
        return needle.filter(haystack.contains).reduce(0) { $0 + weight($1) } / total
    }

    /// The best weighted share over alternatives ("UV or sun fading": either side may match).
    func coverage(of groups: [[String]], in haystack: Set<String>) -> Double {
        groups.map { coverage(of: $0, in: haystack) }.max() ?? 0
    }
}
