import Foundation
import MurmurCore

/// The case format of the voice-tools eval (`Evals/actions-tools-dev.json`, and the sealed
/// held-out set on its own branch). One file:
///
/// ```json
/// {"format": "hushy.tool-eval/v1", "catalog": "tools-v1", "name": "actions-tools-dev", "split": "dev",
///  "cases": [{
///    "id": "dev-0001",
///    "utterance": "uh remind me to call the plumber tomorrow at nine",
///    "context": {"now": "2026-10-05T10:15:00+05:30", "timeZone": "Asia/Kolkata", "locale": "en_IN", "frontmostApp": "Slack"},
///    "category": "relative-datetime", "tags": ["en-IN", "filler"],
///    "expect": {"decision": "call", "tool": "create_reminder",
///               "args": {"title": "call the plumber", "when": "2026-10-06T09:00:00+05:30"},
///               "whenSpoken": ["tomorrow at nine"]}}]}
/// ```
///
/// - `utterance` is ASR-shaped: lowercase, no punctuation, disfluencies kept.
/// - `decision` is `call`, `no_action` (ordinary dictation, mentions, chit-chat — the false-fire
///   negatives) or `refuse` (sensitive, unsupported, ambiguous, multi-intent).
/// - `args` hold the expected values: dates as ISO-8601 with offset (or `YYYY-MM-DD` when only
///   the day is meant), timer durations in seconds, lists as arrays. `accept` lists extra
///   acceptable values per argument; `alternatives` lists other acceptable whole calls.
/// - `reasons` are the acceptable `no_action` reasons; `split` is an acceptable one-call-per-
///   intent answer for multi-intent cases ("either split or refuse").
struct ToolEvalSet: Codable, Sendable {
    static let format = "hushy.tool-eval/v1"

    var format: String
    var catalog: String
    var name: String
    var split: String
    var cases: [ToolEvalCase]

    enum Access: Equatable {
        /// Dev evals, tuning, calibration, data generation: sealed sets are refused.
        case tuning(purpose: String)
        /// The orchestrator's held-out run: the file must be the pinned sealed set.
        case sealedHeldout
    }

    static func load(_ url: URL, access: Access) throws -> ToolEvalSet {
        switch access {
        case .tuning(let purpose): try SealedEvalGuard.assertTuningSafe(url, purpose: purpose)
        case .sealedHeldout: try SealedEvalGuard.assertIsSealedActionsHeldout(url)
        }
        let set = try JSONDecoder().decode(ToolEvalSet.self, from: Data(contentsOf: url))
        let problems = set.problems()
        guard problems.isEmpty else {
            throw EvalError.missing("\(url.lastPathComponent) is invalid:\n  " + problems.prefix(20).joined(separator: "\n  "))
        }
        return set
    }

    /// Everything wrong with the file, as readable lines (empty = valid).
    func problems() -> [String] {
        var problems: [String] = []
        if format != Self.format { problems.append("format \(format), expected \(Self.format)") }
        if catalog != VoiceToolCatalog.version { problems.append("catalog \(catalog), expected \(VoiceToolCatalog.version)") }
        var seen = Set<String>()
        for item in cases {
            if !seen.insert(item.id).inserted { problems.append("\(item.id): duplicate id") }
            problems += item.problems().map { "\(item.id): \($0)" }
        }
        return problems
    }
}

struct ToolEvalCase: Codable, Sendable, Equatable {
    var id: String
    var utterance: String
    var context: Context
    var category: ToolEvalCategory
    var tags: [String]
    var expect: Expectation
    var notes: String?

    struct Context: Codable, Sendable, Equatable {
        var now: String
        var timeZone: String
        var locale: String
        var frontmostApp: String?

        static let locales: Set<String> = ["en_US", "en_IN"]

        var nowDate: Date? { ProposalFields.parseISO8601(now) }
        var zone: TimeZone? { TimeZone(identifier: timeZone) }
        /// The case's clock, zone and locale (the real clock only if the file's `now` is invalid,
        /// which `problems()` already rejects).
        var dateContext: DateContext {
            DateContext(now: nowDate ?? Date(), timeZone: zone ?? .current, locale: Locale(identifier: locale))
        }

        /// The context line every catalogue-mode backend sees before the utterance.
        /// Built by `VoiceToolCatalog.contextLine`, the same code the fine-tune export uses.
        func promptLine() -> String {
            guard let date = nowDate, let zone else { return "" }
            return VoiceToolCatalog.contextLine(now: date, timeZone: zone, locale: locale, frontmostApp: frontmostApp)
        }
    }

    struct Expectation: Codable, Sendable, Equatable {
        enum Decision: String, Codable, Sendable {
            case call
            case noAction = "no_action"
            case refuse
        }

        var decision: Decision
        var tool: String
        var args: [String: ToolArgumentValue]
        var whenSpoken: [String]?
        var accept: [String: [ToolArgumentValue]]?
        var alternatives: [ToolCall]?
        var reasons: [String]?
        var split: [ToolCall]?

        var call: ToolCall { ToolCall(tool: tool, arguments: args) }
        /// The expected call first, then any acceptable alternative.
        var acceptableCalls: [ToolCall] { [call] + (alternatives ?? []) }
    }

    static let punctuatedTag = "punctuated"

    var isNegative: Bool { expect.decision == .noAction }

    func problems() -> [String] {
        var problems: [String] = []
        // A case tagged `punctuated` keeps the capitals and marks Whisper gives a real sentence
        // ("Could you ...?"): the shape the shipping gate actually sees. Everything else is bare ASR.
        if !tags.contains(Self.punctuatedTag) {
            if utterance != utterance.lowercased() { problems.append("utterance must be lowercase ASR text") }
            if utterance.contains(where: { ".,?!;:\"".contains($0) }) { problems.append("utterance must have no punctuation") }
        }
        if context.nowDate == nil { problems.append("context.now is not ISO-8601 with offset") }
        if context.zone == nil { problems.append("unknown time zone \(context.timeZone)") }
        if !Context.locales.contains(context.locale) { problems.append("locale must be en_US or en_IN") }
        problems += expectationProblems()
        return problems
    }

    private func expectationProblems() -> [String] {
        var problems: [String] = []
        let noAction = VoiceToolCatalog.noActionName
        switch expect.decision {
        case .call:
            if expect.tool == noAction { problems.append("decision call needs a tool") }
        case .noAction, .refuse:
            if expect.tool != noAction { problems.append("decision \(expect.decision.rawValue) needs tool no_action") }
            let reasons = expect.reasons ?? []
            if reasons.isEmpty { problems.append("no_action/refuse needs reasons") }
            for reason in reasons where VoiceToolCatalog.NoActionReason(rawValue: reason) == nil {
                problems.append("unknown reason \(reason)")
            }
        }
        let calls = expect.decision == .call ? expect.acceptableCalls : (expect.split ?? [])
        for call in calls {
            problems += call.validationIssues().map { "expected call: \($0)" }
        }
        return problems
    }
}

/// One primary category per case (secondary facts go in `tags`).
enum ToolEvalCategory: String, Codable, Sendable, CaseIterable {
    case plainCommand = "plain-command"
    case relativeDatetime = "relative-datetime"
    case indianEnglish = "indian-english"
    case attendees
    case listItems = "list-items"
    case selfCorrection = "self-correction"
    case connected
    case multiIntent = "multi-intent"
    case ambiguous
    case falseFire = "false-fire"
    case injection
    case sensitive
    case unsupported
}
