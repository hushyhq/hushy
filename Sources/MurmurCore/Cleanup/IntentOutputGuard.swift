import Foundation

/// The whole-transcript model chooses which spoken material expresses the final intent.
/// This gate refuses unsupported values, a lost negation and malformed answers. It does not restore omissions, except one: a word the
/// answer left a hole where, in the middle of a clause, is put back where it stood (`DroppedContent`).
enum IntentOutputGuard {
    /// Whether the speaker took something back in `raw`, so the words that were said hold a value that is not the final one.
    static func hasRetraction(_ raw: String) -> Bool {
        IntentCorrection.resolve(raw) != nil || ModelHints.hasCorrectionCue(raw) || SpokenNumberRuns(raw).retractable.contains(true)
    }

    /// `register` is the one the model was asked to write in, when it was sent the register line. In the prompt register
    /// the model puts identifiers, paths and commands in backticks, so a backtick span around something the speaker said
    /// is not "a changed literal"; every other check is the same in every register.
    /// `knownNames` are the person's Dictionary terms and installed apps (`KnownProductNames`).
    static func check(
        _ answer: String, raw: String, block: PersonBlock? = nil, register: IntentRegister? = nil, knownNames: [String] = []
    ) -> SmartCleaner.Refinement {
        check(answer, raw: raw, spellingWords: block?.spellingWords ?? [], register: register, knownNames: knownNames)
    }

    /// The prompt register may put code in backticks, but only code. A span the speaker did not have that wraps ordinary
    /// words ("`son` at `agent`") is put back to plain words before the checks, so the rest of a good answer stands.
    private static func plainingOrdinaryCode(_ answer: String, raw: String, register: IntentRegister?) -> String {
        guard register == .prompt, answer.contains("`") else { return answer }
        return LiteralSyntaxProtection.unwrappingOrdinarySpans(in: answer, draft: raw)
    }

    static func check(
        _ answer: String, raw: String, spellingWords: Set<String>, register: IntentRegister? = nil, knownNames: [String] = []
    ) -> SmartCleaner.Refinement {
        let verdict = filled(
            plainingOrdinaryCode(answer, raw: raw, register: register), raw: raw, spellingWords: spellingWords,
            register: register, knownNames: knownNames)
        // A register rewords on purpose, and its answer may still leave out no name the speaker said (founder, 2026-11-11:
        // "never drop a named person"). Refused, the answer is asked for again without the register line, so this costs
        // a re-ask, never the rules text (`SmartCleaner.refine`).
        guard register != nil, case .accepted(let text, _) = verdict, DroppedContent.dropsName(answer: text, raw: raw) else {
            return verdict
        }
        return .rejected(DroppedContent.droppedNameReason)
    }

    private static func filled(
        _ answer: String, raw: String, spellingWords: Set<String>, register: IntentRegister?, knownNames: [String]
    ) -> SmartCleaner.Refinement {
        let verdict = judge(answer, raw: raw, spellingWords: spellingWords, register: register, knownNames: knownNames)
        // A word the answer left a hole where, in the middle of a clause, is put back where it stood; the answer then goes
        // through every check again, as it will be pasted. Run last, so that a refusal for any other reason keeps its reason.
        guard case .accepted(let text, _) = verdict, let reason = DroppedContent.violation(answer: text, raw: raw, register: register)
        else { return verdict }
        guard let restored = DroppedContent.restoring(answer: text, raw: raw, register: register) else { return .rejected(reason) }
        return judge(restored, raw: raw, spellingWords: spellingWords, register: register, knownNames: knownNames)
    }

    private static func judge(
        _ answer: String, raw: String, spellingWords: Set<String>, register: IntentRegister?, knownNames: [String]
    ) -> SmartCleaner.Refinement {
        let cleaned = answer.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "^(Output|Cleaned text):\\s*", with: "", options: .regularExpression)
        guard !cleaned.isEmpty else { return .rejected("empty") }
        let answerWords = OutputGuard.words(cleaned)
        let rawWords = OutputGuard.words(raw)
        guard answerWords.count <= max(12, rawWords.count * 2 + 3) else { return .rejected("longer than transcript") }
        if let reason = LiteralSyntaxProtection.violation(
            candidate: cleaned, draft: raw, allowingSpokenLiterals: register == .prompt) { return .rejected(reason) }
        // Numbers are read the way people say them ("the first", "two to three hundred"; `SpokenValueReading`).
        if let reason = CorrectionBound.violation(
            answer: cleaned, draft: raw, spellingWords: spellingWords, knownNames: knownNames, readsSpokenValues: true) {
            return .rejected(reason)
        }
        // A code-like name keeps its digits, whatever other numbers the speaker said (`IdentifierDigits`).
        if let reason = IdentifierDigits.violation(answer: cleaned, said: raw) { return .rejected(reason) }
        // A "not" or "never" lost turns the sentence round; only one a correction took back may go (`NegationPolarity`).
        if NegationPolarity.dropsNegation(answer: cleaned, said: raw) { return .rejected("dropped negation") }
        if RetractedWording.kept(answer: cleaned, raw: raw) != nil { return .rejected("kept retracted wording") }
        if let valueReason = SpokenValueReading.valueViolation(answer: cleaned, draft: raw, corrected: hasRetraction(raw)) {
            return .rejected(valueReason)
        }
        return .accepted(cleaned)
    }
}
