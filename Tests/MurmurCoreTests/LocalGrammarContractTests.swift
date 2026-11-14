import Testing
import Synchronization
@testable import MurmurCore

@Suite("Candidate Clean local grammar contract")
struct LocalGrammarContractTests {
    @Test("compact prompt versions keep legacy Clean text and version the candidate separately")
    func promptVersions() throws {
        let legacy = CompactCleanupPrompt.systemText(level: .clean, version: .v2)
        let candidate = CompactCleanupPrompt.systemText(level: .clean, version: .v3)
        #expect(CompactCleanupPrompt.version == "compact-v2")
        #expect(CompactCleanupPrompt.versionV3 == "compact-v3")
        #expect(legacy.contains("Do not fix grammar"))
        #expect(candidate.contains("auxiliary verbs only"))
        #expect(candidate.contains("the invoices is due"))
        #expect(candidate.contains("I saw a apple"))

        let candidateInstructions = SmartCleaner.cleanupInstructions(confidenceGuided: false, localGrammar: true)
        #expect(candidateInstructions != SmartCleaner.cleanupInstructions(confidenceGuided: false))
        #expect(!candidateInstructions.contains("Do not fix grammar"))
        #expect(!candidateInstructions.contains("left exactly as spoken at this level"))
        #expect(candidateInstructions.contains("auxiliary agreement among am/is/are"))
        #expect(candidateInstructions.contains("Output: The reports are due Friday."))
        #expect(!candidateInstructions.contains("Output: The reports is due Friday"))
        #expect(CompactCleanupPrompt.systemText(forInstructions: candidateInstructions, version: .v2) == legacy)
        #expect(CompactCleanupPrompt.systemText(forInstructions: candidateInstructions, version: .v3) == candidate)
        let legacyInstructions = SmartCleaner.cleanupInstructions(confidenceGuided: false)
        #expect(CompactCleanupPrompt.systemText(forInstructions: legacyInstructions, version: .v3) == legacy)
    }

    @Test("candidate accepts articles and auxiliary agreement without Polished clause permissions")
    func localGrammarAllowance() {
        #expect(isAccepted("I saw an apple", from: "I saw a apple", profile: .localGrammar))
        #expect(isAccepted("the invoices are due", from: "the invoices is due", profile: .localGrammar))
        #expect(isAccepted("the invoices are due", from: "the invoices is due", profile: .grammarRepair))
        #expect(!isAccepted("client send it", from: "send it to client", profile: .localGrammar))
        #expect(!isAccepted("ada sent to ravi", from: "ravi sent to ada", profile: .localGrammar))
        #expect(!isAccepted("I saw a client", from: "I saw the client", profile: .localGrammar))
    }

