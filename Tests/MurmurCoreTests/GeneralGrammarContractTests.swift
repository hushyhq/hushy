import Testing
import Synchronization
@testable import MurmurCore

@Suite("General Clean grammar experiment")
struct GeneralGrammarContractTests {
    @Test("v2/v3 prompts retain their narrow contracts and broad profiles are separately versioned")
    func promptProfilesAreSeparate() {
        let v2 = CompactCleanupPrompt.systemText(level: .clean, version: .v2)
        let v3 = CompactCleanupPrompt.systemText(level: .clean, version: .v3)
        let v4 = CompactCleanupPrompt.systemText(level: .clean, version: .v4)
        let bridge = CompactCleanupPrompt.systemText(level: .clean, version: .v4PolishedBridge)

        #expect(CompactCleanupPrompt.version == "compact-v2")
        #expect(CompactCleanupPrompt.versionV3 == "compact-v3")
        #expect(CompactCleanupPrompt.versionV4 == "compact-v4")
        #expect(CompactCleanupPrompt.versionV4PolishedBridge == "compact-v4-polished-bridge")
        #expect(v2.contains("Do not fix grammar") && !v2.contains("lexical verb inflection"))
        #expect(v3.contains("auxiliary verbs only") && !v3.contains("lexical verb inflection"))
        #expect(v4.contains("lexical verb inflection") && v4.contains("complement syntax"))
        #expect(bridge.contains("learned grammar-repair capability of the Polished task"))
        #expect(bridge.contains("This is not a request to polish"))

        let broadInstructions = SmartCleaner.cleanupInstructions(confidenceGuided: false, generalGrammar: true)
        #expect(CompactCleanupPrompt.systemText(forInstructions: broadInstructions, version: .v2) == nil)
        #expect(CompactCleanupPrompt.systemText(forInstructions: broadInstructions, version: .v3) == nil)
        #expect(CompactCleanupPrompt.systemText(forInstructions: broadInstructions, version: .v4) == v4)
        #expect(CompactCleanupPrompt.systemText(forInstructions: broadInstructions, version: .v4PolishedBridge) == bridge)
        #expect(!broadInstructions.contains("Do not fix grammar"))
        #expect(!broadInstructions.contains("left exactly as spoken at this level"))
    }

