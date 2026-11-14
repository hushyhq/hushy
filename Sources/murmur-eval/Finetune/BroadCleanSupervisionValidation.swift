import CryptoKit
import Foundation
import MurmurCore

/// Prospective schema 2: {schemaVersion:2,candidatesSHA256,rows:[review]}.
/// Every review requires id, candidateRowSHA256, modelObservableInputSHA256,
/// preparedTargetSHA256, independentReviewer, runtimeEvidenceOnly (boolean), decision
/// (approved|preserve|ambiguous|rejected), reviewedFamilyIDs (unique nonempty strings),
/// situationID, constructionID, decisionStratumID, authorID, sourceID (nonempty strings).
/// Review fields come exclusively from this ledger, never author candidate annotations.
/// Validation only: no examples, training files, model calls or automatic semantic approval.
enum BroadCleanSupervisionValidation {
    private struct ReviewedRow {
        let id: String
        let packet: [String: Any]
        let review: [String: Any]?
        let relationEvidenceValid: Bool
        var reasons: [String]
        var component: String?
        var split: String?
    }

    static func run(_ args: Arguments) throws {
        try write(input: FinetuneRunner.required(args, "in"),
            review: FinetuneRunner.required(args, "review-v2"), output: FinetuneRunner.required(args, "out"))
    }

