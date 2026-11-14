import Foundation

/// Compare the numbers a person said with the values in the answer. Number spelling and
/// punctuation may change; the order and multiplicity of values may not.
enum NumberValueGuard {
    static func violation(answer: String, draft: String) -> String? {
        guard let reason = strictViolation(answer: answer, draft: draft) else { return nil }
        // A list counted aloud and written as prose: the counters were layout, not numbers the speaker meant (`FoldedCounters`).
        if let folded = foldedDraft(draft, answer: answer), strictViolation(answer: answer, draft: folded) == nil { return nil }
        return reason
    }

    /// The draft without its counters, for an answer that does not number its items: where the answer lays out "1. 2. 3."
    /// the counters have to match the numbers, so a dropped item still shows (`withoutSpokenListMarkers`).
    private static func foldedDraft(_ draft: String, answer: String) -> String? {
        withoutAddedListMarkers(answer, draft: draft).markers == 0 ? FoldedCounters.removing(from: draft) : nil
    }

    private static func strictViolation(answer: String, draft: String) -> String? {
        let layout = withoutAddedListMarkers(answer, draft: draft)
        let source = values(in: withoutSpokenListMarkers(draft, answer: answer, markers: layout.markers))
        let result = values(in: layout.text)
        if source == result || isCollapsedNumericRestart(source, result, draft: draft) { return nil }
        return "changed digits"
    }

    private static func isCollapsedNumericRestart(_ source: [String], _ result: [String], draft: String) -> Bool {
        guard source.count == 2, source[0] == source[1], result == [source[1]] else { return false }
        return Regex.firstMatch(
            draft, "(?i)\\b(the|a|these|those)\\s+(one|two|three|four|five|six|seven|eight|nine|\\d+)"
                + "\\s+\\w+\\s+\\1\\s+\\2\\b") != nil
    }

    /// With a correction in the transcript, a spoken value the speaker may have taken back
    /// (`SpokenNumberRuns.retractable`: a correction cue comes after it, or "not" before it) may be left out. Values
    /// outside those still have to survive, in order.
    static func violationWithCorrection(answer: String, draft: String) -> String? {
        guard let reason = strictViolationWithCorrection(answer: answer, draft: draft) else { return nil }
        if let folded = foldedDraft(draft, answer: answer),
           strictViolationWithCorrection(answer: answer, draft: folded) == nil { return nil }
        return reason
    }

    private static func strictViolationWithCorrection(answer: String, draft: String) -> String? {
        let layout = withoutAddedListMarkers(answer, draft: draft)
        let source = SpokenNumberRuns(withoutPronounOne(
            withoutSpokenListMarkers(draft, answer: answer, markers: layout.markers)))
        let answerValues = values(in: layout.text)
        var next = 0
        for index in source.runs.indices {
            if source.retractable[index] { continue }
            if source.cueBefore.indices.contains(index + 1), source.cueBefore[index + 1] { continue }
            let value = source.runs[index].joined()
            guard let found = answerValues[next...].firstIndex(where: { $0 == value || $0.hasPrefix(value) }) else {
                return "changed digits"
            }
            next = found + 1
        }
        return nil
    }

    private static func values(in text: String) -> [String] {
        SpokenNumberRuns(withoutPronounOne(text)).runs.map { $0.joined() }
    }

    /// "the green one", "which one is", "this one of ours": a "one" after a determiner and before the end of a
    /// phrase stands for a noun, not a count. "one" before a noun ("the one bag") and a bare "I need one" stay.
    static func withoutPronounOne(_ text: String) -> String {
        withoutPronounOneAfterDeterminer(
            Regex.replace(text, "(?i)\\bone\\s+(per\\s+line|on\\s+(?:each|every|its own)\\s+line)\\b") { _, parts in parts[1] })
    }

    /// "which one", "no one", "each one", "the other one": whatever follows, a pronoun, unless a number word does.
    private static func withoutNamedPronounOne(_ text: String) -> String {
        Regex.replace(text, "(?i)\\b(which|no|each|every|another|any|the\\s+other)\\s+one\\b(?!\\s+(?:hundred|thousand|million|billion|point|[0-9]))") {
            _, parts in parts[1]
        }
    }

