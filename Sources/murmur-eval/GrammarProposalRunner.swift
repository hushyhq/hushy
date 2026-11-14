import CryptoKit
import Foundation
import MurmurCore

/// Local, diagnostic proposals only. No result from this runner is a certified delivery or paste.
enum GrammarProposalRunner {
    struct Case: Decodable {
        let id: String
        let raw: String
        let reference: String
        let alternatives: [String]
        let expectation: String
        let category: String
        let protectedTerms: [String]
        let isCodeContext: Bool
        let isCasualContext: Bool
        let voiceCommandsEnabled: Bool
        let detectedLanguage: String?
    }
    private struct Input: Decodable { let schema_version: Int; let cases: [Case] }
    struct Row: Encodable {
        let id: String
        let pass: Int
        let expectation: String
        let category: String
        let raw: String
        let preparedDraft: String
        let sourceChangedDuringPreparation: Bool
        let proposal: String?
        let diagnosticRendering: String?
        let generationFailure: String?
        let applicationFailure: String?
        let hardVeto: String?
        let mechanicallyValid: Bool
        let byteIdenticalToDraft: Bool
        let referenceMatch: Bool?
        let editCount: Int?
        let sourceBytesReplaced: Int?
        let replacementBytes: Int?
        let wholeSentenceReplacements: Int?
        let budgetMilliseconds: Int
        let milliseconds: Double
        let modelCalls: [CleanupTraceCall]
    }
    private struct Report: Encodable {
        let schemaVersion: Int
        let interpretation: String
        let arm: String
        let backend: String
        let modelIdentity: String
        let assetFingerprint: String?
        let inputSHA256: String
        let promptVersion: String
        let baseInstructionsSHA256: String
        let outputSchemaSHA256: String
        let repeats: Int
        let generationTransport: String
        let mlxPromptProfile: String?
        let mlxSpeculation: String?
        let rows: [Row]
    }

    static func prepare(_ data: Data) throws -> [Case] {
        let input = try JSONDecoder().decode(Input.self, from: data)
        guard input.schema_version == 1, !input.cases.isEmpty else { throw invalid("schema_version1 and nonempty cases required") }
        var ids: Set<String> = []
        for item in input.cases {
            guard ids.insert(item.id).inserted,
                  [item.id, item.raw, item.reference, item.category].allSatisfy({ !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }),
                  ["repair", "preserve"].contains(item.expectation),
                  item.alternatives.allSatisfy({ !$0.isEmpty }), item.protectedTerms.allSatisfy({ !$0.isEmpty }) else {
                throw invalid("unique IDs, nonempty strings, and repair|preserve expectations required")
            }
        }
        return input.cases
    }

