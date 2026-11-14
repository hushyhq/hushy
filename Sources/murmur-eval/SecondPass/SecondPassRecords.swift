import Foundation
import MurmurCore

/// What `murmur-eval second-pass` writes for each arm: one row per dictation with its groups, so the tables
/// (how often the second pass ran, what it did, what it cost) are computed from the rows by
/// `scripts/second-pass-report.py`. The text fields hold invented dev text only.
enum SecondPassRecords {
    /// What became of one group's second pass, in the words of the report.
    enum Fate: String, Codable, CaseIterable {
        /// The first pass left nothing the trigger looks for.
        case notTriggered = "not-triggered"
        /// The trigger fired but the first model had given no answer (timed out, busy), so by design nothing was asked.
        case firstPassHadNoAnswer = "first-pass-had-no-answer"
        /// The trigger fired and the first model had answered, yet no second call was made: the second model was
        /// unavailable, the dictation was out of time, or the first pass was a short attempt.
        case unavailable
        /// The second model's answer passed the checks and replaced the first pass.
        case accepted
        /// The second model answered with the first pass's text.
        case unchanged
        /// The second model changed the text and a check kept the first pass.
        case rejected
        /// No answer inside the time allowed.
        case timedOut = "timed-out"
        /// No answer for another reason (busy system, refusal, error).
        case noAnswer = "no-answer"
    }

    struct Group: Codable {
        let index: Int
        let words: Int
        let outcome: String
        let guardCode: String?
        let source: String?
        /// Both passes and their checks, as the app's own trace counts it.
        let modelMs: Int?
        /// Inside the first model's generation calls.
        let callMs: Int?
        /// The guided second ask of the first model after a check objected.
        let retryMs: Int?
        let retries: Int
        let askedAgain: String
        let repairedSpans: Int
        let secondPass: String
        let secondPassMs: Int?
        let secondPassCallMs: Int?
        let secondPassOutcome: String?
        let secondPassGuard: String?
        let triggered: Bool?
        let fate: String
        let firstPassText: String?
        let secondPassAnswer: String?
    }

    struct Call: Codable {
        /// `local` (the Hushy fine-tune), `apple` (the first model's fallback) or `second` (the second pass).
        let backend: String
        let ms: Double
        let outcome: String
    }

    struct Dictation: Codable {
        let set: String
        let id: String
        let spokenWords: Int
        let plannedGroups: Int
        /// From the key release (cleanup start) to the finished text, tone included.
        let waitMs: Double
        let output: String
        /// The set's own scorer, fault kind to count.
        let faults: [String: Int]
        /// Denominators and counts the scorer reports beside the faults.
        let extras: [String: Int]
        let groups: [Group]
        let calls: [Call]
        /// One-minute load average when the dictation started.
        let load: Double
        /// How long the rule-only tone pass takes on this output, by tone, in milliseconds.
        let toneMs: [String: Double]
    }

    struct Arm: Codable {
        let label: String
        /// `live` (real model calls) or `replay` (the answers of the last live arm with the second pass on).
        let kind: String
        /// `on`, `off`, or the second pass's time budget in milliseconds.
        let secondPass: String
        let setting: String
        let level: String
        let path: String
        let bundleID: String
        let firstModel: String
        let secondModel: String?
        let started: String
        let seconds: Double
        let loadAtStart: [Double]
        let loadAtEnd: [Double]
        let thermalAtEnd: String
        let replayHits: Int
        let replayMisses: Int
        let replayLate: Int
        /// Replay arm with the second pass on only: dictations whose text equals the live run's.
        let identicalToLive: Int?
        let dictations: [Dictation]
    }

    /// The trigger is the app's own (`SmartCleaner.hasLeftoverFiller` with the narrow vocabulary the app ships).
    static func fate(of trace: GroupTrace) -> (triggered: Bool?, fate: Fate) {
        let triggered = trace.measured.firstPassText.map { SmartCleaner.hasLeftoverFiller($0, includingMarkers: false) }
        switch trace.secondPass {
        case .used: return (triggered, .accepted)
        case .none:
            guard triggered == true else { return (triggered, .notTriggered) }
            let answered = trace.outcome == .used || trace.outcome == .rejectedByGuard
            return (triggered, answered ? .unavailable : .firstPassHadNoAnswer)
        case .kept:
            switch trace.measured.secondPassOutcome {
            case .timeout?: return (triggered, .timedOut)
            case .used?: return (triggered, .unchanged)
            case .rejectedByGuard?:
                // A check can also "reject" an answer that says the same words: that is an unchanged text, not a refusal.
                let same = sameWords(trace.measured.secondPassAnswer, trace.measured.firstPassText)
                return (triggered, same ? .unchanged : .rejected)
            default: return (triggered, .noAnswer)
            }
        }
    }

    static func sameWords(_ a: String?, _ b: String?) -> Bool {
        guard let a, let b else { return false }
        func plain(_ text: String) -> String {
            text.lowercased().filter { $0.isLetter || $0.isNumber || $0.isWhitespace }
                .split(whereSeparator: \.isWhitespace).joined(separator: " ")
        }
        return plain(a) == plain(b)
    }

    static func group(_ trace: GroupTrace, index: Int) -> Group {
        let verdict = fate(of: trace)
        return Group(
            index: index, words: trace.words, outcome: trace.outcome.rawValue, guardCode: trace.guardCode?.rawValue,
            source: trace.source?.rawValue, modelMs: trace.modelMs, callMs: trace.measured.callMs, retryMs: trace.retryMs,
            retries: trace.retries, askedAgain: trace.askedAgain.rawValue, repairedSpans: trace.repairedSpans,
            secondPass: trace.secondPass.rawValue, secondPassMs: trace.secondPassMs,
            secondPassCallMs: trace.measured.secondPassCallMs, secondPassOutcome: trace.measured.secondPassOutcome?.rawValue,
            secondPassGuard: trace.measured.secondPassGuard?.rawValue, triggered: verdict.triggered, fate: verdict.fate.rawValue,
            firstPassText: trace.measured.firstPassText, secondPassAnswer: trace.measured.secondPassAnswer)
    }
}
