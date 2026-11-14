import CoreFoundation
import CryptoKit
import Foundation
import MurmurCore

/// Read-only runtime rendering for independent target review; no inference or approval.
enum BroadCleanReviewPacket {
    static func run(_ args: Arguments) throws {
        try write(input: FinetuneRunner.required(args, "in"), output: FinetuneRunner.required(args, "out"))
    }

    static func write(input: String, output: String) throws {
        let inputURL = try FinetunePathGuard.checked(input)
        try SealedEvalGuard.assertTuningSafe(inputURL, purpose: "broad review packet input")
        let outputURL = try checkedOutput(output)
        let source = try Data(contentsOf: inputURL)
        let packet = try render(source: source)
        let data = try JSONSerialization.data(withJSONObject: packet, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        try FileManager.default.createDirectory(at: outputURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        // Recheck the original path and the created parent before exclusive creation.
        guard try checkedOutput(output).path == outputURL.path,
              try checkedOutput(outputURL.path).path == outputURL.path else {
            throw invalid("output parent changed during packet preparation")
        }
        try data.write(to: outputURL, options: .withoutOverwriting)
        print("Broad review packet written: \(outputURL.path)")
    }

    static func checkedOutput(_ path: String) throws -> URL {
        let output = try prospectiveURL(FinetunePathGuard.checked(path))
        _ = try FinetunePathGuard.checked(output.path)
        try SealedEvalGuard.assertTuningSafe(output, purpose: "broad review packet output")
        let root = try prospectiveURL(URL(fileURLWithPath: ".build/finetune", isDirectory: true))
        guard output.path.hasPrefix(root.path + "/"), !FileManager.default.fileExists(atPath: output.path) else {
            throw invalid("output must be a new file beneath .build/finetune")
        }
        return output
    }

    /// Foundation may leave a symlink ancestor unresolved when the final file is absent.
    /// Resolve the nearest existing ancestor, then append the missing tail to that real path.
    private static func prospectiveURL(_ url: URL) throws -> URL {
        var ancestor = url.standardizedFileURL
        var tail: [String] = []
        while !FileManager.default.fileExists(atPath: ancestor.path) {
            if (try? FileManager.default.destinationOfSymbolicLink(atPath: ancestor.path)) != nil {
                throw invalid("dangling symlink in output path")
            }
            guard ancestor.path != "/" else { throw invalid("output ancestor unavailable") }
            tail.append(ancestor.lastPathComponent)
            ancestor.deleteLastPathComponent()
        }
        var resolved = ancestor.resolvingSymlinksInPath().standardizedFileURL
        for component in tail.reversed() { resolved.appendPathComponent(component) }
        return resolved.standardizedFileURL
    }

    static func render(source: Data) throws -> [String: Any] {
        guard let text = String(data: source, encoding: .utf8) else { throw invalid("input must be UTF-8 JSONL") }
        let sourceHash = hash(source)
        var ids: Set<String> = []
        var records: [[String: Any]] = []
        for (offset, line) in text.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
            if line.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { continue }
            guard let row = try JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                  let id = row["id"] as? String, !id.isEmpty, ids.insert(id).inserted,
                  let raw = row["raw"] as? String, !raw.isEmpty,
                  let target = row["target"] as? String, !target.isEmpty,
                  row["level"] as? String == "clean", let terms = row["protected"] as? [String],
                  let code = boolean(row["isCodeContext"]), let voice = boolean(row["voiceCommandsEnabled"]),
                  row["detectedLanguage"] == nil || row["detectedLanguage"] is NSNull || row["detectedLanguage"] is String else {
                throw invalid("invalid or duplicate candidate on line \(offset + 1)")
            }
            let prepared = try BroadCleanTraining.prepare(raw: raw, target: target, terms: terms,
                code: code, voice: voice, language: row["detectedLanguage"] as? String)
            let request = try BroadCleanTraining.renderRequest(draft: prepared.draft, context: prepared.context)
            let schema = WholeGrammarProposal.generationSchema.json
            let runtimeKeys: Set<String> = ["id", "raw", "target", "level", "protected", "isCodeContext",
                "voiceCommandsEnabled", "detectedLanguage"]
            let annotations = row.filter { !runtimeKeys.contains($0.key) }
            let observable: [String: Any] = [
                "grammarProposalContext": ["isCodeContext": code,
                    "detectedLanguage": prepared.context.detectedLanguage.map { $0 as Any } ?? NSNull(),
                    "protectedTerms": terms],
                "instructions": request.instructions, "prompt": request.prompt,
                "mlxSystemMessage": request.system,
            ]
            records.append([
                "id": id, "sourceLine": offset + 1,
                "candidatesSHA256": sourceHash, "candidateRowSHA256": hash(Data(line.utf8)),
                "originalRaw": raw, "originalTarget": target,
                "preparedDraft": prepared.draft, "preparedTarget": prepared.target,
                "preparedDraftSHA256": hash(Data(prepared.draft.utf8)),
                "preparedTargetSHA256": hash(Data(prepared.target.utf8)),
                "targetChangedByPreparation": Array(target.utf8) != Array(prepared.target.utf8),
                "hardViolation": prepared.hardViolation.map { $0 as Any } ?? NSNull(),
                "annotationMetadataNotModelInput": annotations,
                "preparationOptions": ["level": "clean", "grammarContract": "generalMinimal",
                    "voiceCommandsEnabled": voice],
                "modelObservableInput": observable,
                "modelObservableInputSHA256": try canonicalDigest(observable),
                "promptVersion": GrammarEditProposalGenerator.wholeTextPromptVersion,
                "renderedSHA256": ["instructions": hash(Data(request.instructions.utf8)),
                    "prompt": hash(Data(request.prompt.utf8)), "mlxSystemMessage": hash(Data(request.system.utf8)),
                    "outputSchema": hash(Data(schema.utf8))],
            ])
        }
        guard !records.isEmpty else { throw invalid("nonempty candidates required") }
        return ["schemaVersion": 1, "candidatesSHA256": sourceHash, "rows": records,
            "promptVersion": GrammarEditProposalGenerator.wholeTextPromptVersion,
            "outputSchema": WholeGrammarProposal.generationSchema.json,
            "scope": "Review aid only. Author context/rationales are annotations, not model input. A nil hardViolation is not semantic approval. No inference, training, export or promotion."]
    }

    /// Canonical review digest: sorted-key JSON with unescaped slashes, encoded as UTF-8.
    static func canonicalDigest(_ value: Any) throws -> String {
        hash(try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys, .withoutEscapingSlashes]))
    }

    static func boolean(_ value: Any?) -> Bool? {
        guard let value = value as? NSNumber, CFGetTypeID(value) == CFBooleanGetTypeID() else { return nil }
        return value.boolValue
    }
    private static func hash(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
    private static func invalid(_ message: String) -> NSError {
        NSError(domain: "broad-clean-review-packet", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }
}
