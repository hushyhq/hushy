import CryptoKit
import Foundation
import HushyModelsMLX
import MurmurCore
import Synchronization

/// One-backend, fixed-text cleanup attribution. Model calls are observed in place, before the
/// production guards run; this runner never issues a diagnostic second model request.
enum CleanupTraceRunner {
    static func run(_ args: Arguments) async throws {
        guard let casesPath = args.string("cases"), let reportPath = args.string("report") else {
            throw usage()
        }
        let backend = args.string("backend") ?? ""
        guard ["none", "apple", "mlx"].contains(backend) else {
            throw invalid("--backend must be explicitly none, apple, or mlx; fallback and remote backends are not allowed")
        }
        if backend == "mlx", args.string("mlx-model") == nil {
            throw invalid("--backend mlx requires --mlx-model <local-directory>")
        }
        let prompt = args.string("mlx-prompt") ?? "production"
        let contract = try args.cleanGrammarContract().rawValue
        guard Arguments.cleanupPromptProfiles.contains(prompt) else {
            throw invalid("unknown --mlx-prompt profile")
        }
        guard backend == "mlx" || prompt == "production" else {
            throw invalid("compact prompt profiles apply only to --backend mlx")
        }
        if args.flag("polished-experiment") {
            throw invalid("--polished-experiment requires a value (agreement-v1)")
        }
        let polishedExperiment = try CleanupTracePromptExperiment.profile(
            args.string("polished-experiment"), backend: backend)
        let inputURL = URL(fileURLWithPath: casesPath).standardizedFileURL
        try SealedEvalGuard.assertTuningSafe(inputURL, purpose: "cleanup-trace input")
        let data = try Data(contentsOf: inputURL)
        let input = try JSONDecoder().decode(CleanupTraceCases.self, from: data)
        guard input.schema_version == 1, !input.cases.isEmpty else {
            throw invalid("cleanup-trace cases must use schema_version 1 and contain cases")
        }
        if polishedExperiment != nil, !input.cases.contains(where: { $0.level == CleanupLevel.polished.rawValue }) {
            throw invalid("--polished-experiment requires at least one polished case")
        }
        let ids = input.cases.map(\.id)
        guard Set(ids).count == ids.count,
              input.cases.allSatisfy({ !$0.id.isEmpty && !$0.raw.isEmpty && !$0.category.isEmpty }) else {
            throw invalid("case IDs must be unique and id/raw/category must be non-empty")
        }
        // Validate and convert the whole input before selecting or invoking a model. Confidence
        // entries are authored eval metadata and must correspond exactly to raw whitespace tokens.
        let preparedCases = try input.cases.map(prepare)
        let outputURL = URL(fileURLWithPath: reportPath).standardizedFileURL
        let resolvedInput = inputURL.resolvingSymlinksInPath().standardizedFileURL
        let resolvedOutput = outputURL.resolvingSymlinksInPath().standardizedFileURL
        guard resolvedOutput != resolvedInput else { throw invalid("report path must not overwrite the case file") }
        let reportRoot = Paths.root.appendingPathComponent("runs", isDirectory: true)
            .resolvingSymlinksInPath().standardizedFileURL.path
        guard resolvedOutput.path.hasPrefix(reportRoot + "/") else {
            throw invalid("--report must be inside the ignored Evals/runs directory")
        }
        try SealedEvalGuard.assertTuningSafe(resolvedOutput, purpose: "cleanup-trace report")
        if let modelPath = args.string("mlx-model") {
            let modelRoot = URL(fileURLWithPath: modelPath, isDirectory: true)
                .resolvingSymlinksInPath().standardizedFileURL.path
            guard resolvedOutput.path != modelRoot, !resolvedOutput.path.hasPrefix(modelRoot + "/") else {
                throw invalid("report path must be outside the MLX model asset directory")
            }
        }
        let gate: SmartCleaner.CleanGate
        if let rawGate = args.string("clean-gate") {
            guard let parsed = SmartCleaner.CleanGate(rawValue: rawGate) else {
                throw invalid("--clean-gate must be heuristic or always")
            }
            gate = parsed
        } else {
            gate = .always
        }
        if let rawStrategy = args.string("strategy"), SmartCleaner.Strategy(rawValue: rawStrategy) == nil {
            throw invalid("--strategy must be rules, hybrid, or model")
        }
        if let rawBudget = args.string("budget-ms"), Int(rawBudget).map({ $0 > 0 }) != true {
            throw invalid("--budget-ms must be a positive integer")
        }

        let selected = LanguageModels.current
        switch backend {
        case "none" where selected.identifier != "none":
            throw invalid("selected language model does not match --backend none")
        case "apple" where selected.identifier != "apple-fm":
            throw invalid("selected language model does not match --backend apple (fallbacks are forbidden)")
        case "mlx" where !selected.identifier.hasPrefix("mlx:"):
            throw invalid("selected language model does not match --backend mlx (fallbacks are forbidden)")
        default: break
        }
        if backend == "mlx" {
            guard let mlx = selected as? MLXLanguageModel,
                  mlx.configuration.promptProfile.rawValue == prompt else {
                throw invalid("MLX profile does not match --mlx-prompt \(prompt)")
            }
            guard mlx.configuration.adapterDirectory == nil, args.string("mlx-adapter") == nil else {
                throw invalid("cleanup-trace compares direct model weights; LoRA adapters are not accepted")
            }
        }
        let modelIdentity = selected.identifier
        let assetFingerprint = try fingerprint(modelPath: args.string("mlx-model"), backend: backend)
        var rows: [CleanupTraceRow] = []

        for prepared in preparedCases {
            let item = prepared.item
            let level = prepared.level
            let options = try args.cleanupOptions(
                level: level,
                isCodeContext: item.isCodeContext,
                isCasualContext: item.isCasualContext,
                detectedLanguage: item.detectedLanguage)
            let draft = TextCleaner(options: options).clean(item.raw).text
            let strategy: SmartCleaner.Strategy = switch level {
            case .verbatim: .rules
            case .clean: backend == "none" ? .rules : args.strategy
            case .polished: backend == "none" ? .rules : .model
            }
            let recorder = CleanupTraceRecorder()
            let recordingModel = RecordingLanguageModel(base: selected, recorder: recorder,
                compactPrompt: backend == "mlx" && prompt == "compact",
                mlxPromptProfile: backend == "mlx" ? MLXLanguageModel.PromptProfile(rawValue: prompt) : nil,
                polishedExperiment: level == .polished ? polishedExperiment : nil,
                includePromptText: prepared.wordConfidences != nil)
            let pipeline = DictationPipeline(transcriber: NullTranscriber(),
                cleaner: makeCleaner(args, model: recordingModel, gate: gate))
            let result = await pipeline.clean(item.raw, confidences: prepared.wordConfidences,
                settings: PipelineSettings(cleanupOptions: options), strategy: strategy)
            let budget = args.int("budget-ms").map { "uniform:\($0)ms" }
                ?? "production-tiered:base=2400ms,correction=3000ms,segment=3500ms,polished=4000ms"
            rows.append(CleanupTraceRow(
                id: item.id, category: item.category, level: item.level, raw: item.raw,
                rulesDraft: draft, reference: item.reference, modelCalls: recorder.snapshot, final: result.text,
                usedModel: result.usedModel, rejection: result.rejection, speedFallback: result.speedFallback,
                cleanupMs: result.timings.cleanupMs,
                cleanGate: gate.rawValue, strategy: strategy.rawValue, budgetProfile: budget,
                wordConfidences: item.wordConfidences, confidenceRegime: prepared.confidenceRegime,
                grammarContract: contract, isCodeContext: options.isCodeContext, isCasualContext: options.isCasualContext,
                detectedLanguage: options.detectedLanguage,
                exactMatch: item.reference.map { result.text == $0 },
                requiredChecks: checks(item.mustContain, in: result.text),
                forbiddenChecks: checks(item.mustNotContain, in: result.text, shouldContain: false)))
        }

        let report = CleanupTraceReport(
            schemaVersion: 2, casesSHA256: hash(data), backend: backend, modelIdentity: modelIdentity,
            mlxPrompt: backend == "mlx" ? prompt : "not-applicable",
            polishedExperiment: polishedExperiment ?? "none",
            promptProfileVersion: backend == "mlx" && prompt == "compact" ? CompactCleanupPrompt.version : prompt,
            assetFingerprint: assetFingerprint,
            mlxConfiguration: (selected as? MLXLanguageModel).map { mlx in
                "prefixCache=\(mlx.configuration.usePrefixCache),kvCacheBits=\(mlx.configuration.kvCacheBits.map(String.init) ?? "none"),speculation=\(mlx.configuration.speculation.map(String.init(describing:)) ?? "off")"
            },
            packageResolvedSHA256: try packageHash(), cases: rows,
            exactMatches: Counted(total: rows.filter { $0.exactMatch != nil }.count,
                passed: rows.filter { $0.exactMatch == true }.count),
            required: aggregate(rows.flatMap(\.requiredChecks)),
            forbidden: aggregate(rows.flatMap(\.forbiddenChecks)))
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(report).write(to: outputURL, options: .atomic)
        print("Cleanup trace: \(rows.count) cases → \(outputURL.path)")
    }