    static func write(input: String, review: String, output: String) throws {
        let inputURL = try checkedInput(input)
        let reviewURL = try checkedInput(review)
        let outputURL = try BroadCleanReviewPacket.checkedOutput(output)
        let report = try validate(source: Data(contentsOf: inputURL), ledger: Data(contentsOf: reviewURL))
        let data = try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        try FileManager.default.createDirectory(at: outputURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard try BroadCleanReviewPacket.checkedOutput(output).path == outputURL.path,
              try BroadCleanReviewPacket.checkedOutput(outputURL.path).path == outputURL.path else {
            throw invalid("output parent changed during validation")
        }
        try data.write(to: outputURL, options: .withoutOverwriting)
        print("Broad supervision v2 validation report written: \(outputURL.path)")
    }

    static func validate(source: Data, ledger: Data) throws -> [String: Any] {
        let packet = try BroadCleanReviewPacket.render(source: source)
        guard let packetRows = packet["rows"] as? [[String: Any]],
              let sourceHash = packet["candidatesSHA256"] as? String,
              let object = try JSONSerialization.jsonObject(with: ledger) as? [String: Any],
              object["schemaVersion"] as? Int == 2,
              let ledgerSourceHash = object["candidatesSHA256"] as? String, !ledgerSourceHash.isEmpty,
              let reviews = object["rows"] as? [[String: Any]] else {
            throw invalid("schema 2 ledger with candidatesSHA256 and review rows required")
        }
        let sourceIDs = Set(packetRows.compactMap { $0["id"] as? String })
        var byID: [String: [String: Any]] = [:]
        for review in reviews {
            try checkReviewStructure(review)
            guard let id = review["id"] as? String, sourceIDs.contains(id), byID[id] == nil else {
                throw invalid("unknown or duplicate review id")
            }
            byID[id] = review
        }
        var rows: [ReviewedRow] = []
        for row in packetRows {
            guard let id = row["id"] as? String else { throw invalid("packet row id unavailable") }
            let review = byID[id]
            var reasons: [String] = []
            if ledgerSourceHash != sourceHash { reasons.append("stale candidate-file digest") }
            if let review {
                for key in ["candidateRowSHA256", "modelObservableInputSHA256", "preparedTargetSHA256"] {
                    if review[key] as? String != row[key] as? String { reasons.append("stale \(key)") }
                }
                if BroadCleanReviewPacket.boolean(review["runtimeEvidenceOnly"]) != true {
                    reasons.append("runtime-only evidence unavailable")
                }
                if review["independentReviewer"] as? String == review["authorID"] as? String {
                    reasons.append("reviewer is source author")
                }
                let decision = review["decision"] as? String
                if decision == "ambiguous" || decision == "rejected" { reasons.append("review decision \(decision ?? "missing")") }
                if decision == "preserve", row["preparedDraftSHA256"] as? String != row["preparedTargetSHA256"] as? String {
                    reasons.append("preserve decision requires exact prepared identity")
                }
            } else { reasons.append("missing independent review") }
            if let veto = row["hardViolation"] as? String { reasons.append("hard veto: \(veto)") }
            let digestKeys = ["candidateRowSHA256", "modelObservableInputSHA256", "preparedTargetSHA256"]
            let relationEvidenceValid: Bool
            if let review {
                relationEvidenceValid = ledgerSourceHash == sourceHash
                    && digestKeys.allSatisfy({ review[$0] as? String == row[$0] as? String })
                    && review["independentReviewer"] as? String != review["authorID"] as? String
            } else { relationEvidenceValid = false }
            rows.append(ReviewedRow(id: id, packet: row, review: review,
                relationEvidenceValid: relationEvidenceValid, reasons: reasons))
        }
        rows.sort { $0.id < $1.id }
        // Rejected targets can still supply valid independently reviewed relation evidence.
        // Dropping such a bridge would let related approved examples cross the split.
        let relationRows = rows.indices.filter { rows[$0].relationEvidenceValid }
        var parent = Array(rows.indices)
        func root(_ index: Int) -> Int {
            var current = index
            while parent[current] != current { current = parent[current] }
            return current
        }
        var firstByKey: [String: Int] = [:]
        for index in relationRows {
            guard let review = rows[index].review, let families = review["reviewedFamilyIDs"] as? [String],
                  let situation = review["situationID"] as? String,
                  let draft = rows[index].packet["preparedDraftSHA256"] as? String else {
                throw invalid("validated component fields unavailable")
            }
            let keys = families.map { "family:\($0)" } + ["situation:\(situation)", "draft:\(draft)"]
            for key in keys {
                if let first = firstByKey[key] {
                    let currentRoot = root(index); let previousRoot = root(first)
                    parent[currentRoot] = previousRoot
                } else { firstByKey[key] = index }
            }
        }
        var grouped: [Int: [Int]] = [:]
        for index in relationRows { grouped[root(index), default: []].append(index) }
        var components: [[String: Any]] = []
        var conflicts = 0
        for members in grouped.values {
            let eligibleMembers = members.filter { rows[$0].reasons.isEmpty }
            guard !eligibleMembers.isEmpty else { continue }
            // Relation-only nodes affect connectivity, never the digest or eligible row counts.
            let ids = eligibleMembers.map { rows[$0].id }.sorted()
            let componentID = try BroadCleanReviewPacket.canonicalDigest(ids)
            var targets: [String: Set<String>] = [:]
            for index in eligibleMembers {
                let row = rows[index].packet
                guard let draft = row["preparedDraftSHA256"] as? String,
                      let request = row["modelObservableInputSHA256"] as? String,
                      let target = row["preparedTargetSHA256"] as? String else { throw invalid("packet digests unavailable") }
                targets[draft + ":" + request, default: []].insert(target)
            }
            let conflicting = targets.values.contains { $0.count > 1 }
            let splitName = split(componentID)
            if conflicting { conflicts += 1 }
            for index in members { rows[index].component = componentID }
            for index in eligibleMembers {
                if conflicting { rows[index].reasons.append("contradictory targets in connected component") }
                else { rows[index].split = splitName }
            }
            components.append(["componentID": componentID, "rowIDs": ids, "rowCount": eligibleMembers.count,
                "relationEvidenceRowIDs": members.map { rows[$0].id }.sorted(),
                "relationEvidenceRowCount": members.count, "eligible": !conflicting, "split": conflicting ? NSNull() : splitName as Any,
                "targetConflict": conflicting])
        }
        components.sort { ($0["componentID"] as? String ?? "") < ($1["componentID"] as? String ?? "") }
        let finalEligible = rows.filter { $0.reasons.isEmpty }
        var rejectionCounts: [String: Int] = [:]
        for row in rows { for reason in row.reasons { rejectionCounts[reason, default: 0] += 1 } }
        let trainCount = finalEligible.filter { $0.split == "train" }.count
        let validCount = finalEligible.filter { $0.split == "valid" }.count
        var splitsByRelationship: [String: Set<String>] = [:]
        for row in finalEligible {
            guard let review = row.review, let split = row.split,
                  let families = review["reviewedFamilyIDs"] as? [String],
                  let situation = review["situationID"] as? String,
                  let draft = row.packet["preparedDraftSHA256"] as? String else {
                throw invalid("eligible split fields unavailable")
            }
            for key in families.map({ "family:\($0)" }) + ["situation:\(situation)", "draft:\(draft)"] {
                splitsByRelationship[key, default: []].insert(split)
            }
        }
        let crossSplitCollisions = splitsByRelationship.values.filter { $0.count > 1 }.count
        let rowReports: [[String: Any]] = rows.map { row in
            ["id": row.id, "candidateRowSHA256": row.packet["candidateRowSHA256"] ?? NSNull(),
             "modelObservableInputSHA256": row.packet["modelObservableInputSHA256"] ?? NSNull(),
             "preparedTargetSHA256": row.packet["preparedTargetSHA256"] ?? NSNull(),
             "eligible": row.reasons.isEmpty, "rejectionReasons": row.reasons,
             "relationMetadataEligibleForGrouping": row.relationEvidenceValid,
             "componentID": row.component.map { $0 as Any } ?? NSNull(),
             "split": row.split.map { $0 as Any } ?? NSNull(),
             "reviewProvenance": row.review.map { $0 as Any } ?? NSNull()]
        }
        let eligibleFamilies: [String] = finalEligible.flatMap { row in
            row.review?["reviewedFamilyIDs"] as? [String] ?? []
        }
        let eligibleComponents = components.filter { $0["eligible"] as? Bool == true }
        let componentSizes = eligibleComponents.compactMap { $0["rowCount"] as? Int }
        let manifest: [String: Any] = [
            "candidateRows": rows.count, "eligibleRows": finalEligible.count,
            "rejectedRows": rows.count - finalEligible.count, "validRelationEvidenceRows": relationRows.count,
            "eligibleSituationCount": unique(finalEligible, "situationID"),
            "eligibleConstructionCount": unique(finalEligible, "constructionID"),
            "eligibleDecisionStratumCount": unique(finalEligible, "decisionStratumID"),
            "eligibleAuthorCount": unique(finalEligible, "authorID"),
            "eligibleSourceCount": unique(finalEligible, "sourceID"),
            "eligibleReviewedFamilyCount": Set(eligibleFamilies).count,
            "eligibleComponentCount": eligibleComponents.count,
            "largestEligibleComponent": componentSizes.max() ?? 0,
            "targetConflictComponents": conflicts, "crossSplitCollisions": crossSplitCollisions,
            "trainRows": trainCount, "validRows": validCount,
            "nonemptySplitFeasible": trainCount > 0 && validCount > 0,
        ]
        let report: [String: Any] = [
            "schemaVersion": 2, "candidatesSHA256": sourceHash,
            "reviewLedgerSHA256": hash(ledger), "promptVersion": packet["promptVersion"] ?? NSNull(),
            "rows": rowReports, "components": components, "rejectionCounts": rejectionCounts,
            "manifest": manifest,
            "scope": "Validation only; no training export or semantic approval. Reviewer independence and runtime-only evidence are ledger attestations, not automatically verified. Nil hardViolation is not approval.",
        ]
        return report
    }

    private static func checkReviewStructure(_ review: [String: Any]) throws {
        let strings = ["id", "candidateRowSHA256", "modelObservableInputSHA256", "preparedTargetSHA256",
            "independentReviewer", "situationID", "constructionID", "decisionStratumID", "authorID", "sourceID"]
        let identifiers = ["id", "independentReviewer", "situationID", "constructionID", "decisionStratumID", "authorID", "sourceID"]
        guard strings.allSatisfy({ (review[$0] as? String)?.isEmpty == false }),
              identifiers.allSatisfy({ canonicalIdentifier(review[$0]) }),
              BroadCleanReviewPacket.boolean(review["runtimeEvidenceOnly"]) != nil,
              let decision = review["decision"] as? String, ["approved", "preserve", "ambiguous", "rejected"].contains(decision),
              let families = review["reviewedFamilyIDs"] as? [String], !families.isEmpty,
              families.allSatisfy({ canonicalIdentifier($0) }),
              Set(families).count == families.count else { throw invalid("malformed independent review fields or family identifiers") }
    }
    private static func canonicalIdentifier(_ value: Any?) -> Bool {
        guard let text = value as? String, !text.isEmpty else { return false }
        return text == text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    private static func split(_ digest: String) -> String {
        (UInt8(digest.prefix(2), radix: 16) ?? 0) % 5 == 0 ? "valid" : "train"
    }
    private static func unique(_ rows: [ReviewedRow], _ key: String) -> Int {
        Set(rows.compactMap { $0.review?[key] as? String }).count
    }
    private static func checkedInput(_ path: String) throws -> URL {
        let url = try FinetunePathGuard.checked(path)
        try SealedEvalGuard.assertTuningSafe(url, purpose: "broad supervision v2 validation input")
        return url
    }
    private static func hash(_ data: Data) -> String {
        // Preserve the exact ledger-file digest, rather than a canonical object digest.
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
    private static func invalid(_ message: String) -> NSError {
        NSError(domain: "broad-supervision-validation-v2", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }
}
