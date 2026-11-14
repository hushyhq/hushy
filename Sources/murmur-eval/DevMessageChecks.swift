import Foundation

/// The case format and scoring rules for `murmur-eval dev-messages` (Evals/developer-messages-dev.json).
///
/// Every check is a general property of good output, not a comparison with one phrasing: the
/// hand-written `ideal` is kept for the reader (and for a self-consistency test that the ideal
/// itself passes every check), never scored against. All of this is pure text logic, so it is
/// unit-tested without a model (DevMessageChecksTests).
enum DevMessageChecks {
    // MARK: Case format

    struct CaseSet: Decodable {
        let format: String
        let name: String
        let split: String
        let note: String?
        let cases: [Case]
    }

    /// The dictation target. The runner feeds `bundleID` and `windowTitle` to the real
    /// `AppCategory.classify`; `expectedCategory` is the author's judgement of the right
    /// category for this text (what a developer would call it), kept apart from what the app
    /// actually decides so that a wrong classification shows up as its own failure cause.
    struct Target: Decodable {
        let bundleID: String
        let windowTitle: String?
        let expectedCategory: String
    }

    struct Expectations: Decodable, Equatable {
        /// Literals that must appear, exactly (case-sensitive).
        var mustContain: [String]?
        /// Groups of acceptable spellings: each group needs at least one member present (case-sensitive).
        var mustContainOneOf: [[String]]?
        /// Strings that must not appear (case-insensitive, whole-word where the string starts/ends with a word character).
        var mustNotContain: [String]?
        var startsWithCapital: Bool?
        var endsWithTerminalPunctuation: Bool?
        /// Bounds on words added to / removed from the raw input, as a multiset difference of normalised words.
        var maxWordsAdded: Int?
        var maxWordsRemoved: Int?
        /// The output must equal the raw input (whitespace-collapsed): already-fine text must not change.
        var unchanged: Bool?
        /// Minimum number of non-empty lines (greeting / body / sign-off on their own lines, list items).
        var minLines: Int?
    }

    struct Case: Decodable {
        let id: String
        let category: String
        let tags: [String]
        let raw: String
        let target: Target
        let ideal: String
        let checks: Expectations
    }

    // MARK: Check kinds and outcomes

    enum Kind: String, CaseIterable, Codable, Sendable {
        case literal, forbidden, capital, terminal, wordDelta, unchanged, layout

        /// Kinds that are about shape (casing, punctuation, line layout) rather than the words.
        var isFormat: Bool { [.capital, .terminal, .layout].contains(self) }
    }

    struct Outcome: Equatable, Sendable {
        let kind: Kind
        /// Stable label, e.g. `literal:auth-service`, used to compare the same check across runs.
        let label: String
        let passed: Bool
        let detail: String
    }

    // MARK: Evaluation

    static func evaluate(_ expectations: Expectations, raw: String, output: String) -> [Outcome] {
        var outcomes: [Outcome] = []
        for literal in expectations.mustContain ?? [] {
            let found = output.contains(literal)
            outcomes.append(Outcome(kind: .literal, label: "literal:\(literal)", passed: found,
                                    detail: found ? "present" : "missing \"\(literal)\""))
        }
        for group in expectations.mustContainOneOf ?? [] {
            let found = group.contains { output.contains($0) }
            let label = "literal:" + group.joined(separator: "|")
            outcomes.append(Outcome(kind: .literal, label: label, passed: found,
                                    detail: found ? "present" : "none of \(group.map { "\"\($0)\"" }.joined(separator: ", ")) found"))
        }
        for banned in expectations.mustNotContain ?? [] {
            let present = containsTerm(output, banned)
            outcomes.append(Outcome(kind: .forbidden, label: "forbidden:\(banned)", passed: !present,
                                    detail: present ? "still contains \"\(banned)\"" : "absent"))
        }
        if expectations.startsWithCapital == true {
            let ok = startsWithCapital(output)
            outcomes.append(Outcome(kind: .capital, label: "capital", passed: ok, detail: ok ? "capitalised" : "does not start with a capital"))
        }
        if expectations.endsWithTerminalPunctuation == true {
            let ok = endsWithTerminalPunctuation(output)
            outcomes.append(Outcome(kind: .terminal, label: "terminal", passed: ok, detail: ok ? "terminated" : "no terminal punctuation"))
        }
        if expectations.maxWordsAdded != nil || expectations.maxWordsRemoved != nil {
            let delta = wordDelta(raw: raw, output: output)
            if let limit = expectations.maxWordsAdded {
                let ok = delta.added <= limit
                outcomes.append(Outcome(kind: .wordDelta, label: "added", passed: ok, detail: "\(delta.added) added (limit \(limit))"))
            }
            if let limit = expectations.maxWordsRemoved {
                let ok = delta.removed <= limit
                outcomes.append(Outcome(kind: .wordDelta, label: "removed", passed: ok, detail: "\(delta.removed) removed (limit \(limit))"))
            }
        }
        if expectations.unchanged == true {
            let ok = collapsed(output) == collapsed(raw)
            outcomes.append(Outcome(kind: .unchanged, label: "unchanged", passed: ok, detail: ok ? "unchanged" : "text was changed"))
        }
        if let minimum = expectations.minLines {
            let count = nonEmptyLineCount(output)
            outcomes.append(Outcome(kind: .layout, label: "layout", passed: count >= minimum,
                                    detail: "\(count) non-empty line(s) (need \(minimum))"))
        }
        return outcomes
    }

