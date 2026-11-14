import CryptoKit
import Foundation
import HushyModelsMLX
import MurmurCore

/// Bounded, reviewed whole-text adaptation export. It does not authorize live delivery.
enum BroadCleanTraining {
    static func run(_ args: Arguments) throws {
        let sourceURL = try checked(try FinetuneRunner.required(args, "in"))
        let reviewURL = try checked(try FinetuneRunner.required(args, "review"))
        let independentURL = try checked(try FinetuneRunner.required(args, "independent-review"))
        let indexURLs = try FinetuneRunner.required(args, "contamination-index").split(separator: ",").map { try checked(String($0)) }
        guard !indexURLs.isEmpty else { throw invalid("development contamination indexes required") }
        let output = try FinetunePathGuard.checked(try FinetuneRunner.required(args, "out-dir"))
            .resolvingSymlinksInPath().standardizedFileURL
        let outputRoot = URL(fileURLWithPath: ".build/finetune", isDirectory: true)
            .resolvingSymlinksInPath().standardizedFileURL
        guard output.path.hasPrefix(outputRoot.path + "/"), !FileManager.default.fileExists(atPath: output.path) else {
            throw invalid("output must be a new directory beneath .build/finetune")
        }
        let source = try Data(contentsOf: sourceURL)
        let reviewData = try Data(contentsOf: reviewURL)
        let independentData = try Data(contentsOf: independentURL)
        let indexData = try indexURLs.map { try Data(contentsOf: $0) }
        let rows = try validatedRows(source: source, review: reviewData, independent: independentData)
        var index = ContaminationIndex()
        for data in indexData {
            let part = try contaminationIndex(data)
            index.grams.formUnion(part.grams); index.exact.formUnion(part.exact)
        }
        var prepared: [[String: Any]] = []
        var train: [[String: Any]] = []
        var valid: [[String: Any]] = []
        var counts: [String: Int] = [:]
        for row in rows {
            guard let id = row["id"] as? String, let raw = row["raw"] as? String,
                  let originalTarget = row["target"] as? String, let terms = row["protected"] as? [String],
                  let code = row["isCodeContext"] as? Bool, let voice = row["voiceCommandsEnabled"] as? Bool else {
                throw invalid("validated row fields unavailable")
            }
            let preparation = try prepare(raw: raw, target: originalTarget, terms: terms, code: code,
                voice: voice, language: row["detectedLanguage"] as? String)
            let draft = preparation.draft
            let target = preparation.target
            let context = preparation.context
            var rejections: [String] = []
            if let violation = preparation.hardViolation {
                rejections.append(violation)
            }
            if !grams(raw).union(grams(originalTarget)).isDisjoint(with: index.grams)
                || index.exact.contains(normalized(raw)) || index.exact.contains(normalized(originalTarget)) {
                rejections.append("evaluation exact or 8-gram overlap")
            }
            if terms.contains(where: { !raw.contains($0) || !originalTarget.contains($0) }) { rejections.append("absent protected term") }
            var record = row
            record["draft"] = draft; record["preparedTarget"] = target
            record["targetChangedByPreparation"] = originalTarget != target
            record["identityAfterPreparation"] = Array(draft.utf8) == Array(target.utf8)
            record["rejection"] = rejections.first.map { $0 as Any } ?? NSNull()
            record["rejectionReasons"] = rejections
            prepared.append(record)
            if !rejections.isEmpty {
                for reason in Set(rejections) { counts[reason, default: 0] += 1 }
                continue
            }
            let example = try trainingExample(id: id, draft: draft, target: target, context: context)
            // Stable split independent of labels/outputs. Exact drafts never cross the split.
            if Array(SHA256.hash(data: Data(draft.utf8))).first.map({ $0 % 5 == 0 }) == true { valid.append(example) }
            else { train.append(example) }
            counts[draft == target ? "identity" : "repair", default: 0] += 1
        }
        guard !train.isEmpty, !valid.isEmpty else { throw invalid("nonempty train and validation splits required") }
        try FinetuneJSONL.write(prepared, to: output.appendingPathComponent("prepared.jsonl").path)
        try FinetuneJSONL.write(train, to: output.appendingPathComponent("train.jsonl").path)
        try FinetuneJSONL.write(valid, to: output.appendingPathComponent("valid.jsonl").path)
        var inputs = [sourceURL: source, reviewURL: reviewData, independentURL: independentData]
        for (url, data) in zip(indexURLs, indexData) { inputs[url] = data }
        var inputHashes: [String: String] = [:]
        for (url, data) in inputs { inputHashes[url.path] = hash(data) }
        var outputHashes: [String: String] = [:]
        for name in ["prepared.jsonl", "train.jsonl", "valid.jsonl"] {
            outputHashes[name] = hash(try Data(contentsOf: output.appendingPathComponent(name)))
        }
        let manifest: [String: Any] = ["schemaVersion": 1,
            "promptVersion": GrammarEditProposalGenerator.wholeTextPromptVersion,
            "systemRenderer": "MLXLanguageModel.systemText production with WholeGrammarProposal schema",
            "reviewMethod": "prior independent annotations plus explicit root current-file adjudication; not human calibration",
            "inputsSHA256": inputHashes, "outputsSHA256": outputHashes, "counts": counts,
            "trainRows": train.count, "validRows": valid.count,
            "rejectedRows": rows.count - train.count - valid.count,
            "outputSchema": WholeGrammarProposal.generationSchema.json,
            "scope": "Small synthetic adaptation pilot; no semantic approval from deterministic checks; no live promotion."]
        try JSONSerialization.data(withJSONObject: manifest, options: [.prettyPrinted, .sortedKeys])
            .write(to: output.appendingPathComponent("export.json"), options: .atomic)
        print("Reviewed broad export: train \(train.count), valid \(valid.count), counts \(counts)")
    }