    @Test("only normalized-word-identical legacy-safe output bypasses verification")
    func typedCandidateRouting() {
        #expect(GeneralGrammarCandidateGate.evaluate(
            answer: "We need the report!", raw: "We need the report.", draft: "We need the report.")
            == .hardReject("changed question or emphasis punctuation"))
        #expect(GeneralGrammarCandidateGate.evaluate(
            answer: "We need the report.", raw: "We need the report.", draft: "We need the report.")
            == .legacySafe("We need the report."))

        for answer in ["I sent the file to Ada.", "Ada sent the file to Ravi.", "I sent a file."] {
            let draft = answer == "I sent the file to Ada." ? "I sent a file to Ada."
                : (answer == "Ada sent the file to Ravi." ? "Ravi sent the file to Ada." : "I sent the file.")
            if case .needsGrammarVerification = GeneralGrammarCandidateGate.evaluate(
                answer: answer, raw: draft, draft: draft) { continue }
            Issue.record("Substantive candidate bypassed verification: \(draft) → \(answer)")
        }

        if case .hardReject(let reason) = GeneralGrammarCandidateGate.evaluate(
            answer: "Send it at 6.", raw: "No, send it at 5, actually 6.", draft: "No, send it at 5, actually 6.") {
            #expect(["changed digits", "dropped negation"].contains(reason))
        } else {
            Issue.record("A correction cue globally exempted a changed number")
        }
        #expect(ModalQuantifierGuard.violation(answer: "You could send any two files.", draft: "You can send any two files.") != nil)
        #expect(ModalQuantifierGuard.violation(answer: "You can send any three files.", draft: "You can send any two files.") != nil)
        #expect(CriticalTokenGuard.negationCount(in: "cant, isnt, couldnt, and cannot") == 4)
        #expect(CriticalTokenGuard.violation(answer: "I know the answer.", draft: "I dont know the answer.", allowCorrectionChanges: false)
            == "dropped negation")
    }

    @Test("a grammar edit goes through a fresh structured verifier and can pass at high confidence")
    func verifierRoutingAndConfidence() async {
        let model = ScriptedGrammarModel(generator: "The invoices are due for the meeting.", verdict: .accept)
        let raw = "the invoices is due for the meting"
        let confidences = [
            WordConfidence(word: "the", confidence: 0.99),
            WordConfidence(word: "invoices", confidence: 0.99),
            WordConfidence(word: "is", confidence: 0.99),
            WordConfidence(word: "due", confidence: 0.99),
            WordConfidence(word: "for", confidence: 0.99),
            WordConfidence(word: "the", confidence: 0.99),
            WordConfidence(word: "meting", confidence: 0.2),
        ]
        let output = await SmartCleaner(model: model, health: ModelHealth()).clean(
            raw, confidences: confidences,
            options: CleanupOptions(level: .clean, grammarContract: .generalMinimal),
            strategy: .model, incremental: false)

        #expect(output.usedModel)
        #expect(output.text == "The invoices are due for the meeting.")
        #expect(model.calls.count == 2)
        #expect(model.calls[0].schema == "Cleaned")
        #expect(model.calls[0].instructions.contains("A clear grammar repair may change a confidently recognized"))
        #expect(model.calls[0].prompt.contains("⟦meting.⟧"))
        #expect(model.calls[1].schema == "GeneralGrammarVerification")
        #expect(model.calls[1].instructions == GeneralGrammarVerifier.instructions)
        #expect(model.calls[1].prompt.contains("changedWordSpans"))
        #expect(model.calls[1].prompt.contains("the invoices is due for the meting"))
        #expect(model.calls[1].prompt.contains("\"lowConfidenceWords\":[\"meting\"]"))
    }

    @Test("missing and all-high confidence remain distinct while both permit verified grammar")
    func confidenceAbsentVersusAllHigh() async {
        let absent = ScriptedGrammarModel(generator: "The invoice is due.", verdict: .accept)
        let absentOutput = await SmartCleaner(model: absent, health: ModelHealth()).clean(
            "the invoice are due", options: CleanupOptions(level: .clean, grammarContract: .generalMinimal),
            strategy: .model, incremental: false)
        #expect(absentOutput.usedModel)
        #expect(absent.calls[0].prompt.contains("Transcript: The invoice are due."))
        #expect(!absent.calls[0].prompt.contains("⟦"))
        #expect(absent.calls[1].prompt.contains("\"lowConfidenceWords\":null"))

        let allHigh = ScriptedGrammarModel(generator: "The invoice is due.", verdict: .accept)
        let confidences = [
            WordConfidence(word: "the", confidence: 0.99),
            WordConfidence(word: "invoice", confidence: 0.99),
            WordConfidence(word: "are", confidence: 0.99),
            WordConfidence(word: "due", confidence: 0.99),
        ]
        let allHighOutput = await SmartCleaner(model: allHigh, health: ModelHealth()).clean(
            "the invoice are due", confidences: confidences,
            options: CleanupOptions(level: .clean, grammarContract: .generalMinimal),
            strategy: .model, incremental: false)
        #expect(allHighOutput.usedModel)
        #expect(!allHigh.calls[0].instructions.contains("Some words are wrapped"))
        #expect(allHigh.calls[1].prompt.contains("\"lowConfidenceWords\":[]"))
    }

    @Test("uncertain, malformed, or timed-out verifier results abstain")
    func verifierAbstention() async {
        let uncertain = ScriptedGrammarModel(generator: "The invoice is due.", verdict: .uncertain)
        let output = await SmartCleaner(model: uncertain, health: ModelHealth()).clean(
            "the invoice are due", options: CleanupOptions(level: .clean, grammarContract: .generalMinimal),
            strategy: .model, incremental: false)
        #expect(!output.usedModel)
        #expect(output.rejection?.contains("grammar verification") == true)
        #expect(uncertain.calls.count == 2)

        let malformed = ScriptedGrammarModel(generator: "The invoice is due.", malformedVerifier: true)
        let malformedOutput = await SmartCleaner(model: malformed, health: ModelHealth()).clean(
            "the invoice are due", options: CleanupOptions(level: .clean, grammarContract: .generalMinimal),
            strategy: .model, incremental: false)
        #expect(!malformedOutput.usedModel)
        #expect(malformedOutput.rejection?.contains("grammar verification") == true)

        let failed = ScriptedGrammarModel(generator: "The invoice is due.", throwVerifier: true)
        let failedOutput = await SmartCleaner(model: failed, health: ModelHealth()).clean(
            "the invoice are due", options: CleanupOptions(level: .clean, grammarContract: .generalMinimal),
            strategy: .model, incremental: false)
        #expect(!failedOutput.usedModel)
        #expect(failedOutput.rejection?.contains("grammar verification") == true)

        let timed = DelayedGrammarModel()
        let verdict = await GeneralGrammarVerifier.assess(
            model: timed, transcript: "A child walk home.", rulesDraft: "A child walk home.",
            candidate: "A child walks home.", budget: .milliseconds(1))
        #expect(verdict == nil)
    }

    @Test("verifier cannot override hard fact checks or strict code/language routing")
    func hardVetoAndContextRouting() async {
        let factChange = ScriptedGrammarModel(generator: "Send it at 6.", verdict: .accept)
        let factOutput = await SmartCleaner(model: factChange, health: ModelHealth()).clean(
            "send it at 5", options: CleanupOptions(level: .clean, grammarContract: .generalMinimal),
            strategy: .model, incremental: false)
        #expect(!factOutput.usedModel)
        #expect(factChange.calls.count == 1)

        let code = ScriptedGrammarModel(generator: "The receipts are due.", verdict: .accept)
        let codeOutput = await SmartCleaner(model: code, health: ModelHealth()).clean(
            "the invoices is due", options: CleanupOptions(level: .clean, isCodeContext: true, grammarContract: .generalMinimal),
            strategy: .model, incremental: false)
        #expect(!codeOutput.usedModel)
        #expect(code.calls.count == 1)
        #expect(code.calls[0].instructions.contains("Do not fix grammar"))

        let spanish = ScriptedGrammarModel(generator: "Las facturas están listas.", verdict: .accept)
        let spanishOutput = await SmartCleaner(model: spanish, health: ModelHealth()).clean(
            "las factura está lista", options: CleanupOptions(level: .clean, detectedLanguage: "es", grammarContract: .generalMinimal),
            strategy: .model, incremental: false)
        #expect(!spanishOutput.usedModel)
        #expect(spanish.calls.count == 1)
        #expect(spanish.calls[0].instructions.contains("Do not fix grammar"))
    }

    @Test("v4 training pairs require independent semantic review")
    func trainingPairReviewRequirement() {
        let raw = "A child walk home."
        let target = "A child walks home."
        let legacy = TrainingPairCheck.check(raw: raw, target: target, level: .clean, version: .v2)
        let v3 = TrainingPairCheck.check(raw: raw, target: target, level: .clean, version: .v3)
        let v4 = TrainingPairCheck.check(raw: raw, target: target, level: .clean, version: .v4)
        let bridge = TrainingPairCheck.check(raw: raw, target: target, level: .clean, version: .v4PolishedBridge)
        #expect(legacy.reviewRequirement == .none)
        #expect(v3.reviewRequirement == .none)
        #expect(v4.reviewRequirement == .independentSemanticReview)
        #expect(bridge.reviewRequirement == .independentSemanticReview)
    }
}

