import Foundation

/// Which pass produced a group's text when a second model was asked about the filler the first one left.
/// A fixed category: no words, safe for logs, metrics and History.
public enum SecondPass: String, Sendable, Equatable {
    /// No second pass was made: the first pass's text stands.
    case none
    /// The second model's guarded answer is the text.
    case used
    /// The second model was asked, but did not answer, answered too late or was rejected: the first pass's text stands.
    case kept
}

/// What the cleanup model did for one group of a dictation (a short dictation is one group), kept
/// with the result so a rules draft that was pasted instead of the model's answer can always be
/// traced to a cause: the outcome says whether the model was skipped, timed out, answered and was
/// rejected, or answered and was used, and `guardCode` names the guard that rejected it.
///
/// Counts and timings only. The text fields exist for the eval (`rejectedCandidate` is filled only
/// when the cleaner was built to retain it) and are never logged.
public struct GroupTrace: Sendable, Equatable {
    /// Words in the rules draft the model was (or would have been) asked about.
    public let words: Int
    public let outcome: ModelOutcome
    /// The check that threw the answer away, when one did. A name only: never the guard's own reason.
    public let guardCode: GuardCode?
    /// The model's answer was used and differs from the rules draft.
    public let edited: Bool
    /// Time spent in the model call and its checks, nil when no call was made.
    public let modelMs: Int?
    /// Spans of the model's answer a check objected to that were put back to the draft, with the rest
    /// of the answer kept (see `SmartCleaner`'s span repair). Zero when the answer was used as it came.
    public let repairedSpans: Int
    /// A check objected and every change the model made was the one it objected to, so span repair had nothing of the
    /// model's to keep. A fixed flag, no words.
    public let repairHadNothingToKeep: Bool
    /// Times the model call was repeated after a timeout, a busy system or an error.
    public let retries: Int
    /// The model had been timing out on recent dictations, so this call was one short attempt without a retry.
    public let shortAttempt: Bool
    /// Whether a second model had a look at the filler the first pass left, and what came of it.
    public let secondPass: SecondPass
    /// Whether the model was asked again after a check objected to its answer, and what came of it.
    public let askedAgain: AskedAgain
    /// Time the second ask itself took, in milliseconds (not the first call), nil when the model was not asked again.
    public let retryMs: Int?
    /// The second pass ran only because the trigger was widened to filler markers: the earlier, narrower trigger would not have run it.
    public let secondPassOnlyBecauseWidened: Bool
    /// Time the second pass itself took, in milliseconds (`modelMs` holds both passes), nil when there was none.
    public let secondPassMs: Int?
    /// Time spent waiting on the first model for its first answer, in milliseconds, a repeat after a timeout or a
    /// busy system included; nil when the model was not called. What is left of `modelMs` after this, `retryMs`
    /// and `secondPassMs` is the time the checks took (`checksMs`).
    public let firstAskMs: Int?
    /// Where this group's result came from at release, for a segmented dictation.
    public let source: SmartCleaner.GroupSource?
    /// Eval only: the model's answer when a guard rejected it.
    public let rejectedCandidate: String?
    /// Measurement only (second-pass study): timings and fixed categories, plus text fields that are filled only
    /// when the cleaner was built to retain candidates (the eval). Never logged, never read by the app.
    public var measured = Measured()
    /// How much of the model's answer was made of what was said, when it answered and the other checks let it through
    /// (see `RewriteAccount`). Counts only.
    public var account: RewriteAccount?
    /// Paragraph and line breaks in the model's answer, when it gave one. Numbers only, never the text.
    public var answerBreaks: LineBreakCount?
    /// The model was sent a register line and its answer was refused, so it was asked once more without the line and
    /// this group's text is that plain answer (or the rules draft if that was refused too). The tone then comes from
    /// the word-level pass, as it does for a model that never saw the line.
    public var registerDropped = false
    /// Time the plain second ask took, in milliseconds, when there was one (`registerDropped`).
    public var plainRetryMs: Int?

