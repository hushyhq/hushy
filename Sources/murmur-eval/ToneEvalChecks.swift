import Foundation
import MurmurCore

/// The case format and scoring rules for `murmur-eval tones` (Evals/tones-dev.json,
/// `hushy.tones/v1` or `hushy.tones/v2`).
///
/// Each case carries one expectation per tone. A tone's output is scored three ways, reported
/// separately because they answer different questions:
///   - exact: the output equals the author's preferred string (a draft preference, not proof);
///   - checks: general properties of the output, with tone-specific term matching;
///   - faithfulness: every content word survived and no unspoken word appeared except the
///     case's permitted ones and the tone's own closed set (`ToneRegister.closedIntroductions`).
/// A case "meets its expectation" when it matches exactly or passes its checks, with no forbidden term.
///
/// Pure text logic, unit-tested without a model (ToneEvalChecksTests).
enum ToneEvalChecks {
    // MARK: Case format

    struct CaseSet: Decodable {
        let format: String
        let name: String
        let split: String
        let note: String?
        let cases: [Case]
    }

    struct Faithfulness: Decodable, Equatable {
        /// Words or phrases that must still be present (case-insensitive, whole-word).
        let contentWords: [String]
        let contentWordsOneOf: [[String]]?
        /// Words this case allows the tone to introduce, on top of the tone's closed set.
        let permittedIntroductions: [String]
        let note: String?
    }

    struct ToneExpectation: Decodable {
        let exact: String?
        let acceptedExact: [String]?
        let checks: DevMessageChecks.Expectations?
        let mustContainOneOf: [[String]]?
        let mustNotContainOneOf: [[String]]?
        let greetingBodySeparated: Bool?
        let closingOnOwnLine: String?
        let faithfulness: Faithfulness
    }

    struct Case: Decodable {
        let id: String
        let category: String
        let tags: [String]
        let raw: String
        let target: DevMessageChecks.Target
        let ideal: String
        /// Keyed by `DictationTone.rawValue`.
        let toneExpectations: [String: ToneExpectation]
        let pendingFounderRuling: String?
        let contested: Bool?
        let contestedReason: String?

        var isContested: Bool { contested == true }
    }

    // MARK: Scoring

    struct Score: Equatable {
        /// nil when the case defines no exact string for this tone.
        let exactMatch: Bool?
        let checks: [DevMessageChecks.Outcome]
        /// nil when the case defines no checks for this tone.
        let checksPassed: Bool?
        let missingContent: [String]
        /// Words in the output but not the base text, outside the permitted and closed sets, sorted.
        let unexpectedIntroductions: [String]

        var failedChecks: [DevMessageChecks.Outcome] { checks.filter { !$0.passed } }
        var faithful: Bool { missingContent.isEmpty && unexpectedIntroductions.isEmpty }
        /// Matches exactly or passes its checks. A tone with neither defined cannot meet one.
        var meetsExpectation: Bool {
            (exactMatch == true || checksPassed == true) && !checks.contains { $0.kind == .forbidden && !$0.passed }
        }

        /// One line saying why this output fell short, for the failure list; nil if nothing did.
        var failureReason: String? {
            var parts: [String] = []
            if !meetsExpectation {
                if exactMatch == false { parts.append("not the exact string") }
                if checksPassed == false { parts.append("checks failed: " + failedChecks.map(\.detail).joined(separator: "; ")) }
                if exactMatch == true && checksPassed == false { parts.append("forbidden term present") }
                if exactMatch == nil && checksPassed == nil { parts.append("no expectation defined") }
            }
            if !missingContent.isEmpty { parts.append("missing content: " + missingContent.joined(separator: ", ")) }
            if !unexpectedIntroductions.isEmpty { parts.append("unspoken words: " + unexpectedIntroductions.joined(separator: ", ")) }
            return parts.isEmpty ? nil : parts.joined(separator: " | ")
        }
    }

    /// `base` is the rules-cleaned text before the tone was applied: the tone layer is judged on
    /// what it changed, not on what cleanup did.
    static func score(tone: DictationTone, expectation: ToneExpectation, base: String, output: String) -> Score {
        let outcomes = evaluate(expectation, base: base, output: output)
        let missing = expectation.faithfulness.contentWords.filter { !DevMessageChecks.containsTerm(output, $0) }
            + (expectation.faithfulness.contentWordsOneOf ?? []).filter { group in
                !group.contains { DevMessageChecks.containsTerm(output, $0) }
            }.map { $0.joined(separator: " | ") }
        let allowed = Set(expectation.faithfulness.permittedIntroductions.map { $0.lowercased() })
            .union(ToneRegister.closedIntroductions(for: tone))
        let introduced = ToneRegister.introducedWords(from: base, to: output).keys.filter { !allowed.contains($0) }.sorted()
        return Score(
            exactMatch: expectation.exact.map { preferred in
                ([preferred] + (expectation.acceptedExact ?? [])).contains(output.trimmingCharacters(in: .whitespacesAndNewlines))
            },
            checks: outcomes,
            // No outcome means no check ran: that is "not defined", never a pass.
            checksPassed: outcomes.isEmpty ? nil : outcomes.allSatisfy(\.passed),
            missingContent: missing,
            unexpectedIntroductions: introduced)
    }