private final class ScriptedGrammarModel: LanguageModel, @unchecked Sendable {
    struct Call: Sendable {
        let schema: String
        let instructions: String
        let prompt: String
    }

    private let generator: String
    private let verdict: GeneralGrammarVerification.Verdict
    private let malformedVerifier: Bool
    private let throwVerifier: Bool
    private let state = Mutex<[Call]>([])

    init(
        generator: String, verdict: GeneralGrammarVerification.Verdict = .accept,
        malformedVerifier: Bool = false, throwVerifier: Bool = false
    ) {
        self.generator = generator
        self.verdict = verdict
        self.malformedVerifier = malformedVerifier
        self.throwVerifier = throwVerifier
    }

    var calls: [Call] { state.withLock { $0 } }
    var identifier: String { "scripted-general-grammar" }
    var availability: LanguageModelAvailability { .available }
    func supportsLanguage(_ languageCode: String) -> Bool { true }
    func prewarm(instructions: String) {}
    func prefixCache(instructions: String) async {}

    func respond(instructions: String, prompt: String, schema: GenerationSchemaSpec, options: LanguageModelOptions) async throws -> String {
        state.withLock { $0.append(Call(schema: schema.name, instructions: instructions, prompt: prompt)) }
        if schema.name == "Cleaned" { return CompactCleanupPrompt.answerJSON(generator) }
        if throwVerifier { throw LanguageModelError.unavailable("scripted verifier failure") }
        if malformedVerifier { return "{}" }
        let accepted = verdict == .accept
        let allPreserved = accepted
        return """
            {"verdict":"\(verdict.rawValue)","grammarImproved":\(accepted),"contentAndRolesPreserved":\(allPreserved),"timeQuantityPolarityModalityPreserved":\(allPreserved),"toneAndIntentPreserved":\(allPreserved),"noAmbiguityIntroduced":\(allPreserved)}
            """
    }
}

private struct DelayedGrammarModel: LanguageModel {
    var identifier: String { "delayed-verifier" }
    var availability: LanguageModelAvailability { .available }
    func supportsLanguage(_ languageCode: String) -> Bool { true }
    func prewarm(instructions: String) {}
    func prefixCache(instructions: String) async {}
    func respond(instructions: String, prompt: String, schema: GenerationSchemaSpec, options: LanguageModelOptions) async throws -> String {
        try await Task.sleep(for: .seconds(1))
        return "{}"
    }
}