    public struct Measured: Sendable, Equatable {
        /// Time spent inside the first model's own generation calls for this group (every attempt after a timeout,
        /// not the guided second ask, which is `retryMs`), nil when no call was made.
        public var callMs: Int?
        /// Repeat of the first call after a timeout, busy response or error.
        public var failureRetryMs: Int = 0
        /// The same for the second pass's one call.
        public var secondPassCallMs: Int?
        /// Time in local span repair, including the guards re-run on repaired candidates.
        public var spanRepairMs: Int = 0
        /// A separate model call to break a rules-versus-model tie.
        public var rerankMs: Int = 0
        /// A separate model call to verify a grammar edit.
        public var grammarVerifyMs: Int = 0
        /// What the second model's own call came to (`used` = answered and passed the checks), nil without a second pass.
        public var secondPassOutcome: ModelOutcome?
        /// The check that threw the second model's answer away, when one did.
        public var secondPassGuard: GuardCode?
        /// Eval only: this group's text after the first pass, before any second pass.
        public var firstPassText: String?
        /// Eval only: the second model's answer, accepted or not; nil when it gave none.
        public var secondPassAnswer: String?
        /// Eval only: why the answer to the register ask was refused, when it was (`registerDropped`).
        public var registerRefusal: String?
        /// Eval only: the answer to the register ask when it was refused and the plain ask replaced it (`registerDropped`).
        public var registerAnswer: String?
        /// Eval only: the model's last answer before the checks, used or not; nil when it gave none.
        public var modelAnswer: String?

        public init() {}
    }

    public init(
        words: Int, outcome: ModelOutcome, guardCode: GuardCode?, edited: Bool, modelMs: Int?,
        repairedSpans: Int = 0, repairHadNothingToKeep: Bool = false, retries: Int = 0, shortAttempt: Bool = false, secondPass: SecondPass = .none,
        askedAgain: AskedAgain = .none, retryMs: Int? = nil, secondPassOnlyBecauseWidened: Bool = false, source: SmartCleaner.GroupSource? = nil, rejectedCandidate: String? = nil,
        secondPassMs: Int? = nil, firstAskMs: Int? = nil
    ) {
        self.secondPassMs = secondPassMs
        self.firstAskMs = firstAskMs
        self.secondPassOnlyBecauseWidened = secondPassOnlyBecauseWidened
        self.repairedSpans = repairedSpans
        self.repairHadNothingToKeep = repairHadNothingToKeep
        self.retries = retries
        self.shortAttempt = shortAttempt
        self.secondPass = secondPass
        self.askedAgain = askedAgain
        self.retryMs = retryMs
        self.words = words
        self.outcome = outcome
        self.guardCode = guardCode
        self.edited = edited
        self.modelMs = modelMs
        self.source = source
        self.rejectedCandidate = rejectedCandidate
    }

    func with(source: SmartCleaner.GroupSource) -> GroupTrace {
        var copy = GroupTrace(
            words: words, outcome: outcome, guardCode: guardCode, edited: edited, modelMs: modelMs,
            repairedSpans: repairedSpans, repairHadNothingToKeep: repairHadNothingToKeep, retries: retries, shortAttempt: shortAttempt, secondPass: secondPass, askedAgain: askedAgain, retryMs: retryMs, secondPassOnlyBecauseWidened: secondPassOnlyBecauseWidened, source: source,
            rejectedCandidate: rejectedCandidate, secondPassMs: secondPassMs, firstAskMs: firstAskMs)
        copy.measured = measured
        copy.account = account
        copy.answerBreaks = answerBreaks
        copy.registerDropped = registerDropped
        copy.plainRetryMs = plainRetryMs
        return copy
    }

    func with(secondPass: SecondPass, outcome: ModelOutcome? = nil, guardCode: GuardCode?? = nil, modelMs: Int? = nil, secondPassMs: Int? = nil, widenedOnly: Bool = false) -> GroupTrace {
        var copy = GroupTrace(
            words: words, outcome: outcome ?? self.outcome, guardCode: guardCode ?? self.guardCode, edited: edited || secondPass == .used,
            modelMs: modelMs ?? self.modelMs, repairedSpans: repairedSpans, repairHadNothingToKeep: repairHadNothingToKeep, retries: retries, shortAttempt: shortAttempt,
            secondPass: secondPass, askedAgain: askedAgain, retryMs: retryMs, secondPassOnlyBecauseWidened: widenedOnly, source: source,
            rejectedCandidate: secondPass == .used ? nil : rejectedCandidate, secondPassMs: secondPassMs ?? self.secondPassMs,
            firstAskMs: firstAskMs)
        copy.measured = measured
        copy.account = account
        copy.answerBreaks = answerBreaks
        copy.registerDropped = registerDropped
        copy.plainRetryMs = plainRetryMs
        return copy
    }

    /// This trace after a second pass that took `elapsed`: the pass's own time is kept apart (`secondPassMs`), and
    /// `modelMs` is the first pass's time plus it.
    func afterSecondPass(
        _ pass: SecondPass, took elapsed: Duration, outcome: ModelOutcome? = nil, guardCode: GuardCode?? = nil,
        widenedOnly: Bool
    ) -> GroupTrace {
        let secondMs = Int(ModelPace.ms(elapsed))
        return with(
            secondPass: pass, outcome: outcome, guardCode: guardCode, modelMs: (modelMs ?? 0) + secondMs,
            secondPassMs: secondMs, widenedOnly: widenedOnly)
    }