    static func run(_ args: Arguments) async throws {
        let backend = args.string("backend") ?? ""
        let arm = args.string("arm") ?? ""
        if backend == "mlx" {
            guard args.string("mlx-prompt") == "production", args.string("mlx-speculate") == "off",
                  args.string("mlx-adapter") == nil,
                  ProcessInfo.processInfo.environment["HUSHY_MLX_ADAPTER_DIR"] == nil else {
                throw invalid("paired pilot requires --mlx-prompt production --mlx-speculate off and no adapter")
            }
        }
        guard ["mlx", "apple"].contains(backend), ["text", "edits"].contains(arm),
              let casesPath = args.string("cases"), let reportPath = args.string("report") else {
            throw invalid("grammar-proposal --cases <dev.json> --backend mlx|apple --arm text|edits --report Evals/runs/<report>.json")
        }
        let inputURL = URL(fileURLWithPath: casesPath).resolvingSymlinksInPath().standardizedFileURL
        try SealedEvalGuard.assertTuningSafe(inputURL, purpose: "grammar proposal input")
        let data = try Data(contentsOf: inputURL)
        let items = try prepare(data)
        let outputURL = URL(fileURLWithPath: reportPath).resolvingSymlinksInPath().standardizedFileURL
        let outputRoot = Paths.root.appendingPathComponent("runs").resolvingSymlinksInPath().standardizedFileURL.path
        guard outputURL != inputURL, outputURL.path.hasPrefix(outputRoot + "/") else { throw invalid("report must be inside ignored Evals/runs outside input") }
        try SealedEvalGuard.assertTuningSafe(outputURL, purpose: "grammar proposal report")
        if let modelPath = args.string("mlx-model") {
            let modelRoot = URL(fileURLWithPath: modelPath).resolvingSymlinksInPath().standardizedFileURL.path
            guard outputURL.path != modelRoot, !outputURL.path.hasPrefix(modelRoot + "/") else { throw invalid("report must not overwrite model assets") }
        }
        guard !args.flag("repeats"), args.string("repeats") == nil || args.int("repeats") != nil,
              !args.flag("budget-ms"), args.string("budget-ms") == nil || args.int("budget-ms") != nil else {
            throw invalid("numeric flags need positive integer values")
        }
        let repeats = args.int("repeats") ?? 1
        guard repeats > 0, args.int("budget-ms").map({ $0 > 0 }) ?? true else { throw invalid("numeric flags need positive integer values") }
        let model = LanguageModels.current
        guard (backend == "apple" && model.identifier == "apple-fm") || (backend == "mlx" && model.identifier.hasPrefix("mlx:")) else {
            throw invalid("selected backend must match; no fallback")
        }
        let format = GrammarEditProposalGenerator.PromptFormat.compactV5
        let instructions = arm == "edits" ? GrammarEditProposalGenerator.instructions(for: format)
            : GrammarEditProposalGenerator.wholeTextInstructions
        let schema = arm == "edits" ? GrammarEditProposal.generationSchema : WholeGrammarProposal.generationSchema
        var rows: [Row] = []
        for pass in 1...repeats {
            for item in items {
                var options = CleanupOptions(level: .clean, voiceCommandsEnabled: item.voiceCommandsEnabled,
                    detectedLanguage: item.detectedLanguage, isCodeContext: item.isCodeContext, grammarContract: .generalMinimal)
                options.isCasualContext = item.isCasualContext
                options.protectedTerms = item.protectedTerms
                let draft = TextCleaner(options: options).clean(item.raw).text
                let context = GrammarProposalContext(isCodeContext: item.isCodeContext,
                    detectedLanguage: item.detectedLanguage, protectedTerms: item.protectedTerms)
                let budget = args.int("budget-ms") ?? (TextStats.wordCount(draft) > 24 ? 3500 : (ModelHints.hasCorrectionCue(item.raw) ? 3000 : 2400))
                let recorder = CleanupTraceRecorder()
                let recording = RecordingLanguageModel(base: model, recorder: recorder)
                let start = ContinuousClock.now
                var proposed: String?
                var generationFailure: String?
                var applicationFailure: String?
                var editCount: Int?
                var sourceBytes: Int?
                var replacementBytes: Int?
                var sentenceEdits: Int?
                if arm == "edits" {
                    switch await GrammarEditProposalGenerator.generate(model: recording, preparedDraft: draft,
                        format: format, context: context, budget: .milliseconds(budget)) {
                    case .failure(let error): generationFailure = String(describing: error)
                    case .success(let proposal):
                        editCount = proposal.edits.count
                        switch GrammarEditApplicator.apply(proposal, to: draft, protectedSpans: protectedSpans(item.protectedTerms, in: draft)) {
                        case .failure(let error): applicationFailure = String(describing: error)
                        case .success(let applied):
                            proposed = applied.text
                            sourceBytes = applied.edits.reduce(0) { $0 + $1.sourceByteCount }
                            replacementBytes = applied.edits.reduce(0) { $0 + $1.replacementByteCount }
                            sentenceEdits = applied.edits.filter(\.wholeSentenceReplacement).count
                        }
                    }
                } else {
                    switch await GrammarEditProposalGenerator.generateWholeText(model: recording, preparedDraft: draft,
                        format: format, context: context, budget: .milliseconds(budget)) {
                    case .failure(let error): generationFailure = String(describing: error)
                    case .success(let proposal): proposed = proposal.text
                    }
                }
                let elapsed = ContinuousClock.now - start
                let ms = Double(elapsed.components.seconds) * 1000 + Double(elapsed.components.attoseconds) / 1e15
                let veto = proposed.flatMap { GrammarProposalDiagnostics.hardViolation(raw: item.raw, draft: draft, candidate: $0, context: context) }
                let rendering = proposed.map { TextCleaner(options: CleanupOptions(level: .verbatim,
                    voiceCommandsEnabled: false, detectedLanguage: item.detectedLanguage, isCodeContext: item.isCodeContext)).clean($0).text }
                let acceptable = [item.reference] + item.alternatives
                rows.append(Row(id: item.id, pass: pass, expectation: item.expectation, category: item.category,
                    raw: item.raw, preparedDraft: draft, sourceChangedDuringPreparation: item.raw != draft,
                    proposal: proposed, diagnosticRendering: rendering, generationFailure: generationFailure,
                    applicationFailure: applicationFailure, hardVeto: veto,
                    mechanicallyValid: proposed != nil, byteIdenticalToDraft: proposed.map { Array($0.utf8) == Array(draft.utf8) } ?? false,
                    referenceMatch: proposed.map { acceptable.contains($0) }, editCount: editCount,
                    sourceBytesReplaced: sourceBytes, replacementBytes: replacementBytes,
                    wholeSentenceReplacements: sentenceEdits, budgetMilliseconds: budget, milliseconds: ms, modelCalls: recorder.snapshot))
            }
        }
        let report = Report(schemaVersion: 1, interpretation: "Diagnostic proposals only; valid patches and hard-veto passes do not certify meaning or live delivery.",
            arm: arm, backend: backend, modelIdentity: model.identifier,
            assetFingerprint: try CleanupTraceRunner.fingerprint(modelPath: args.string("mlx-model"), backend: backend),
            inputSHA256: hash(data), promptVersion: arm == "edits" ? GrammarEditProposalGenerator.promptVersion : GrammarEditProposalGenerator.wholeTextPromptVersion,
            baseInstructionsSHA256: hash(Data(instructions.utf8)), outputSchemaSHA256: hash(Data(schema.json.utf8)), repeats: repeats,
            generationTransport: arm == "text" ? "schema-guided-greedy-v1" : "structured-edits-v1",
            mlxPromptProfile: args.string("mlx-prompt"), mlxSpeculation: args.string("mlx-speculate"), rows: rows)
        try FileManager.default.createDirectory(at: outputURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(report).write(to: outputURL, options: .atomic)
        print("Grammar proposals: \(arm), \(rows.count) rows → \(outputURL.path)")
    }

    private static func protectedSpans(_ terms: [String], in text: String) -> [NSRange] {
        let source = text as NSString
        var ranges: [NSRange] = []
        for term in terms {
            var cursor = 0
            while cursor < source.length {
                let found = source.range(of: term, options: [.literal], range: NSRange(location: cursor, length: source.length - cursor))
                if found.location == NSNotFound { break }
                ranges.append(found); cursor = found.location + found.length
            }
        }
        return ranges
    }
    private static func hash(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
    private static func invalid(_ message: String) -> NSError { NSError(domain: "grammar-proposal", code: 1, userInfo: [NSLocalizedDescriptionKey: message]) }
}
