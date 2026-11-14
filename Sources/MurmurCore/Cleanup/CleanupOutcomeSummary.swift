import Foundation

/// One content-free line about what the model did for a dictation: saved with the History entry as a
/// short code and shown there as a plain sentence, so a rules-only result is never unexplained.
///
/// Code shape: `<outcome>[/<guard>][:<parts>/<total>]`, for example `ran`, `timeout`,
/// `rejected-by-guard/kept-retracted-item`, or `timeout:2/12` when 2 of 12 parts of a long dictation
/// did not run. Only outcome names and guard names appear; never a reason string, a word, or an app.
public struct CleanupOutcomeSummary: Equatable, Sendable {
    public let code: String
    private let outcome: Stage
    private let guardCode: GuardCode?
    private let parts: (affected: Int, total: Int)?

    private enum Stage: String {
        case ran, ranRepaired = "ran-repaired", ranSecond = "ran-second", ranSecondKept = "ran-second-kept"
        case notAsked = "not-asked", skippedSlow = "skipped-slow", breakerOpen = "breaker-open"
        case timeout, timeoutShort = "timeout-short", modelError = "model-error", modelBusy = "model-busy", refused
        case releaseWindow = "release-window", prewarmLate = "prewarm-late", notResponding = "not-responding", unavailable
        case thermalSerious = "thermal-serious", rejectedByGuard = "rejected-by-guard"
    }

    /// The summary for a dictation's groups, or nil when no model pass was meant to run (Verbatim).
    /// The first group that did not run decides the outcome; `parts` says how many were affected.
    public init?(groups: [GroupTrace], level: CleanupLevel) {
        guard level != .verbatim, !groups.isEmpty else { return nil }
        let failed = groups.filter { $0.outcome != .used }
        let decisive = failed.first
        let stage: Stage
        if let decisive {
            stage = decisive.outcome == .timeout && decisive.shortAttempt
                ? .timeoutShort : (Stage(rawValue: decisive.outcome.rawValue) ?? .rejectedByGuard)
        } else {
            stage = groups.contains { $0.secondPass == .used } ? .ranSecond
                : groups.contains { $0.secondPass == .kept } ? .ranSecondKept
                : groups.contains { $0.repairedSpans > 0 } ? .ranRepaired : .ran
        }
        let code = decisive?.guardCode
        let parts = groups.count > 1 && !failed.isEmpty ? (failed.count, groups.count) : nil
        self.init(stage: stage, guardCode: stage == .rejectedByGuard ? (code ?? GuardCode.other) : nil, parts: parts)
    }

    /// Reads a saved code. Nil for anything that is not one (an old row, a future format).
    public init?(code: String) {
        var rest = Substring(code)
        var parts: (Int, Int)?
        if let colon = rest.lastIndex(of: ":") {
            let counts = rest[rest.index(after: colon)...].split(separator: "/").compactMap { Int($0) }
            guard counts.count == 2 else { return nil }
            parts = (counts[0], counts[1])
            rest = rest[..<colon]
        }
        var guardCode: GuardCode?
        if let slash = rest.firstIndex(of: "/") {
            guard let parsed = GuardCode(rawValue: String(rest[rest.index(after: slash)...])) else { return nil }
            guardCode = parsed
            rest = rest[..<slash]
        }
        guard let stage = Stage(rawValue: String(rest)) else { return nil }
        self.init(stage: stage, guardCode: guardCode, parts: parts)
    }

    private init(stage: Stage, guardCode: GuardCode?, parts: (Int, Int)?) {
        self.outcome = stage
        self.guardCode = guardCode
        self.parts = parts.map { (affected: $0.0, total: $0.1) }
        var code = stage.rawValue
        if let guardCode { code += "/" + guardCode.rawValue }
        if let parts { code += ":\(parts.0)/\(parts.1)" }
        self.code = code
    }

    public static func == (lhs: CleanupOutcomeSummary, rhs: CleanupOutcomeSummary) -> Bool { lhs.code == rhs.code }

    /// True when the model's answer shaped the text.
    public var ran: Bool { [.ran, .ranRepaired, .ranSecond, .ranSecondKept].contains(outcome) }

    /// The sentence History shows.
    public var plainLine: String {
        let scope = parts.map { " (\($0.affected) of \($0.total) parts)" } ?? ""
        switch outcome {
        case .ran: return "The model pass ran."
        case .ranRepaired:
            return "The model pass ran. A check objected to part of its rewrite, so only that part was put back."
        case .ranSecond:
            return "The model pass ran. A second pass by Apple's model tidied filler the first one had left."
        case .ranSecondKept:
            return "The model pass ran. A second pass for leftover filler was tried, but its answer was not used."
        case .notAsked: return "The model pass did not run: there was nothing to clean."
        case .skippedSlow, .breakerOpen: return "Model pass skipped\(scope): the model had been too slow."
        case .timeout: return "Model pass skipped\(scope): the model took too long."
        case .timeoutShort:
            return "Model pass skipped\(scope): the model took too long. It had been timing out on recent dictations, "
                + "so Hushy tried once, for a short time."
        case .modelError: return "Model pass skipped\(scope): the model returned an error."
        case .modelBusy: return "Model pass skipped\(scope): the system was too busy to run the model."
        case .refused: return "Model pass skipped\(scope): the model declined this text."
        case .releaseWindow, .prewarmLate:
            return "Model pass skipped\(scope): the model was still working when the text was due."
        case .notResponding:
            return "Model pass skipped\(scope): the model is not responding. Earlier requests to it are still stuck, so no new one was sent."
        case .unavailable: return "Model pass skipped: no cleanup model is available for this text on this Mac."
        case .thermalSerious: return "Model pass skipped\(scope): the Mac was running hot."
        case .rejectedByGuard:
            let what = (guardCode ?? .other).plainName
            return "Kept the plain version\(scope): a check protecting \(what) rejected the model's rewrite."
        }
    }
}
