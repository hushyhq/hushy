import CryptoKit
import Foundation
import MurmurCore

/// Synthetic source/candidate pairs exercise the verifier independently of its generator.
/// This is conditional stress coverage, not a population false-edit estimate or delivery gate.
enum GrammarVerifierStressRunner {
    struct Case: Decodable {
        let id: String
        let raw: String
        let draft: String
        let candidate: String
        let expectedVerdict: GeneralGrammarVerification.Verdict
        let category: String
        let rationale: String
    }

    private struct Input: Decodable {
        let schema_version: Int
        let cases: [Case]
    }

    struct Row: Encodable {
        let id: String
        let category: String
        let expectedVerdict: String
        let declaredVerdict: String?
        let accepted: Bool
        let abstained: Bool
        let grammarImproved: Bool?
        let contentAndRolesPreserved: Bool?
        let timeQuantityPolarityModalityPreserved: Bool?
        let toneAndIntentPreserved: Bool?
        let noAmbiguityIntroduced: Bool?
        let milliseconds: Double
        let modelCalls: [CleanupTraceCall]
    }

    private struct Report: Encodable {
        let schemaVersion: Int
        let interpretation: String
        let backend: String
        let modelIdentity: String
        let modelAvailable: Bool
        let assetFingerprint: String?
        let casesSHA256: String
        let verifierPromptVersion: String
        let verifierInstructionsSHA256: String
        let verifierSchemaSHA256: String
        let budgetMilliseconds: Int
        let total: Int
        let goodProposals: Int
        let acceptedGoodProposals: Int
        let rejectedGoodProposals: Int
        let badProposals: Int
        let acceptedBadProposals: Int
        let ambiguousProposals: Int
        let acceptedAmbiguousProposals: Int
        let abstentions: Int
        let p50Milliseconds: Double
        let p95Milliseconds: Double
        let cases: [Row]
    }

