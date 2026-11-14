import CryptoKit
import Foundation
import HushyModelsMLX
import MurmurCore
import Testing

@testable import murmur_eval

@Suite("Cleanup trace model observation")
struct CleanupTraceTests {
    private func devRoot() throws -> URL {
        let root = Paths.root.appendingPathComponent("runs/cleanup-trace-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func writeCases(_ url: URL) throws {
        let data = Data(#"{"schema_version":1,"cases":[{"id":"one","raw":"hello","level":"clean","category":"test"}]}"#.utf8)
        try data.write(to: url)
    }

    private func writeCases(_ url: URL, cases: [[String: Any]]) throws {
        let data = try JSONSerialization.data(withJSONObject: ["schema_version": 1, "cases": cases])
        try data.write(to: url)
    }

    private func expectEarlyRejection(cases: URL, report: URL, options: [String] = [], contains fragment: String) async throws {
        var raw = ["cleanup-trace", "--cases", cases.path, "--backend", "none", "--report", report.path]
        raw.append(contentsOf: options)
        do {
            try await CleanupTraceRunner.run(Arguments(raw[...]))
            Issue.record("expected cleanup-trace to reject before model inference")
        } catch {
            #expect(error.localizedDescription.contains(fragment), "unexpected rejection: \(error.localizedDescription)")
        }
    }

    private func run(_ raw: String, answer: String, level: CleanupLevel = .polished,
                     protectedTerms: [String] = [], delay: Duration? = nil,
                     confidences: [WordConfidence]? = nil,
                     availability: LanguageModelAvailability = .available,
                     budget: Duration = .seconds(1)) async throws -> (PipelineResult, [CleanupTraceCall]) {
        let json = try JSONSerialization.data(withJSONObject: ["text": answer])
        let base = TraceStubModel(answer: String(decoding: json, as: UTF8.self), delay: delay,
            availability: availability)
        let recorder = CleanupTraceRecorder()
        let model = RecordingLanguageModel(base: base, recorder: recorder, includePromptText: confidences != nil)
        let cleaner = SmartCleaner(budget: budget, correctionBudget: budget, polishedBudget: budget,
            segmentBudget: budget, cleanGate: .always, model: model, health: ModelHealth())
        var options = CleanupOptions(level: level)
        options.protectedTerms = protectedTerms
        let pipeline = DictationPipeline(transcriber: NullTranscriber(), cleaner: cleaner)
        let result = await pipeline.clean(raw, confidences: confidences,
            settings: PipelineSettings(cleanupOptions: options), strategy: .model)
        return (result, recorder.snapshot)
    }

    @Test func decoratorForwardsCapabilitiesAndCapturesTheActualReturnedJSONWithoutPromptText() async throws {
        let base = TraceStubModel(answer: #"{"text":"Keep the exact phrase."}"#)
        let recorder = CleanupTraceRecorder()
        let model = RecordingLanguageModel(base: base, recorder: recorder)
        #expect(model.identifier == base.identifier)
        #expect(model.availability == base.availability)
        #expect(model.contextTokens == 1234)
        #expect(model.supportsLanguage("en"))
        model.prewarm(instructions: "prefill")
        await model.prefixCache(instructions: "prefix")

        let returned = try await model.respond(instructions: "private system text", prompt: "private input text",
            schema: GenerationSchemaSpec(name: "Trace", json: "{\"type\":\"object\"}"), options: .greedy)
        let call = try #require(recorder.snapshot.first)
        #expect(returned == #"{"text":"Keep the exact phrase."}"#)
        #expect(call.outputJSON == returned)
        #expect(call.error == nil)
        #expect(call.instructionsSHA256.count == 64)
        #expect(call.promptSHA256.count == 64)
        #expect(!call.instructionsSHA256.contains("private"))
        #expect(!call.promptSHA256.contains("private"))
        #expect(base.prewarmed == "prefill")
        #expect(base.prefixed == "prefix")
    }

    @Test func grammarContractRejectsUnknownOrInconsistentProfilesBeforeInference() async throws {
        let root = try devRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let cases = root.appendingPathComponent("cases.json")
        let report = root.appendingPathComponent("report.json")
        try writeCases(cases)
        try await expectEarlyRejection(cases: cases, report: report,
            options: ["--clean-grammar-contract", "unknown"], contains: "must be legacy, minimal, or general-minimal")
        try await expectEarlyRejection(cases: cases, report: report,
            options: ["--mlx-prompt", "compact-v3", "--clean-grammar-contract", "legacy"],
            contains: "applies only to mlx")
        #expect(!FileManager.default.fileExists(atPath: report.path))
    }

    @Test func polishedExperimentIsOptInValidatedAndScopedToPolishedInstructionBlocks() async throws {
        #expect(try CleanupTracePromptExperiment.profile(nil, backend: "mlx") == nil)
        #expect(try CleanupTracePromptExperiment.profile("agreement-v1", backend: "mlx") == "agreement-v1")
        #expect(throws: (any Error).self) {
            try CleanupTracePromptExperiment.profile("unknown", backend: "mlx")
        }
        #expect(throws: (any Error).self) {
            try CleanupTracePromptExperiment.profile("agreement-v1", backend: "none")
        }

        let polished = SmartCleaner.cleanupInstructions(confidenceGuided: false, grammarRepair: true)
        let clean = SmartCleaner.cleanupInstructions(confidenceGuided: false, grammarRepair: false)
        let effectivePolished = CleanupTracePromptExperiment.effectiveInstructions(polished, profile: "agreement-v1")
        #expect(effectivePolished.hasPrefix(polished))
        #expect(effectivePolished.count > polished.count)
        #expect(CleanupTracePromptExperiment.effectiveInstructions(clean, profile: "agreement-v1") == clean)
        #expect(CleanupTracePromptExperiment.effectiveInstructions(polished, profile: nil) == polished)
    }

    @Test func recorderHashesAndForwardsTheModifiedPolishedInstructionOnly() async throws {
        let base = TraceStubModel()
        let recorder = CleanupTraceRecorder()
        let model = RecordingLanguageModel(base: base, recorder: recorder, polishedExperiment: "agreement-v1")
        let polished = SmartCleaner.cleanupInstructions(confidenceGuided: false, grammarRepair: true)
        let clean = SmartCleaner.cleanupInstructions(confidenceGuided: false, grammarRepair: false)
        let schema = GenerationSchemaSpec(name: "Trace", json: "{}")
        _ = try await model.respond(instructions: polished, prompt: "p", schema: schema, options: .greedy)
        _ = try await model.respond(instructions: clean, prompt: "p", schema: schema, options: .greedy)

        #expect(base.receivedInstructions.count == 2)
        #expect(base.receivedInstructions[0] == CleanupTracePromptExperiment.effectiveInstructions(polished, profile: "agreement-v1"))
        #expect(base.receivedInstructions[1] == clean)
        let calls = recorder.snapshot
        #expect(calls[0].instructionsSHA256 == Self.hash(base.receivedInstructions[0]))
        #expect(calls[1].instructionsSHA256 == Self.hash(clean))
        #expect(calls[0].backend == base.identifier)
    }

    @Test func recorderHashesTheEffectiveCompactV3SystemFromSelectedProfile() async throws {
        var configuration = MLXLanguageModel.Configuration(directory: URL(fileURLWithPath: "/tmp/unused-mlx-config"))
        configuration.promptProfile = .compactV3
        let base = TraceStubModel()
        let recorder = CleanupTraceRecorder()
        let model = RecordingLanguageModel(
            base: base, recorder: recorder, mlxPromptProfile: configuration.promptProfile)
        let instructions = SmartCleaner.cleanupInstructions(confidenceGuided: false, localGrammar: true)
        let schema = SmartCleaner.cleanedSchema

        _ = try await model.respond(instructions: instructions, prompt: "synthetic diagnostic",
            schema: schema, options: .greedy)

        let expectedSystem = MLXLanguageModel.systemText(
            instructions: instructions, schema: schema, profile: configuration.promptProfile)
        let call = try #require(recorder.snapshot.first)
        #expect(call.effectiveSystemSHA256 == Self.hash(expectedSystem))
        #expect(call.instructionsSHA256 == Self.hash(instructions))
        #expect(base.receivedInstructions == [instructions])
    }

    @Test func decoratorRecordsThrownBackendErrorsAndRethrowsThemUnchanged() async throws {
        let expected = LanguageModelError.unavailable("offline")
        let recorder = CleanupTraceRecorder()
        let model = RecordingLanguageModel(base: TraceStubModel(error: expected), recorder: recorder)
        do {
            _ = try await model.respond(instructions: "i", prompt: "p",
                schema: GenerationSchemaSpec(name: "Trace", json: "{}"), options: .greedy)
            Issue.record("expected the backend error")
        } catch let error as LanguageModelError {
            #expect(error == expected)
        }
        let call = try #require(recorder.snapshot.first)
        #expect(call.outputJSON == nil)
        #expect(call.error?.contains("offline") == true)
    }

    @Test func unavailableBackendCapabilityPassesThroughWithoutInventingAnAnswer() async throws {
        let base = TraceStubModel(availability: .unavailable(reason: "disabled"))
        let recorder = CleanupTraceRecorder()
        let model = RecordingLanguageModel(base: base, recorder: recorder)
        #expect(model.availability == .unavailable(reason: "disabled"))
        do {
            _ = try await model.respond(instructions: "i", prompt: "p",
                schema: GenerationSchemaSpec(name: "Trace", json: "{}"), options: .greedy)
            Issue.record("expected unavailable model failure")
        } catch let error as LanguageModelError {
            #expect(error == .unavailable("disabled"))
        }
        #expect(recorder.snapshot.first?.error?.contains("disabled") == true)
    }

    @Test func timeoutNeverInventsACompletedModelAnswer() async throws {
        let recorder = CleanupTraceRecorder()
        let model = RecordingLanguageModel(base: TraceStubModel(delay: .seconds(60)), recorder: recorder)
        let result = await model.respondResult(instructions: "i", prompt: "p", generating: TraceOutput.self,
            options: .greedy, budget: .milliseconds(2))
        if case .failure(let failure) = result { #expect(failure == .timeout || failure == .cancelled) }
        else { Issue.record("expected model-call timeout") }
        if let call = recorder.snapshot.first {
            #expect(call.outputJSON == nil)
            #expect(!call.complete || call.error != nil, "an unfinished call may have no final error yet")
        }
    }

    @Test func productionPipelineUsesAndTracesAcceptedModelOutput() async throws {
        let (result, calls) = try await run("so we should ship it on friday", answer: "So we should ship it on Friday.")
        #expect(result.usedModel)
        #expect(result.text == "So we should ship it on Friday.")
        #expect(calls.count == 1)
        #expect(calls.first?.outputJSON?.contains("Friday") == true)
        #expect(calls.first?.complete == true)
        #expect(calls.first?.promptText == nil)
    }

    @Test func confidenceMetadataReachesThePipelineAndCapturesOnlyThatMarkedPrompt() async throws {
        let confidences = [
            WordConfidence(word: "The", confidence: 0.99),
            WordConfidence(word: "meting", confidence: 0.2),
            WordConfidence(word: "is", confidence: 0.98),
            WordConfidence(word: "tomorrow.", confidence: 0.97),
        ]
        let (result, calls) = try await run("The meting is tomorrow.", answer: "The meeting is tomorrow.",
            confidences: confidences)
        #expect(result.usedModel)
        #expect(result.text == "The meeting is tomorrow.")
        #expect(calls.first?.promptText?.contains("⟦meting⟧") == true)
        #expect(calls.first?.promptText?.contains("⟦The⟧") == false)

        let allHigh = confidences.map { WordConfidence(word: $0.word, confidence: 0.99) }
        let (highResult, highCalls) = try await run("The meting is tomorrow.", answer: "The meting is tomorrow.",
            confidences: allHigh)
        #expect(highResult.usedModel)
        #expect(highCalls.first?.promptText?.contains("⟦") == false)
        #expect(highCalls.first?.promptText?.contains("Transcript: The meting is tomorrow.") == true)
    }

    @Test func confidenceMetadataIsValidatedForEveryCaseBeforeTheTraceStarts() async throws {
        let root = try devRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let cases = root.appendingPathComponent("cases.json")
        let report = root.appendingPathComponent("report.json")
        let first: [String: Any] = ["id": "first", "raw": "safe input", "level": "clean", "category": "test"]

        try writeCases(cases, cases: [first, [
            "id": "bad-count", "raw": "two words", "level": "clean", "category": "test",
            "wordConfidences": [["word": "two", "confidence": 0.2]],
        ]])
        try await expectEarlyRejection(cases: cases, report: report, contains: "raw token count")
        #expect(!FileManager.default.fileExists(atPath: report.path))

        try writeCases(cases, cases: [first, [
            "id": "bad-order", "raw": "two words", "level": "clean", "category": "test",
            "wordConfidences": [["word": "words", "confidence": 0.2], ["word": "two", "confidence": 0.9]],
        ]])
        try await expectEarlyRejection(cases: cases, report: report, contains: "exactly match raw token")

        try writeCases(cases, cases: [first, [
            "id": "bad-range", "raw": "two words", "level": "clean", "category": "test",
            "wordConfidences": [["word": "two", "confidence": 1.01], ["word": "words", "confidence": 0.9]],
        ]])
        try await expectEarlyRejection(cases: cases, report: report, contains: "between 0 and 1")
    }

    @Test func confidenceInputConversionUsesTheProductionThreshold() throws {
        let input = [
            CleanupTraceWordConfidence(word: "The", confidence: 0.99),
            CleanupTraceWordConfidence(word: "meting", confidence: 0.2),
        ]
        let (converted, regime) = try CleanupTraceRunner.validateConfidence(
            caseID: "synthetic", raw: "The meting", supplied: input)
        #expect(converted?.map(\.word) == ["The", "meting"])
        #expect(regime == "low-present")

        let (high, highRegime) = try CleanupTraceRunner.validateConfidence(
            caseID: "synthetic", raw: "The meting", supplied: input.map {
                CleanupTraceWordConfidence(word: $0.word, confidence: 0.99)
            })
        #expect(high?.allSatisfy { $0.confidence >= ConfidenceSpans.Calibration.threshold } == true)
        #expect(highRegime == "all-high")
        let (none, noneRegime) = try CleanupTraceRunner.validateConfidence(
            caseID: "synthetic", raw: "The meting", supplied: nil)
        #expect(none == nil)
        #expect(noneRegime == "none")
    }

    @Test func productionPipelineTracesRawAnswerRejectedByProtectedTermGuard() async throws {
        let raw = "kubectl said the cluster is ready and we can ship it today"
        let answer = "Cube cuddle said the cluster is ready and we can ship it today."
        let (result, calls) = try await run(raw, answer: answer, protectedTerms: ["kubectl"])
        #expect(!result.usedModel)
        #expect(result.rejection == "changed protected term")
        #expect(result.text.lowercased().contains("kubectl"))
        #expect(calls.first?.outputJSON?.contains("Cube cuddle") == true)
    }

    @Test func productionPipelineTracesUnavailableModelFallback() async throws {
        let (result, calls) = try await run("so we should ship it on friday", answer: "So we should ship it on Friday.",
            availability: .unavailable(reason: "offline"))
        #expect(!result.usedModel)
        #expect(result.rejection == "model unavailable")
        #expect(calls.isEmpty, "an unavailable capability is skipped before a model request")
    }

    @Test func productionPipelineTracesTimedOutCallAndRulesFallback() async throws {
        let (result, calls) = try await run("so we should ship it on friday", answer: "So we should ship it on Friday.",
            delay: .seconds(60), budget: .milliseconds(2))
        #expect(!result.usedModel)
        #expect(result.rejection?.hasPrefix("timeout") == true || result.rejection == "cancelled")
        if result.rejection?.hasPrefix("timeout") == true { #expect(result.speedFallback) }
        if let call = calls.first {
            #expect(call.outputJSON == nil)
            #expect(!call.complete || call.error != nil, "an unfinished call may have no final error yet")
        }
    }

    @Test func forbiddenSubstringChecksRequireAbsence() throws {
        let absent = try #require(CleanupTraceRunner.checks(["secret"], in: "safe output", shouldContain: false).first)
        let present = try #require(CleanupTraceRunner.checks(["secret"], in: "secret leaked", shouldContain: false).first)
        #expect(absent.passed)
        #expect(!present.passed)
    }

    @Test func reportCannotOverwriteCasesThroughDirectOrSymlinkAlias() async throws {
        let root = try devRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let cases = root.appendingPathComponent("cases.json")
        try writeCases(cases)
        try await expectEarlyRejection(cases: cases, report: cases, contains: "must not overwrite")

        let alias = root.appendingPathComponent("case-alias.json")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: cases)
        try await expectEarlyRejection(cases: alias, report: cases, contains: "must not overwrite")
    }

    @Test func reportCannotBeWrittenInsideMLXAssets() async throws {
        let root = try devRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let cases = root.appendingPathComponent("cases.json")
        try writeCases(cases)
        let model = root.appendingPathComponent("model", isDirectory: true)
        try FileManager.default.createDirectory(at: model, withIntermediateDirectories: true)
        let report = model.appendingPathComponent("report.json")
        try await expectEarlyRejection(cases: cases, report: report,
            options: ["--mlx-model", model.path], contains: "outside the MLX model asset directory")
    }

    @Test func sealedNamedInputAndInvalidControlsRejectBeforeInference() async throws {
        let root = try devRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let sealed = root.appendingPathComponent("heldout-v2-copy.json")
        try writeCases(sealed)
        try await expectEarlyRejection(cases: sealed, report: root.appendingPathComponent("sealed-report.json"),
            contains: "sealed")

        let cases = root.appendingPathComponent("cases.json")
        try writeCases(cases)
        let report = root.appendingPathComponent("report.json")
        try await expectEarlyRejection(cases: cases, report: report, options: ["--budget-ms", "0"],
            contains: "positive integer")
        try await expectEarlyRejection(cases: cases, report: report, options: ["--clean-gate", "sometimes"],
            contains: "clean-gate")
        try await expectEarlyRejection(cases: cases, report: report, options: ["--polished-experiment", "unknown"],
            contains: "unknown --polished-experiment")
        try await expectEarlyRejection(cases: cases, report: report, options: ["--polished-experiment", "agreement-v1"],
            contains: "requires --backend mlx")
        try await expectEarlyRejection(cases: cases, report: report, options: ["--polished-experiment"],
            contains: "requires a value")
    }

    private static func hash(_ value: String) -> String {
        SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}

private final class TraceStubModel: LanguageModel, @unchecked Sendable {
    let answer: String
    let error: LanguageModelError?
    let delay: Duration?
    let availability: LanguageModelAvailability
    private(set) var prewarmed: String?
    private(set) var prefixed: String?
    private(set) var receivedInstructions: [String] = []
    let identifier = "trace-stub"
    var contextTokens: Int { 1234 }

    init(answer: String = #"{"text":"answer"}"#, error: LanguageModelError? = nil, delay: Duration? = nil,
         availability: LanguageModelAvailability = .available) {
        self.answer = answer
        self.error = error
        self.delay = delay
        self.availability = availability
    }
    func supportsLanguage(_ languageCode: String) -> Bool { languageCode == "en" }
    func prewarm(instructions: String) { prewarmed = instructions }
    func prefixCache(instructions: String) async { prefixed = instructions }
    func respond(instructions: String, prompt: String, schema: GenerationSchemaSpec,
                 options: LanguageModelOptions) async throws -> String {
        receivedInstructions.append(instructions)
        if let delay { try await Task.sleep(for: delay) }
        if let error { throw error }
        if case .unavailable(let reason) = availability { throw LanguageModelError.unavailable(reason) }
        return answer
    }
}

private struct TraceOutput: StructuredOutput {
    let text: String
    static let generationSchema = GenerationSchemaSpec(name: "Trace", json: #"{"type":"object"}"#)
}