    private static func makeCleaner(_ args: Arguments, model: any LanguageModel,
                                    gate: SmartCleaner.CleanGate) -> SmartCleaner {
        guard let ms = args.int("budget-ms"), ms > 0 else {
            return SmartCleaner(cleanGate: gate, model: model)
        }
        let budget = Duration.milliseconds(ms)
        return SmartCleaner(budget: budget, correctionBudget: budget, polishedBudget: budget,
            segmentBudget: budget, cleanGate: gate, model: model)
    }

    private static func prepare(_ item: CleanupTraceCase) throws -> PreparedCleanupTraceCase {
        guard let level = CleanupLevel(rawValue: item.level) else {
            throw invalid("case \(item.id) has invalid level \(item.level)")
        }
        let (confidences, regime) = try validateConfidence(
            caseID: item.id, raw: item.raw, supplied: item.wordConfidences)
        return PreparedCleanupTraceCase(item: item, level: level, wordConfidences: confidences,
            confidenceRegime: regime)
    }

    static func validateConfidence(caseID: String, raw: String,
                                   supplied: [CleanupTraceWordConfidence]?) throws -> ([WordConfidence]?, String) {
        guard let supplied else { return (nil, "none") }
        let rawTokens = raw.split(whereSeparator: \.isWhitespace).map(String.init)
        guard supplied.count == rawTokens.count else {
            throw invalid("case \(caseID) wordConfidences must match the whitespace-delimited raw token count (expected \(rawTokens.count), got \(supplied.count))")
        }
        for (index, pair) in zip(rawTokens, supplied).enumerated() {
            let (rawToken, confidence) = pair
            guard confidence.word == rawToken else {
                throw invalid("case \(caseID) wordConfidences[\(index)].word must exactly match raw token \(index + 1)")
            }
            guard confidence.confidence.isFinite, (0...1).contains(confidence.confidence) else {
                throw invalid("case \(caseID) wordConfidences[\(index)].confidence must be finite and between 0 and 1")
            }
        }
        let converted = supplied.map { WordConfidence(word: $0.word, confidence: Float($0.confidence)) }
        let hasLow = converted.contains { $0.confidence < ConfidenceSpans.Calibration.threshold }
        return (converted, hasLow ? "low-present" : "all-high")
    }