    static func prepare(_ data: Data) throws -> [Case] {
        let input = try JSONDecoder().decode(Input.self, from: data)
        guard input.schema_version == 1, !input.cases.isEmpty else {
            throw invalid("expected schema_version 1 and nonempty cases")
        }
        var ids: Set<String> = []
        for item in input.cases {
            let required = [item.id, item.raw, item.draft, item.candidate, item.category, item.rationale]
            guard required.allSatisfy({ !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) else {
                throw invalid("all case strings must be nonempty")
            }
            guard ids.insert(item.id).inserted else { throw invalid("duplicate case id: \(item.id)") }
        }
        return input.cases
    }

    static func run(_ args: Arguments) async throws {
        guard let inputPath = args.string("cases"), let reportPath = args.string("report") else {
            throw invalid("usage: grammar-verify --cases <dev.json> --backend none|apple|mlx --report <json>")
        }
        let backend = args.string("backend") ?? ""
        guard ["none", "apple", "mlx"].contains(backend) else {
            throw invalid("explicit backend none|apple|mlx required; fallback and remote forbidden")
        }
        guard !args.flag("budget-ms"), args.string("budget-ms") == nil || args.int("budget-ms") != nil else {
            throw invalid("--budget-ms requires a positive integer")
        }
        let budget = args.int("budget-ms") ?? 900
        guard budget > 0 else { throw invalid("--budget-ms requires a positive integer") }
        let inputURL = URL(fileURLWithPath: inputPath).resolvingSymlinksInPath().standardizedFileURL
        try SealedEvalGuard.assertTuningSafe(inputURL, purpose: "grammar verifier stress input")
        let data = try Data(contentsOf: inputURL)
        let items = try prepare(data) // Entire input validated before any inference.
        let outputURL = URL(fileURLWithPath: reportPath).resolvingSymlinksInPath().standardizedFileURL
        let reportRoot = Paths.root.appendingPathComponent("runs", isDirectory: true)
            .resolvingSymlinksInPath().standardizedFileURL.path
        guard outputURL != inputURL, outputURL.path.hasPrefix(reportRoot + "/") else {
            throw invalid("report must be inside ignored Evals/runs and must not overwrite input")
        }
        try SealedEvalGuard.assertTuningSafe(outputURL, purpose: "grammar verifier stress report")
        if let modelPath = args.string("mlx-model") {
            let modelRoot = URL(fileURLWithPath: modelPath).resolvingSymlinksInPath().standardizedFileURL.path
            guard outputURL.path != modelRoot, !outputURL.path.hasPrefix(modelRoot + "/") else {
                throw invalid("report must not overwrite model assets")
            }
        }
        let selected = LanguageModels.current
        let expectedIdentity = backend == "none" ? "none" : (backend == "apple" ? "apple-fm" : "mlx:")
        let identityMatches = backend == "mlx" ? selected.identifier.hasPrefix(expectedIdentity) : selected.identifier == expectedIdentity
        guard identityMatches else {
            throw invalid("selected model does not match explicit backend")
        }
        var rows: [Row] = []
        for item in items {
            let recorder = CleanupTraceRecorder()
            let model = RecordingLanguageModel(base: selected, recorder: recorder)
            let start = ContinuousClock.now
            let answer = await GeneralGrammarVerifier.assess(
                model: model, transcript: item.raw, rulesDraft: item.draft,
                candidate: item.candidate, budget: .milliseconds(budget))
            let elapsed = ContinuousClock.now - start
            let parts = elapsed.components
            let milliseconds = Double(parts.seconds) * 1_000 + Double(parts.attoseconds) / 1e15
            rows.append(Row(id: item.id, category: item.category,
                expectedVerdict: item.expectedVerdict.rawValue, declaredVerdict: answer?.verdict.rawValue,
                accepted: answer?.explicitlyAccepts == true, abstained: answer == nil,
                grammarImproved: answer?.grammarImproved,
                contentAndRolesPreserved: answer?.contentAndRolesPreserved,
                timeQuantityPolarityModalityPreserved: answer?.timeQuantityPolarityModalityPreserved,
                toneAndIntentPreserved: answer?.toneAndIntentPreserved,
                noAmbiguityIntroduced: answer?.noAmbiguityIntroduced,
                milliseconds: milliseconds, modelCalls: recorder.snapshot))
        }
        let good = rows.filter { $0.expectedVerdict == "accept" }
        let bad = rows.filter { $0.expectedVerdict == "reject" }
        let ambiguous = rows.filter { $0.expectedVerdict == "uncertain" }
        let report = Report(schemaVersion: 1,
            interpretation: "Conditional synthetic verifier stress; not population false-edit rate or production delivery quality.",
            backend: backend, modelIdentity: selected.identifier, modelAvailable: selected.isAvailable,
            assetFingerprint: try CleanupTraceRunner.fingerprint(modelPath: args.string("mlx-model"), backend: backend),
            casesSHA256: hash(data), verifierPromptVersion: GeneralGrammarVerifier.promptVersion,
            verifierInstructionsSHA256: hash(Data(GeneralGrammarVerifier.instructions.utf8)),
            verifierSchemaSHA256: hash(Data(GeneralGrammarVerification.generationSchema.json.utf8)),
            budgetMilliseconds: budget, total: rows.count, goodProposals: good.count,
            acceptedGoodProposals: good.filter(\.accepted).count,
            rejectedGoodProposals: good.filter { !$0.accepted }.count,
            badProposals: bad.count, acceptedBadProposals: bad.filter(\.accepted).count,
            ambiguousProposals: ambiguous.count, acceptedAmbiguousProposals: ambiguous.filter(\.accepted).count,
            abstentions: rows.filter(\.abstained).count,
            p50Milliseconds: EvalMetrics.percentile(rows.map(\.milliseconds), 0.5),
            p95Milliseconds: EvalMetrics.percentile(rows.map(\.milliseconds), 0.95), cases: rows)
        try FileManager.default.createDirectory(at: outputURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(report).write(to: outputURL, options: .atomic)
        print("Grammar verifier stress: \(rows.count) cases → \(outputURL.path)")
    }

    private static func hash(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private static func invalid(_ message: String) -> NSError {
        NSError(domain: "grammar-verify", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }
}