    private static func withoutPronounOneAfterDeterminer(_ text: String) -> String {
        let text = withoutNamedPronounOne(text)
        let determiner = "the|this|that|these|those|which|another|each|every|any|a|an|my|your|our|their|his|her|its|no"
        // What follows a pronoun "one" and never a counted noun: a verb or a pronoun ("the flat one has me down",
        // "the new one it is").
        let after = "of|is|was|are|were|that|which|who|and|or|but|with|for|in|on|at|to|instead|please|too|here|there|now|"
            + "has|had|have|does|did|do|will|would|can|could|should|may|might|must|goes|went|comes|came|looks|seems|"
            + "it|we|you|they|he|she"
        let pattern = "\\b(\(determiner))((?:\\s+[a-z'-]+){0,2}?)\\s+one\\b"
            + "(?=\\s*$|\\s*[,.;:!?)\\n]|\\s+(?:\(after))\\b)"
        return Regex.replace(text, pattern) { original, parts in
            let between = parts[2].split(whereSeparator: \.isWhitespace).map(String.init)
            if between.contains(where: SpokenNumberRuns.isNumberWord) { return original }
            return parts[1] + parts[2]
        }
    }

    /// The words a speaker counted list items with, when the answer lays the same items out as a numbered list:
    /// "first ... second ..." always, and "one ... two ... three ..." when they run 1, 2, 3 in order, each a
    /// number on its own, and there are exactly as many of them as the answer has markers.
    private static func withoutSpokenListMarkers(_ draft: String, answer: String, markers: Int) -> String {
        guard Regex.firstMatch(answer, "(?m)^\\s*1[.)]\\s+") != nil else { return draft }
        var result = draft
        for word in ["first", "second", "third", "fourth", "fifth"] {
            result = Regex.replace(result, "(?i)\\b\(word)\\b", with: "")
        }
        return withoutSpokenCounters(result, markers: markers)
    }

    private static func withoutSpokenCounters(_ text: String, markers: Int) -> String {
        guard markers >= 2, markers <= counters.count else { return text }
        let tokens = text.split(whereSeparator: \.isWhitespace).map(String.init)
        let keys = tokens.map { $0.trimmingCharacters(in: .punctuationCharacters).lowercased() }
        func isNumber(_ index: Int) -> Bool {
            keys.indices.contains(index) && (SpokenNumberRuns.isNumberWord(keys[index])
                || ["point", "oh"].contains(keys[index]) || keys[index].contains(where: \.isNumber))
        }
        // The words as said first. A counter the recogniser heard as another word ("one ... to ...", "... for ...") is
        // read as the counter only when the words as said do not count the whole list: a "to" is no number, so taking
        // it for the counter changes no value the speaker said, only how many list numbers the draft accounts for.
        for heard in [counterWords, misheardCounterWords] {
            var counted: Set<Int> = []
            for index in keys.indices where counted.count < markers && heard[counted.count].contains(keys[index]) {
                if !isNumber(index - 1), !isNumber(index + 1) { counted.insert(index) }
            }
            if counted.count == markers {
                return tokens.indices.filter { !counted.contains($0) }.map { tokens[$0] }.joined(separator: " ")
            }
        }
        return text
    }

    /// The answer without the numbers of a list it laid out, and how many it numbered.
    private static func withoutAddedListMarkers(_ answer: String, draft: String) -> (text: String, markers: Int) {
        guard EvalMetrics.listItemCount(answer) > EvalMetrics.listItemCount(draft) else { return (answer, 0) }
        var next = 1
        let text = answer.components(separatedBy: "\n").map { line in
            guard let match = Regex.firstMatch(line, "^\\s*(\\d+)[.)]\\s+"),
                  let number = match.string(at: 1, in: line), Int(number) == next else { return line }
            next += 1
            return Regex.replace(line, "^\\s*\\d+[.)]\\s+", with: "")
        }.joined(separator: "\n")
        return (text, next - 1)
    }

    private static let counters = ["one", "two", "three", "four", "five", "six", "seven", "eight", "nine", "ten"]
    private static let counterWords: [Set<String>] = counters.map { [$0] }
    /// What a recogniser writes for the counters that sound like another word.
    private static let misheardCounterWords: [Set<String>] = counters.map { word in
        switch word {
        case "two": ["two", "to", "too"]
        case "four": ["four", "for"]
        default: [word]
        }
    }
}