    static func checks(_ values: [String]?, in text: String, shouldContain: Bool = true) -> [CleanupTraceCheck] {
        (values ?? []).map { value in
            CleanupTraceCheck(value: value, passed: text.localizedCaseInsensitiveContains(value) == shouldContain)
        }
    }

    private static func aggregate(_ checks: [CleanupTraceCheck]) -> Counted {
        Counted(total: checks.count, passed: checks.filter(\.passed).count)
    }

    static func fingerprint(modelPath: String?, backend: String) throws -> String? {
        guard backend == "mlx", let modelPath else { return nil }
        let root = URL(fileURLWithPath: modelPath, isDirectory: true).resolvingSymlinksInPath().standardizedFileURL
        let manager = FileManager.default
        guard manager.fileExists(atPath: root.path) else { throw invalid("MLX model directory does not exist") }
        let enumerator = manager.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey])
        var entries: [String] = []
        while let url = enumerator?.nextObject() as? URL {
            let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            guard values.isSymbolicLink != true else { throw invalid("MLX model directory contains a symbolic link") }
            guard values.isRegularFile == true else { continue }
            let handle = try FileHandle(forReadingFrom: url)
            defer { try? handle.close() }
            var hasher = SHA256()
            while let chunk = try handle.read(upToCount: 1_048_576), !chunk.isEmpty {
                hasher.update(data: chunk)
            }
            let relativePath = String(url.path.dropFirst(root.path.count + 1))
            entries.append("\(relativePath):\(hasher.finalize().map { String(format: "%02x", $0) }.joined())")
        }
        guard !entries.isEmpty else { throw invalid("MLX model directory contains no regular files") }
        return hash(entries.sorted().joined(separator: "\n"))
    }

    private static func packageHash() throws -> String? {
        let url = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("Package.resolved")
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return hash(try Data(contentsOf: url))
    }

    private static func hash(_ text: String) -> String { hash(Data(text.utf8)) }
    private static func hash(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
    private static func invalid(_ message: String) -> NSError {
        NSError(domain: "cleanup-trace", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }
    private static func usage() -> NSError {
        invalid("usage: murmur-eval cleanup-trace --cases <dev.json> --backend none|apple|mlx [--mlx-model dir] [--mlx-prompt production|compact|compact-v3|compact-v4|compact-v4-polished-bridge] --report <json>")
    }
}

private struct CleanupTraceCases: Decodable {
    let schema_version: Int
    let cases: [CleanupTraceCase]
}

private struct CleanupTraceCase: Decodable {
    let id: String
    let raw: String
    let level: String
    let reference: String?
    let category: String
    let mustContain: [String]?
    let mustNotContain: [String]?
    let wordConfidences: [CleanupTraceWordConfidence]?
    let isCodeContext: Bool?
    let isCasualContext: Bool?
    let detectedLanguage: String?
}

struct CleanupTraceWordConfidence: Codable {
    let word: String
    let confidence: Double
}

private struct PreparedCleanupTraceCase {
    let item: CleanupTraceCase
    let level: CleanupLevel
    let wordConfidences: [WordConfidence]?
    let confidenceRegime: String
}

struct CleanupTraceCheck: Encodable {
    let value: String
    let passed: Bool
}

private struct Counted: Encodable {
    let total: Int
    let passed: Int
}

private struct CleanupTraceRow: Encodable {
    let id: String
    let category: String
    let level: String
    let raw: String
    let rulesDraft: String
    let reference: String?
    let modelCalls: [CleanupTraceCall]
    let final: String
    let usedModel: Bool
    let rejection: String?
    let speedFallback: Bool
    let cleanupMs: Double
    let cleanGate: String
    let strategy: String
    let budgetProfile: String
    let wordConfidences: [CleanupTraceWordConfidence]?
    let confidenceRegime: String
    let grammarContract: String
    let isCodeContext: Bool
    let isCasualContext: Bool
    let detectedLanguage: String?
    let exactMatch: Bool?
    let requiredChecks: [CleanupTraceCheck]
    let forbiddenChecks: [CleanupTraceCheck]
}

private struct CleanupTraceReport: Encodable {
    let schemaVersion: Int
    let casesSHA256: String
    let backend: String
    let modelIdentity: String
    let mlxPrompt: String
    let polishedExperiment: String
    let promptProfileVersion: String
    let assetFingerprint: String?
    let mlxConfiguration: String?
    let packageResolvedSHA256: String?
    let cases: [CleanupTraceRow]
    let exactMatches: Counted
    let required: Counted
    let forbidden: Counted
}

struct CleanupTraceCall: Encodable, Sendable {
    let callID: String
    let complete: Bool
    let backend: String
    let instructionsSHA256: String
    let effectiveSystemSHA256: String?
    let promptSHA256: String
    let promptText: String?
    let schemaName: String
    let schemaSHA256: String
    let options: String
    let outputJSON: String?
    let error: String?
    let milliseconds: Double?
}

final class CleanupTraceRecorder: Sendable {
    private let storage = Mutex<[CleanupTraceCall]>([])
    var snapshot: [CleanupTraceCall] { storage.withLock { $0 } }
    func begin(_ call: CleanupTraceCall) { storage.withLock { $0.append(call) } }
    func finish(_ id: String, output: String?, error: String?, elapsed: Double) {
        storage.withLock { calls in
            guard let index = calls.firstIndex(where: { $0.callID == id }) else { return }
            let old = calls[index]
            calls[index] = CleanupTraceCall(callID: old.callID, complete: true, backend: old.backend,
                instructionsSHA256: old.instructionsSHA256, effectiveSystemSHA256: old.effectiveSystemSHA256,
                promptSHA256: old.promptSHA256, promptText: old.promptText,
                schemaName: old.schemaName, schemaSHA256: old.schemaSHA256,
                options: old.options, outputJSON: output, error: error, milliseconds: elapsed)
        }
    }
}

/// Records calls in place. Defaults pass every argument through unchanged; an explicit eval
/// experiment transforms recognized Polished instructions before forwarding and hashing them.
struct RecordingLanguageModel: LanguageModel {
    let base: any LanguageModel
    let recorder: CleanupTraceRecorder
    let compactPrompt: Bool
    let mlxPromptProfile: MLXLanguageModel.PromptProfile?
    let polishedExperiment: String?
    let includePromptText: Bool
    init(base: any LanguageModel, recorder: CleanupTraceRecorder, compactPrompt: Bool = false, mlxPromptProfile: MLXLanguageModel.PromptProfile? = nil,
         polishedExperiment: String? = nil, includePromptText: Bool = false) {
        self.base = base
        self.recorder = recorder
        self.compactPrompt = compactPrompt
        self.mlxPromptProfile = mlxPromptProfile
        self.polishedExperiment = polishedExperiment
        self.includePromptText = includePromptText
    }
    var identifier: String { base.identifier }
    var availability: LanguageModelAvailability { base.availability }
    var contextTokens: Int { base.contextTokens }
    func supportsLanguage(_ languageCode: String) -> Bool { base.supportsLanguage(languageCode) }
    func prewarm(instructions: String) {
        let effective = CleanupTracePromptExperiment.effectiveInstructions(instructions, profile: polishedExperiment)
        base.prewarm(instructions: effective)
    }
    func prefixCache(instructions: String) async {
        let effective = CleanupTracePromptExperiment.effectiveInstructions(instructions, profile: polishedExperiment)
        await base.prefixCache(instructions: effective)
    }

    func respond(instructions: String, prompt: String, schema: GenerationSchemaSpec,
                 options: LanguageModelOptions) async throws -> String {
        let start = ContinuousClock.now
        let id = UUID().uuidString
        let effectiveInstructions = CleanupTracePromptExperiment.effectiveInstructions(instructions, profile: polishedExperiment)
        let selectedProfile = mlxPromptProfile
            ?? (base as? MLXLanguageModel)?.configuration.promptProfile
            ?? (compactPrompt ? .compact : .production)
        let effectiveSystem = (compactPrompt || mlxPromptProfile != nil || base is MLXLanguageModel)
            ? Self.hash(MLXLanguageModel.systemText(instructions: effectiveInstructions, schema: schema, profile: selectedProfile))
            : nil
        recorder.begin(CleanupTraceCall(callID: id, complete: false, backend: identifier,
            instructionsSHA256: Self.hash(effectiveInstructions), effectiveSystemSHA256: effectiveSystem,
            promptSHA256: Self.hash(prompt), promptText: includePromptText ? prompt : nil,
            schemaName: schema.name, schemaSHA256: Self.hash(schema.json),
            options: "sampling=\(String(describing: options.sampling)),textTransform=\(options.textTransform)",
            outputJSON: nil, error: nil, milliseconds: nil))
        do {
            let output = try await base.respond(instructions: effectiveInstructions, prompt: prompt, schema: schema, options: options)
            recorder.finish(id, output: output, error: nil, elapsed: elapsed(start))
            return output
        } catch {
            recorder.finish(id, output: nil, error: String(reflecting: error), elapsed: elapsed(start))
            throw error
        }
    }

    private func elapsed(_ start: ContinuousClock.Instant) -> Double {
        let duration = start.duration(to: .now)
        return Double(duration.components.seconds) * 1_000 + Double(duration.components.attoseconds) / 1e15
    }
    private static func hash(_ value: String) -> String {
        SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}

/// An eval-only prompt suffix. It is enabled only by an explicit cleanup-trace option and only
/// for Polished cleanup instruction blocks; the shipping prompt source remains untouched.
enum CleanupTracePromptExperiment {
    static let agreementV1 = "agreement-v1"
    private static let directions = """


    Experimental copyediting directions: Correct subject-verb and pronoun agreement, use articles naturally, split run-on sentences at clear boundaries, and place hedges such as “I think” or “I guess” where they read naturally. Preserve every fact, name, number, and negation. Keep the speaker’s casual tone and the existing layout. Make only these edits when needed.
    """

    static func profile(_ rawValue: String?, backend: String) throws -> String? {
        guard let rawValue else { return nil }
        guard rawValue == agreementV1 else {
            throw invalid("unknown --polished-experiment \(rawValue) (expected agreement-v1)")
        }
        guard backend == "mlx" else {
            throw invalid("--polished-experiment agreement-v1 requires --backend mlx")
        }
        return agreementV1
    }

    static func effectiveInstructions(_ instructions: String, profile: String?) -> String {
        guard profile == agreementV1,
              let mapped = CompactCleanupPrompt.systemText(forInstructions: instructions),
              mapped.hasPrefix(CompactCleanupPrompt.systemText(level: .polished)) else { return instructions }
        return instructions + directions
    }

    private static func invalid(_ message: String) -> NSError {
        NSError(domain: "cleanup-trace", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }
}