    @Test("candidate keeps noun number, modal force, and critical tokens unchanged")
    func localGrammarBoundaries() {
        #expect(!isAccepted("the reports are ready", from: "the report is ready", profile: .localGrammar))
        #expect(!isAccepted("it cans fail", from: "it can fail", profile: .localGrammar))
        #expect(!isAccepted("ship it on Friday", from: "do not ship it on Friday", profile: .localGrammar))
        #expect(!isAccepted("ship it on Monday", from: "ship it on Friday", profile: .localGrammar))
        #expect(isAccepted("the invoices are due for the meeting", from: "the invoices is due for the meting",
                           profile: .localGrammar, lowConfidenceWords: ["meting"]))
        #expect(!isAccepted("the invoices are due", from: "the invoices is due for the meting",
                            profile: .localGrammar, lowConfidenceWords: ["meting"]))
        #expect(!isAccepted("ada sent to ravi", from: "ravi sent to ada", profile: .localGrammar,
                            lowConfidenceWords: ["ravi"]))
    }

    @Test("training pair check uses the requested prompt and guard version")
    func trainingPairVersions() {
        let raw = "the invoices is due"
        let target = "The invoices are due."
        let legacy = TrainingPairCheck.check(raw: raw, target: target, level: .clean, version: .v2)
        let candidate = TrainingPairCheck.check(raw: raw, target: target, level: .clean, version: .v3)
        #expect(legacy == TrainingPairCheck.check(raw: raw, target: target, level: .clean))
        #expect(candidate.rejection == nil)
    }

    @Test("minimal Clean sends candidate instructions and accepts article and auxiliary edits")
    func minimalCleanEndToEnd() async {
        let model = CapturingModel(answer: "I saw an apple.")
        let output = await SmartCleaner(model: model, health: ModelHealth()).clean(
            "I saw a apple", options: CleanupOptions(level: .clean, grammarContract: .minimal))
        #expect(output.usedModel)
        #expect(output.text == "I saw an apple.")
        #expect(model.calls.first?.instructions.contains("auxiliary agreement among am/is/are") == true)
    }

    @Test("candidate permits high-confidence grammar repair alongside an unrelated low-confidence correction")
    func confidenceGuidedMinimalClean() async {
        let model = CapturingModel(answer: "The invoices are due for the meeting.")
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
            raw, confidences: confidences, options: CleanupOptions(level: .clean, grammarContract: .minimal))
        #expect(output.usedModel)
        #expect(output.text == "The invoices are due for the meeting.")
        #expect(model.calls.first?.instructions.contains("local grammar fixes") == true)
        #expect(model.calls.first?.prompt.contains("⟦meting.⟧") == true)
    }

    @Test("legacy, code, and non-English Clean keep the strict contract")
    func strictContextRouting() async {
        let raw = "the team have access"
        let answer = "The team has access."
        let legacy = CapturingModel(answer: answer)
        let legacyOutput = await SmartCleaner(model: legacy, health: ModelHealth()).clean(
            raw, options: CleanupOptions(level: .clean))
        #expect(!legacyOutput.usedModel)
        #expect(legacyOutput.rejection != nil)
        #expect(legacy.calls.first?.instructions.contains("Do not fix grammar") == true)

        let code = CapturingModel(answer: answer)
        let codeOutput = await SmartCleaner(model: code, health: ModelHealth()).clean(
            "the report is due", options: CleanupOptions(level: .clean, isCodeContext: true, grammarContract: .minimal))
        #expect(!codeOutput.usedModel)
        #expect(code.calls.first?.instructions.contains("Do not fix grammar") == true)

        let nonEnglish = CapturingModel(answer: "Las facturas están listas.")
        let nonEnglishOutput = await SmartCleaner(model: nonEnglish, health: ModelHealth()).clean(
            "las factura está lista", options: CleanupOptions(
                level: .clean, detectedLanguage: "es", grammarContract: .minimal))
        #expect(!nonEnglishOutput.usedModel)
        #expect(nonEnglish.calls.first?.instructions.contains("Do not fix grammar") == true)
    }

    @Test("candidate remains honest when the model is unavailable")
    func unavailableModelFallback() async {
        let output = await SmartCleaner(model: NullLanguageModel()).clean(
            "the invoices is due", options: CleanupOptions(level: .clean, grammarContract: .minimal))
        #expect(!output.usedModel)
        #expect(output.rejection == "model unavailable")
        #expect(!output.text.isEmpty)
    }

    private func isAccepted(
        _ answer: String, from draft: String, profile: OutputGuard.Profile, lowConfidenceWords: Set<String>? = nil
    ) -> Bool {
        if case .accepted = OutputGuard.check(
            answer, raw: draft, draft: draft, lowConfidenceWords: lowConfidenceWords, profile: profile) { return true }
        return false
    }
}

private final class CapturingModel: LanguageModel, @unchecked Sendable {
    struct Call: Sendable {
        let instructions: String
        let prompt: String
    }
    private let answer: String
    private let callsState = Mutex<[Call]>([])

    init(answer: String) { self.answer = answer }
    var calls: [Call] { callsState.withLock { $0 } }
    var identifier: String { "local-grammar-test" }
    var availability: LanguageModelAvailability { .available }
    func supportsLanguage(_ languageCode: String) -> Bool { true }
    func prewarm(instructions: String) {}
    func prefixCache(instructions: String) async {}
    func respond(instructions: String, prompt: String, schema: GenerationSchemaSpec, options: LanguageModelOptions) async throws -> String {
        callsState.withLock { $0.append(Call(instructions: instructions, prompt: prompt)) }
        return CompactCleanupPrompt.answerJSON(answer)
    }
}