    /// Matches the complete production MLX system message, including the backend schema suffix.
    static func trainingExample(id: String, draft: String, target: String, context: GrammarProposalContext) throws -> [String: Any] {
        let request = try renderRequest(draft: draft, context: context)
        let answer = try JSONSerialization.data(withJSONObject: ["text": target], options: [.sortedKeys, .withoutEscapingSlashes])
        return ["id": id, "messages": [
            ["role": "system", "content": request.system],
            ["role": "user", "content": request.prompt],
            ["role": "assistant", "content": String(decoding: answer, as: UTF8.self)],
        ]]
    }

    /// Shared with review packets: changing preparation or the request renderer changes both paths.
    struct Preparation {
        let draft: String
        let target: String
        let context: GrammarProposalContext
        let hardViolation: String?
    }

    static func prepare(raw: String, target: String, terms: [String], code: Bool,
                        voice: Bool, language: String?) throws -> Preparation {
        let options = CleanupOptions(level: .clean, voiceCommandsEnabled: voice,
            detectedLanguage: language, isCodeContext: code, grammarContract: .generalMinimal)
        let draft = TextCleaner(options: options).clean(raw).text
        let preparedTarget = TextCleaner(options: options).clean(target).text
        let context = GrammarProposalContext(isCodeContext: code, detectedLanguage: language, protectedTerms: terms)
        return Preparation(draft: draft, target: preparedTarget, context: context,
            hardViolation: GrammarProposalDiagnostics.hardViolation(raw: raw, draft: draft,
                candidate: preparedTarget, context: context))
    }

    static func renderRequest(draft: String, context: GrammarProposalContext) throws
        -> (instructions: String, prompt: String, system: String) {
        let request = try GrammarEditProposalGenerator.wholeTextRequest(preparedDraft: draft, context: context)
        return (request.instructions, request.prompt,
            MLXLanguageModel.systemText(instructions: request.instructions, schema: WholeGrammarProposal.generationSchema))
    }