    // MARK: Text helpers

    /// Lowercased alphanumeric words with apostrophes kept inside words; punctuation, hyphens and
    /// dots split words, so "re-run" and "re run" compare equal and "v2.14.3" is `v2 14 3`.
    static func words(_ text: String) -> [String] {
        let normalised = text.lowercased().replacingOccurrences(of: "\u{2019}", with: "'")
        var result: [String] = []
        var current = ""
        for character in normalised {
            if character.isLetter || character.isNumber || character == "'" {
                current.append(character)
            } else if !current.isEmpty {
                result.append(current)
                current = ""
            }
        }
        if !current.isEmpty { result.append(current) }
        return result.map { $0.trimmingCharacters(in: CharacterSet(charactersIn: "'")) }.filter { !$0.isEmpty }
    }

    /// Words in `output` not in `raw` (added) and words in `raw` not in `output` (removed), as a multiset difference.
    static func wordDelta(raw: String, output: String) -> (added: Int, removed: Int) {
        var rawCounts: [String: Int] = [:]
        for word in words(raw) { rawCounts[word, default: 0] += 1 }
        var outCounts: [String: Int] = [:]
        for word in words(output) { outCounts[word, default: 0] += 1 }
        var added = 0
        var removed = 0
        for (word, count) in outCounts { added += max(0, count - rawCounts[word, default: 0]) }
        for (word, count) in rawCounts { removed += max(0, count - outCounts[word, default: 0]) }
        return (added, removed)
    }

    /// Case-insensitive containment; whole-word at an edge where that edge is a letter or digit,
    /// so forbidding "um" does not trip on "umbrella" or "forum".
    static func containsTerm(_ text: String, _ term: String) -> Bool {
        guard !term.isEmpty else { return false }
        let haystack = Array(text.lowercased())
        let needle = Array(term.lowercased())
        guard haystack.count >= needle.count else { return false }
        func isWord(_ c: Character) -> Bool { c.isLetter || c.isNumber }
        for start in 0...(haystack.count - needle.count) where Array(haystack[start..<start + needle.count]) == needle {
            let before = start > 0 ? haystack[start - 1] : nil
            let after = start + needle.count < haystack.count ? haystack[start + needle.count] : nil
            let leadingOK = !(isWord(needle[0]) && before.map(isWord) == true)
            let trailingOK = !(isWord(needle[needle.count - 1]) && after.map(isWord) == true)
            if leadingOK && trailingOK { return true }
        }
        return false
    }

    /// The first letter or digit of the text is an uppercase letter or a digit.
    static func startsWithCapital(_ text: String) -> Bool {
        guard let first = text.first(where: { $0.isLetter || $0.isNumber }) else { return false }
        return first.isNumber || first.isUppercase
    }

    /// The text ends in . ! ? or an ellipsis, ignoring trailing closing quotes and brackets.
    static func endsWithTerminalPunctuation(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let closers = CharacterSet(charactersIn: "\"'”’)]}")
        let stripped = trimmed.unicodeScalars.reversed().drop { closers.contains($0) }
        guard let last = stripped.first else { return false }
        return ".!?…".unicodeScalars.contains(last)
    }

    static func collapsed(_ text: String) -> String {
        text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    static func nonEmptyLineCount(_ text: String) -> Int {
        text.components(separatedBy: .newlines).filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }.count
    }

    // MARK: Failure cause

    enum Cause: String, CaseIterable, Codable, Sendable {
        /// The app put the target in a different context than the right one, and that changed the shape of the output.
        case classification
        /// The target was classified as intended but the rules/style layer produced the wrong shape.
        case formatter
        /// The model stage ran and either made a passing rules draft fail, or did not (or could not) fix it.
        case model
        /// Nothing in the pipeline attempts this transformation.
        case missingFeature = "missing-feature"
    }

    /// First-pass attribution for one failed case. `rulesOutcomes` are the same checks scored on the
    /// rules-only output (strategy `.rules`, same settings). Priority: classification, then a model
    /// regression, then a formatter shape error, then model-ran-but-failed, then missing feature.
    static func attribute(
        failed: [Outcome], rulesOutcomes: [Outcome], configMatchesExpected: Bool, modelRan: Bool
    ) -> Cause {
        if !configMatchesExpected, failed.contains(where: { $0.kind.isFormat }) { return .classification }
        let rulesPassing = Set(rulesOutcomes.filter(\.passed).map(\.label))
        if failed.contains(where: { rulesPassing.contains($0.label) }) { return .model }
        if failed.contains(where: { $0.kind.isFormat }) { return .formatter }
        return modelRan ? .model : .missingFeature
    }
}
