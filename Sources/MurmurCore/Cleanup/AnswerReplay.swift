import Foundation

/// What the whole-transcript checks make of one model answer, for the eval that replays saved answers
/// (`murmur-eval answer-check`). Counts and words only; nothing here changes how a dictation is cleaned.
public enum AnswerReplay {
    public struct Verdict: Sendable {
        /// "accepted", or the reason the answer was refused.
        public let verdict: String
        /// The text the checks would paste: the answer, with any dropped content put back.
        public let text: String
        public let lostContent: [String]
        public let unpaidNegations: Int
        public let negations: (spoken: Int, written: Int)
    }

    public static func check(answer: String, raw: String, register: IntentRegister?) -> Verdict {
        var verdict = "accepted"
        var text = answer
        switch IntentOutputGuard.check(answer, raw: raw, register: register) {
        case .accepted(let accepted, _): text = accepted
        case .rejected(let reason): verdict = reason
        }
        return Verdict(
            verdict: verdict, text: text, lostContent: DroppedContent.lost(answer: answer, raw: raw, register: register),
            unpaidNegations: NegationPolarity.unpaidNegations(answer: answer, draft: raw),
            negations: (NegationPolarity.count(in: raw), NegationPolarity.count(in: answer)))
    }
}