    static func validatedRows(source: Data, review: Data, independent: Data) throws -> [[String: Any]] {
        guard let ledger = try JSONSerialization.jsonObject(with: review) as? [String: Any],
              let prior = try JSONSerialization.jsonObject(with: independent) as? [String: Any],
              ledger["schema_version"] as? Int == 1,
              ledger["candidatesSHA256"] as? String == hash(source),
              ledger["independentReviewSHA256"] as? String == hash(independent),
              ledger["independentCandidatesSHA256"] as? String == prior["candidatesSHA256"] as? String,
              let independentIDs = ledger["independentApprovedIDs"] as? [String],
              let adjudicatedIDs = ledger["rootAdjudicatedIDs"] as? [String],
              let rootIDs = ledger["rootReviewedCurrentIDs"] as? [String],
              let rowHashes = ledger["approvedRowSHA256"] as? [String: String],
              let priorRows = prior["cases"] as? [[String: Any]] else { throw invalid("review provenance/hash missing or mismatched") }
        let priorApproved = Set(priorRows.compactMap { $0["status"] as? String == "approved" ? $0["id"] as? String : nil })
        guard Set(independentIDs) == priorApproved, !priorApproved.isEmpty,
              Set(independentIDs).isDisjoint(with: adjudicatedIDs) else { throw invalid("independent approval IDs disagree") }
        var rows: [[String: Any]] = []
        var ids: Set<String> = []
        for line in String(decoding: source, as: UTF8.self).split(separator: "\n") {
            guard let row = try JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                  let id = row["id"] as? String, ids.insert(id).inserted,
                  let raw = row["raw"] as? String, !raw.isEmpty,
                  let target = row["target"] as? String, !target.isEmpty,
                  row["level"] as? String == "clean", row["voiceCommandsEnabled"] is Bool,
                  row["isCodeContext"] is Bool, row["protected"] is [String],
                  rowHashes[id] == hash(Data(line.utf8)) else { throw invalid("invalid, unreviewed or mutated candidate row") }
            rows.append(row)
        }
        guard !ids.isEmpty, ids == Set(rootIDs), ids == Set(independentIDs).union(adjudicatedIDs), ids == Set(rowHashes.keys) else {
            throw invalid("every current row needs explicit reviewed provenance")
        }
        return rows
    }

    private struct ContaminationIndex { var grams: Set<String> = []; var exact: Set<String> = [] }
    private static func contaminationIndex(_ data: Data) throws -> ContaminationIndex {
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let cases = object["cases"] as? [[String: Any]], !cases.isEmpty else { throw invalid("nonempty development contamination index required") }
        var index = ContaminationIndex()
        for row in cases {
            for key in ["raw", "reference", "text", "target", "draft", "candidate"] {
                if let text = row[key] as? String { index.grams.formUnion(grams(text)); index.exact.insert(normalized(text)) }
            }
            for text in row["alternatives"] as? [String] ?? [] { index.grams.formUnion(grams(text)); index.exact.insert(normalized(text)) }
        }
        guard index.exact.contains(where: { !$0.isEmpty }) else { throw invalid("contamination index contains no texts") }
        return index
    }
    private static func grams(_ text: String) -> Set<String> {
        let words = normalized(text).split(separator: " ")
        guard words.count >= 8 else { return [] }
        return Set((0...(words.count - 8)).map { words[$0..<($0 + 8)].joined(separator: " ") })
    }
    private static func normalized(_ text: String) -> String {
        text.lowercased().components(separatedBy: CharacterSet.alphanumerics.inverted).filter { !$0.isEmpty }.joined(separator: " ")
    }
    private static func checked(_ path: String) throws -> URL {
        let url = try FinetunePathGuard.checked(path)
        try SealedEvalGuard.assertTuningSafe(url, purpose: "reviewed broad training input/index")
        return url
    }
    private static func hash(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
    private static func invalid(_ message: String) -> NSError { NSError(domain: "broad-clean-training", code: 1, userInfo: [NSLocalizedDescriptionKey: message]) }
}
