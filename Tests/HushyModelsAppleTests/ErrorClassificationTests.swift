import Foundation
import FoundationModels
import Testing
@testable import HushyModelsApple
@testable import MurmurCore

/// The Apple adapter maps framework errors so `ModelHealth` can tell a busy system and a content
/// refusal from a slow model (DECISIONS 2026-09-27 "Apple FM errors are memory pressure").
@Suite("Apple adapter error classification")
struct ErrorClassificationTests {
    /// The exact chain the system log showed for every failure on the founder's Mac.
    static let memoryPressureError: NSError = {
        let modelManager = NSError(domain: "ModelManagerServices.ModelManagerError", code: 1013)
        let backend = NSError(
            domain: "SensitiveContentAnalysisML.CombinedTextSanitizerBackend.BackendError", code: 1,
            userInfo: [NSUnderlyingErrorKey: modelManager])
        return NSError(domain: "com.apple.SensitiveContentAnalysisML", code: 15, userInfo: [NSUnderlyingErrorKey: backend])
    }()

    @Test("SCA error 15 over ModelManagerError 1013 is a busy system, not a model error")
    func memoryPressureIsBusy() throws {
        guard #available(macOS 26.0, *) else { return }
        #expect(AppleFoundationModel.isSystemBusy(Self.memoryPressureError))
        let mapped = try #require(AppleFoundationModel.classify(Self.memoryPressureError) as? MurmurCore.LanguageModelError)
        #expect(ModelCallFailure(mapped) == .busy)
        if case .busy(let chain) = mapped {
            #expect(chain.hasSuffix("ModelManagerServices.ModelManagerError#1013"))
        }
    }

    @Test("other NSErrors pass through unchanged")
    func otherErrorsPassThrough() {
        guard #available(macOS 26.0, *) else { return }
        let other = NSError(domain: "ModelManagerServices.ModelManagerError", code: 1001)
        #expect(!AppleFoundationModel.isSystemBusy(other))
        #expect(ModelCallFailure(AppleFoundationModel.classify(other)) == .error)
        #expect(ModelCallFailure(AppleFoundationModel.classify(CancellationError())) == .cancelled)
    }

    @Test("guardrail violations and refusals are refusals; rate limits are busy")
    func generationErrors() {
        guard #available(macOS 26.0, *) else { return }
        let context = LanguageModelSession.GenerationError.Context(debugDescription: "May contain sensitive content")
        let refusal = LanguageModelSession.GenerationError.Refusal(transcriptEntries: [])
        #expect(ModelCallFailure(AppleFoundationModel.classify(
            LanguageModelSession.GenerationError.guardrailViolation(context))) == .refused)
        #expect(ModelCallFailure(AppleFoundationModel.classify(
            LanguageModelSession.GenerationError.refusal(refusal, context))) == .refused)
        #expect(ModelCallFailure(AppleFoundationModel.classify(
            LanguageModelSession.GenerationError.rateLimited(context))) == .busy)
        #expect(ModelCallFailure(AppleFoundationModel.classify(
            LanguageModelSession.GenerationError.exceededContextWindowSize(context))) == .error)
    }

    @Test("text-transform schemas (one string field) take the permissive plain-text path; others stay guided")
    func textTransformSchemas() {
        #expect(AppleFoundationModel.singleStringField(SmartCleaner.Cleaned.generationSchema) == "text")
        #expect(AppleFoundationModel.singleStringField(ModeExecutor.Transformed.generationSchema) == "text")
        #expect(AppleFoundationModel.singleStringField(SmartCleaner.RerankAnswer.generationSchema) == nil)
        #expect(AppleFoundationModel.singleStringField(GeneratedActionEnvelope.generationSchema) == nil)
    }

    @Test("plain answers lose echoed scaffolding and round-trip through the schema's field")
    func plainAnswer() throws {
        #expect(AppleFoundationModel.plainAnswer("  Output: Ship it Thursday.\n") == "Ship it Thursday.")
        #expect(AppleFoundationModel.plainAnswer("Ship it.\nTranscript: next\nOutput: next") == "Ship it.")
        #expect(AppleFoundationModel.plainAnswer("Topics:\n- Roadmap\n- Hiring") == "Topics:\n- Roadmap\n- Hiring")
        let json = try AppleFoundationModel.wrap("Say \"hi\"\n- a", field: "text")
        let decoded = try JSONDecoder().decode(SmartCleaner.Cleaned.self, from: Data(json.utf8))
        #expect(decoded.text == "Say \"hi\"\n- a")
    }
}