    /// Time between the first model's answer and the end of the first pass, in milliseconds: the checks on the
    /// answer, span repair, and the tie-break or grammar-verification call when one was made. nil when the first
    /// ask was not timed (no model call). The plain second ask after a refused register answer is its own field
    /// (`plainRetryMs`): before 2026-10-28 it was counted here, and a whole model call read as a second of checks.
    public var checksMs: Int? {
        guard let modelMs, let firstAskMs else { return nil }
        return max(0, modelMs - firstAskMs - (retryMs ?? 0) - (secondPassMs ?? 0) - (plainRetryMs ?? 0))
    }

    /// Where one sentence's cleanup time went, for the `cleanup group` log line. Milliseconds, counts and fixed
    /// category words only: never a word of the dictation. A step that did not run prints `-`.
    ///
    /// `firstMs` the first model's first answer (repeats after a timeout included) · `checksMs` the checks on it ·
    /// `askAgainMs` the second ask after a check objected · `plainMs` the ask without the register line after the
    /// register answer was refused · `secondMs` the second model's pass · `totalMs` all of it · `retries` repeats after
    /// a timeout or a busy system · `again` what came of asking again · `second` what came of the second pass.
    public var timingFields: String {
        func ms(_ value: Int?) -> String { value.map(String.init) ?? "-" }
        return "firstMs=\(ms(firstAskMs)) checksMs=\(ms(checksMs)) askAgainMs=\(ms(retryMs)) plainMs=\(ms(plainRetryMs)) "
            + "secondMs=\(ms(secondPassMs)) totalMs=\(ms(modelMs)) retries=\(retries) again=\(askedAgain.rawValue) "
            + "second=\(secondPass.rawValue)"
    }

    /// `why=` label for a log line or an eval row: the outcome, plus the guard's reason when a guard
    /// rejected the answer.
    public var label: String {
        guard outcome == .rejectedByGuard, let guardCode else { return outcome.rawValue }
        return "\(outcome.rawValue)(\(guardCode.rawValue))"
    }
}

/// Carries the model's raw answer out of `SmartCleaner.refine` for the eval. One per call.
final class CandidateSink: @unchecked Sendable {
    private let keepsAnswer: Bool
    private var held: String?
    /// How many times the call was repeated after a failure that can pass on a second try.
    var newParagraph = false
    /// Breaks in the model's answer (counts only), kept in every build, unlike the answer text.
    var answerBreaks: LineBreakCount?
    var retries = 0
    /// Spans put back to the draft by `SpanRepair` before the answer was accepted.
    var repairedSpans = 0
    /// Span repair found every change the model made to be the one the check objected to.
    var repairHadNothingToKeep = false
    /// Whether the model was asked again after a check objected, and what came of it.
    var askedAgain: AskedAgain = .none
    /// How much of the model's own answer was made of what was said (see `RewriteAccount`).
    var account: RewriteAccount?
    /// How long the second ask took, when there was one.
    var retryMs: Int?
    /// The register line was dropped and the model asked again (see `GroupTrace.registerDropped`), and how long that took.
    var registerDropped = false
    var plainRetryMs: Int?
    /// Measurement only: time inside the model's own generation calls (every attempt), nil when none was made.
    var callMs: Int?
    /// Time through the first ask, including repeats after timeout or busy response.
    var firstAskMs: Int?
    var failureRetryMs = 0
    var spanRepairMs = 0
    var grammarVerifyMs = 0
    /// False once an earlier group of the same dictation timed out even after its retry.
    var allowsRetry = true
    /// How long the dictation may keep waiting on the model, when it has a clock.
    var deadline: WaitClock?

    init(keepsAnswer: Bool) { self.keepsAnswer = keepsAnswer }

    var answer: String? {
        get { held }
        set { if keepsAnswer { held = newValue } }
    }

    private var heldRefusal: String?
    /// Eval only: why the register answer was refused (`GroupTrace.Measured.registerRefusal`).
    var registerRefusal: String? {
        get { heldRefusal }
        set { if keepsAnswer { heldRefusal = newValue } }
    }

    private var heldRegisterAnswer: String?
    /// Eval only: the refused answer to the register ask (`GroupTrace.Measured.registerAnswer`).
    var registerAnswer: String? {
        get { heldRegisterAnswer }
        set { if keepsAnswer { heldRegisterAnswer = newValue } }
    }
}