    static func evaluate(_ expectation: ToneExpectation, base: String, output: String) -> [DevMessageChecks.Outcome] {
        var outcomes: [DevMessageChecks.Outcome] = []
        if var checks = expectation.checks {
            let literals = checks.mustContain ?? []
            let groups = checks.mustContainOneOf ?? []
            checks.mustContain = nil
            checks.mustContainOneOf = nil
            outcomes = DevMessageChecks.evaluate(checks, raw: base, output: output)
            for term in literals { outcomes.append(required([term], output: output)) }
            for group in groups { outcomes.append(required(group, output: output)) }
        }
        for group in expectation.mustContainOneOf ?? [] { outcomes.append(required(group, output: output)) }
        for group in expectation.mustNotContainOneOf ?? [] {
            let found = group.contains { DevMessageChecks.containsTerm(output, $0) }
            outcomes.append(.init(kind: .forbidden, label: "forbidden:" + group.joined(separator: "|"),
                                  passed: !found, detail: found ? "contains one of \(group)" : "absent"))
        }
        if expectation.greetingBodySeparated == true {
            let lines = output.components(separatedBy: .newlines)
            let separated = lines.count >= 3 && lines[1].trimmingCharacters(in: .whitespaces).isEmpty
                && ["hi", "hey", "hello", "dear"].contains(DevMessageChecks.words(lines[0]).first ?? "")
                && !lines[2].trimmingCharacters(in: .whitespaces).isEmpty
            outcomes.append(.init(kind: .layout, label: "greeting-body", passed: separated,
                                  detail: separated ? "greeting and body separated" : "greeting needs a blank line before body"))
        }
        if let closing = expectation.closingOnOwnLine {
            let lines = output.components(separatedBy: .newlines)
            let last = lines.last?.trimmingCharacters(in: .whitespaces) ?? ""
            let separated = lines.count >= 3 && last.caseInsensitiveCompare(closing) == .orderedSame
                && lines[lines.count - 2].trimmingCharacters(in: .whitespaces).isEmpty
            outcomes.append(.init(kind: .layout, label: "closing-line", passed: separated,
                                  detail: separated ? "closing separated" : "closing needs its own paragraph"))
        }
        return outcomes
    }

    private static func required(_ group: [String], output: String) -> DevMessageChecks.Outcome {
        let found = group.contains { DevMessageChecks.containsTerm(output, $0) }
        return .init(kind: .literal, label: "term:" + group.joined(separator: "|"), passed: found,
                     detail: found ? "present" : "none of \(group) found")
    }

    // MARK: Aggregation

    struct Record {
        let id: String
        let tone: DictationTone
        let contested: Bool
        let score: Score
    }

    struct Tally: Equatable {
        var total = 0
        var meetsExpectation = 0
        var checks = 0
        var exact = 0
        var faithful = 0

        mutating func add(_ score: Score) {
            total += 1
            if score.meetsExpectation { meetsExpectation += 1 }
            if score.checksPassed == true { checks += 1 }
            if score.exactMatch == true { exact += 1 }
            if score.faithful { faithful += 1 }
        }
    }

    struct Breakdown: Equatable {
        var all = Tally()
        var contested = Tally()
        var uncontested = Tally()
    }

    static func breakdown(_ records: [Record], tone: DictationTone) -> Breakdown {
        var result = Breakdown()
        for record in records where record.tone == tone {
            result.all.add(record.score)
            if record.contested { result.contested.add(record.score) } else { result.uncontested.add(record.score) }
        }
        return result
    }
}


extension ToneEvalChecks.ToneExpectation {
    /// Something that can actually pass or fail: a non-empty exact string, or at least one check that the
    /// evaluator really runs. "Really runs" is asked of the evaluator itself (it is given empty text and the
    /// outcomes are counted), so this cannot drift from what is scored: an empty `checks` object, empty
    /// lists, and flags set to false produce no outcome and count as nothing.
    var hasEffectiveCheck: Bool {
        if let exact, !exact.isEmpty { return true }
        return !ToneEvalChecks.evaluate(self, base: "", output: "").isEmpty
    }

    /// What is wrong with the way this expectation is written, if anything: an empty term or an empty
    /// group matches everything or nothing, so it is refused when the file is loaded.
    var writingProblem: String? {
        func emptyTerm(_ terms: [String]?) -> Bool { (terms ?? []).contains { $0.isEmpty } }
        func emptyGroup(_ groups: [[String]]?) -> Bool { (groups ?? []).contains { $0.isEmpty || emptyTerm($0) } }
        if exact?.isEmpty == true { return "an empty exact string" }
        if emptyTerm(acceptedExact) { return "an empty accepted string" }
        if emptyTerm(checks?.mustContain) || emptyTerm(checks?.mustNotContain) { return "an empty term in checks" }
        if emptyGroup(checks?.mustContainOneOf) || emptyGroup(mustContainOneOf) || emptyGroup(mustNotContainOneOf) {
            return "an empty group or term in a one-of list"
        }
        if closingOnOwnLine?.isEmpty == true { return "an empty closingOnOwnLine" }
        return nil
    }
}
