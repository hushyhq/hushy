import Foundation
import Testing
@testable import murmur_eval

@Suite("Prospective broad supervision v2 validation")
struct BroadCleanSupervisionValidationTests {
    private func candidate(_ id: String, raw: String? = nil, target: String? = nil) -> [String: Any] {
        let text = raw ?? "Synthetic lantern \(id) shines."
        return ["id": id, "raw": text, "target": target ?? text, "level": "clean",
            "voiceCommandsEnabled": false, "isCodeContext": false, "protected": [String](),
            "context": "Author-only story", "decision": "approved", "runtimeEvidenceOnly": true]
    }
    private func encode(_ object: Any) throws -> Data {
        try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes])
    }
    private func source(_ rows: [[String: Any]]) throws -> Data {
        Data(try rows.map { String(decoding: try encode($0), as: UTF8.self) }.joined(separator: "\n").utf8)
    }
    private func ledger(_ source: Data) throws -> [String: Any] {
        let packet = try BroadCleanReviewPacket.render(source: source)
        let rows = try #require(packet["rows"] as? [[String: Any]])
        let reviews: [[String: Any]] = try rows.map { row in
            let id = try #require(row["id"] as? String)
            return ["id": id, "candidateRowSHA256": row["candidateRowSHA256"] ?? NSNull(),
                "modelObservableInputSHA256": row["modelObservableInputSHA256"] ?? NSNull(),
                "preparedTargetSHA256": row["preparedTargetSHA256"] ?? NSNull(),
                "independentReviewer": "synthetic-reviewer", "runtimeEvidenceOnly": true,
                "decision": "approved", "reviewedFamilyIDs": ["family-\(id)"],
                "situationID": "situation-\(id)", "constructionID": "construction-\(id)",
                "decisionStratumID": "identity", "authorID": "author-\(id)", "sourceID": "source-\(id)"]
        }
        return ["schemaVersion": 2, "candidatesSHA256": packet["candidatesSHA256"] ?? NSNull(), "rows": reviews]
    }
    private func report(_ data: Data, _ ledger: [String: Any]) throws -> [String: Any] {
        try BroadCleanSupervisionValidation.validate(source: data, ledger: encode(ledger))
    }
    private func rows(_ report: [String: Any]) throws -> [[String: Any]] { try #require(report["rows"] as? [[String: Any]]) }

    @Test func unsupportedPositiveAndMissingReviewCannotQualify() throws {
        let data = try source([candidate("positive", raw: "A lantern glow.", target: "A lantern glows."),
                               candidate("missing"), candidate("ambiguous"), candidate("preserve-positive", raw: "A lantern glow.", target: "A lantern glows.")])
        var review = try ledger(data)
        var annotations = try #require(review["rows"] as? [[String: Any]])
        annotations.removeAll { $0["id"] as? String == "missing" }
        for index in annotations.indices {
            switch annotations[index]["id"] as? String {
            case "positive": annotations[index]["runtimeEvidenceOnly"] = false
            case "ambiguous": annotations[index]["decision"] = "ambiguous"
            case "preserve-positive": annotations[index]["decision"] = "preserve"
            default: break
            }
        }
        review["rows"] = annotations
        let result = try report(data, review)
        let output = try rows(result)
        #expect(output.allSatisfy { $0["eligible"] as? Bool == false && $0["split"] is NSNull && $0["componentID"] is NSNull })
        let rejections = try #require(result["rejectionCounts"] as? [String: Int])
        #expect(rejections["missing independent review"] == 1)
        #expect(rejections["runtime-only evidence unavailable"] == 1)
        #expect(rejections["preserve decision requires exact prepared identity"] == 1)
        #expect(rejections["review decision ambiguous"] == 1)
    }

    @Test func staleDigestsAndSameAuthorReviewerReject() throws {
        let data = try source([candidate("stale")])
        for key in ["candidateRowSHA256", "modelObservableInputSHA256", "preparedTargetSHA256"] {
            var review = try ledger(data)
            var annotations = try #require(review["rows"] as? [[String: Any]])
            annotations[0][key] = "stale"
            review["rows"] = annotations
            let output = try rows(report(data, review))
            #expect(output[0]["eligible"] as? Bool == false)
            #expect((output[0]["rejectionReasons"] as? [String])?.contains("stale \(key)") == true)
        }
        var review = try ledger(data); review["candidatesSHA256"] = "stale-source"
        #expect(try rows(report(data, review))[0]["eligible"] as? Bool == false)
        review = try ledger(data)
        var annotations = try #require(review["rows"] as? [[String: Any]])
        annotations[0]["independentReviewer"] = annotations[0]["authorID"]
        review["rows"] = annotations
        #expect(try rows(report(data, review))[0]["eligible"] as? Bool == false)
    }

    @Test func transitiveFamiliesSituationsAndExactDraftsStayTogether() throws {
        let candidates = [candidate("a"), candidate("b"), candidate("c"),
                          candidate("d", raw: "Synthetic lantern c shines."), candidate("e")]
        let data = try source(candidates)
        var review = try ledger(data)
        var annotations = try #require(review["rows"] as? [[String: Any]])
        annotations[0]["reviewedFamilyIDs"] = ["one"]
        annotations[1]["reviewedFamilyIDs"] = ["one", "two"]
        annotations[2]["reviewedFamilyIDs"] = ["two"]
        annotations[4]["situationID"] = annotations[0]["situationID"]
        review["rows"] = annotations
        let result = try report(data, review)
        let output = try rows(result)
        #expect(output.allSatisfy { $0["eligible"] as? Bool == true })
        #expect(Set(output.compactMap { $0["componentID"] as? String }).count == 1)
        #expect(Set(output.compactMap { $0["split"] as? String }).count == 1)
        let manifest = try #require(result["manifest"] as? [String: Any])
        #expect(manifest["largestEligibleComponent"] as? Int == 5)
        #expect(manifest["eligibleReviewedFamilyCount"] as? Int == 4)
        #expect(manifest["crossSplitCollisions"] as? Int == 0)
        #expect(manifest["nonemptySplitFeasible"] as? Bool == false)
    }

    @Test func rejectedReviewCanBridgeWithoutBecomingEligibleOrChangingDigest() throws {
        for mode in ["rejected", "ambiguous", "unavailable-evidence", "hard-veto"] {
            var bridge = candidate("bridge")
            if mode == "hard-veto" {
                bridge["raw"] = "A lantern glow."; bridge["target"] = "A lantern glows."
                bridge["isCodeContext"] = true
            }
            let data = try source([candidate("a"), candidate("b"), bridge])
            var review = try ledger(data)
            var annotations = try #require(review["rows"] as? [[String: Any]])
            annotations[0]["reviewedFamilyIDs"] = ["family-a"]
            annotations[1]["reviewedFamilyIDs"] = ["family-b"]
            annotations[2]["reviewedFamilyIDs"] = ["family-a", "family-b"]
            if mode == "unavailable-evidence" { annotations[2]["runtimeEvidenceOnly"] = false }
            else if mode != "hard-veto" { annotations[2]["decision"] = mode }
            review["rows"] = annotations
            let result = try report(data, review)
            let output = try rows(result)
            let eligible = output.filter { $0["eligible"] as? Bool == true }
            #expect(eligible.count == 2)
            #expect(Set(eligible.compactMap { $0["split"] as? String }).count == 1)
            let expectedDigest = try BroadCleanReviewPacket.canonicalDigest(["a", "b"])
            #expect(Set(eligible.compactMap { $0["componentID"] as? String }) == [expectedDigest])
            let rejectedBridge = try #require(output.first { $0["id"] as? String == "bridge" })
            #expect(rejectedBridge["eligible"] as? Bool == false)
            #expect(rejectedBridge["split"] is NSNull)
            #expect(rejectedBridge["relationMetadataEligibleForGrouping"] as? Bool == true)
            let components = try #require(result["components"] as? [[String: Any]])
            #expect(components.count == 1)
            #expect(components[0]["rowIDs"] as? [String] == ["a", "b"])
            #expect(components[0]["relationEvidenceRowIDs"] as? [String] == ["a", "b", "bridge"])
            let manifest = try #require(result["manifest"] as? [String: Any])
            #expect(manifest["eligibleRows"] as? Int == 2)
            #expect(manifest["largestEligibleComponent"] as? Int == 2)
            #expect(manifest["validRelationEvidenceRows"] as? Int == 3)

            for invalidMode in ["missing", "stale", "self-review"] {
                var invalidAnnotations = annotations
                if invalidMode == "missing" { invalidAnnotations.removeLast() }
                else if invalidMode == "stale" { invalidAnnotations[2]["modelObservableInputSHA256"] = "stale" }
                else { invalidAnnotations[2]["independentReviewer"] = invalidAnnotations[2]["authorID"] }
                review["rows"] = invalidAnnotations
                let invalidResult = try report(data, review)
                let invalidComponents = try #require(invalidResult["components"] as? [[String: Any]])
                #expect(invalidComponents.count == 2)
                let invalidBridge = try #require(rows(invalidResult).first { $0["id"] as? String == "bridge" })
                #expect(invalidBridge["eligible"] as? Bool == false)
                #expect(invalidBridge["relationMetadataEligibleForGrouping"] as? Bool == false)
                #expect(invalidBridge["componentID"] is NSNull)
            }
        }
    }

    @Test func contradictoryTargetsRejectEntireConnectedComponent() throws {
        let data = try source([candidate("a", raw: "A lantern glow."),
            candidate("b", raw: "A lantern glow.", target: "A lantern glows."), candidate("c")])
        var review = try ledger(data)
        var annotations = try #require(review["rows"] as? [[String: Any]])
        annotations[0]["reviewedFamilyIDs"] = ["shared"]
        annotations[2]["reviewedFamilyIDs"] = ["shared"]
        review["rows"] = annotations
        let result = try report(data, review)
        #expect(try rows(result).allSatisfy { $0["eligible"] as? Bool == false && $0["split"] is NSNull })
        let manifest = try #require(result["manifest"] as? [String: Any])
        #expect(manifest["targetConflictComponents"] as? Int == 1)
        #expect(manifest["eligibleRows"] as? Int == 0)
    }

    @Test func deterministicSplitAndNonemptyFeasibilityIgnorePermutation() throws {
        var trainID: String?; var validID: String?
        for index in 0..<100 {
            let id = "synthetic-\(index)"
            let digest = try BroadCleanReviewPacket.canonicalDigest([id])
            if (UInt8(digest.prefix(2), radix: 16) ?? 0) % 5 == 0 { validID = validID ?? id }
            else { trainID = trainID ?? id }
        }
        let candidates = [candidate(try #require(trainID)), candidate(try #require(validID))]
        let data = try source(candidates)
        var identityLedger = try ledger(data)
        var identityReviews = try #require(identityLedger["rows"] as? [[String: Any]])
        for index in identityReviews.indices { identityReviews[index]["decision"] = "preserve" }
        identityLedger["rows"] = identityReviews
        let before = try report(data, identityLedger)
        let reversed = try source(Array(candidates.reversed()))
        var reversedLedger = try ledger(reversed)
        var reversedReviews = try #require(reversedLedger["rows"] as? [[String: Any]])
        for index in reversedReviews.indices { reversedReviews[index]["decision"] = "preserve" }
        reversedLedger["rows"] = Array(reversedReviews.reversed())
        let after = try report(reversed, reversedLedger)
        #expect(try encode(before["components"] ?? []) == encode(after["components"] ?? []))
        #expect(try encode(before["rows"] ?? []) == encode(after["rows"] ?? []))
        let manifest = try #require(before["manifest"] as? [String: Any])
        #expect(manifest["nonemptySplitFeasible"] as? Bool == true)
        #expect(manifest["trainRows"] as? Int == 1)
        #expect(manifest["validRows"] as? Int == 1)
    }

    @Test func malformedReviewIdentifiersAreRefused() throws {
        let data = try source([candidate("a")])
        for (key, value) in [("id", "" as Any), ("reviewedFamilyIDs", [String]() as Any),
                             ("reviewedFamilyIDs", [""] as Any), ("reviewedFamilyIDs", ["one", "one"] as Any),
                             ("situationID", " " as Any), ("situationID", " situation-a" as Any),
                             ("independentReviewer", "synthetic-reviewer " as Any),
                             ("authorID", " author-a" as Any), ("reviewedFamilyIDs", ["one "] as Any),
                             ("runtimeEvidenceOnly", 1 as Any)] {
            var review = try ledger(data)
            var annotations = try #require(review["rows"] as? [[String: Any]])
            annotations[0][key] = value; review["rows"] = annotations
            #expect(throws: (any Error).self) { try report(data, review) }
        }
        var review = try ledger(data)
        let annotations = try #require(review["rows"] as? [[String: Any]])
        review["rows"] = annotations + annotations
        #expect(throws: (any Error).self) { try report(data, review) }
        review = try ledger(data); review["schemaVersion"] = 1
        #expect(throws: (any Error).self) { try report(data, review) }
        review = try ledger(data)
        var unknown = annotations[0]; unknown["id"] = "unknown-candidate"
        review["rows"] = [unknown]
        #expect(throws: (any Error).self) { try report(data, review) }
        for malformed in [Data(), Data("[]".utf8), Data("malformed".utf8), Data([0xff])] {
            #expect(throws: (any Error).self) {
                try BroadCleanSupervisionValidation.validate(source: data, ledger: malformed)
            }
        }
        review = try ledger(data); review["rows"] = [[String: Any]]()
        let empty = try report(data, review)
        #expect(try rows(empty).allSatisfy { $0["eligible"] as? Bool == false && $0["componentID"] is NSNull })
        #expect((empty["rejectionCounts"] as? [String: Int])?["missing independent review"] == 1)
    }

    @Test func validationReusesPathAndOverwriteGuards() throws {
        #expect(throws: (any Error).self) {
            try BroadCleanSupervisionValidation.write(input: "Evals/heldout-v2-synthetic.jsonl",
                review: "review.json", output: ".build/finetune/new.json")
        }
        let directory = URL(fileURLWithPath: ".build/finetune/validation-v2-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let input = directory.appendingPathComponent("synthetic.jsonl")
        let review = directory.appendingPathComponent("review.json")
        let output = directory.appendingPathComponent("report.json")
        let data = try source([candidate("a")]); try data.write(to: input)
        try encode(ledger(data)).write(to: review)
        #expect(throws: (any Error).self) {
            try BroadCleanSupervisionValidation.write(input: input.path, review: review.path, output: ".build/report-v2.json")
        }
        try BroadCleanSupervisionValidation.write(input: input.path, review: review.path, output: output.path)
        let original = try Data(contentsOf: output)
        #expect(throws: (any Error).self) {
            try BroadCleanSupervisionValidation.write(input: input.path, review: review.path, output: output.path)
        }
        #expect(try Data(contentsOf: output) == original)
    }
}
