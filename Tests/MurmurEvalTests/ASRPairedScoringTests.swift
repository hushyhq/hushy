import Foundation
import Testing

@testable import murmur_eval

@Suite("Paired ASR eval validation and scoring")
struct ASRPairedScoringTests {
    private let hash = String(repeating: "a", count: 64)

    private func clip(_ id: String = "one", reference: String = "one two", cleaned: String? = nil, category: String? = nil) -> ASRPairedManifestClip {
        ASRPairedManifestClip(id: id, audio_path: "/tmp/\(id).wav", audio_sha256: hash,
            reference: reference, cleaned_reference: cleaned, group: nil, category: category, critical_terms: nil)
    }

    private func result(_ id: String = "one", hash: String? = nil, status: String = "ok", error: String? = nil,
                        text: String = "one two", runtimeHash: String? = String(repeating: "e", count: 64)) -> ASRPairedCandidateLine {
        ASRPairedCandidateLine(schema_version: 1, clip_id: id, audio_sha256: hash ?? self.hash, text: text,
            recognition_seconds: 0.1, load_seconds: 0.2, model_id: "qwen", model_revision: "rev1",
            runtime_revision: "mlx1", model_asset_sha256: ["weights": String(repeating: "c", count: 64)], runtime_source_sha256: runtimeHash, status: status, error: error)
    }

    @Test func rejectsManifestVersionAndEmptyMembership() throws {
        #expect(throws: ASRPairedValidationError.self) {
            try ASRPairedScoring.validate(manifest: ASRPairedManifest(schema_version: 2, clips: [clip()]), candidates: [result()])
        }
        #expect(throws: ASRPairedValidationError.self) {
            try ASRPairedScoring.validate(manifest: ASRPairedManifest(schema_version: 1, clips: []), candidates: [])
        }
    }

    @Test func decodesNativeQwenRuntimeSourceProvenanceShape() throws {
        let sourceDigest = String(repeating: "e", count: 64)
        let sourceFileDigest = String(repeating: "f", count: 64)
        let json = """
        {"schema_version":1,"clip_id":"one","audio_sha256":"\(hash)","text":"one two","recognition_seconds":0.1,"load_seconds":0.2,"model_id":"mlx-community/Qwen3-ASR-0.6B-4bit","model_revision":"313d850181767edf09f00a9c289becca70e58cd0","runtime_revision":"8d86630ade569728aaea3dc1a29fc44e2efa719b","runtime_source_sha256":"\(sourceDigest)","runtime_source_files_sha256":{"Sources/Qwen3ASR.swift":"\(sourceFileDigest)"},"model_asset_sha256":{"model.safetensors":"\(sourceFileDigest)"},"status":"ok"}
        """
        let decoded = try JSONDecoder().decode(ASRPairedCandidateLine.self, from: Data(json.utf8))
        #expect(decoded.runtime_source_sha256 == sourceDigest)
        #expect(decoded.model_revision == "313d850181767edf09f00a9c289becca70e58cd0")
    }

    @Test func rejectsNonScoringAndUnlabeledEmptyReferencesButAllowsExplicitSilence() throws {
        let marker = clip(reference: "IGNORE_TIME_SEGMENT_IN_SCORING", category: "accent")
        #expect(throws: ASRPairedValidationError.self) {
            try ASRPairedScoring.validate(manifest: ASRPairedManifest(schema_version: 1, clips: [marker]), candidates: [result()])
        }
        let empty = clip(reference: "  ", category: "accent")
        #expect(throws: ASRPairedValidationError.self) {
            try ASRPairedScoring.validate(manifest: ASRPairedManifest(schema_version: 1, clips: [empty]), candidates: [result()])
        }
        let unlabeledEmpty = clip(reference: "")
        #expect(throws: ASRPairedValidationError.self) {
            try ASRPairedScoring.validate(manifest: ASRPairedManifest(schema_version: 1, clips: [unlabeledEmpty]), candidates: [result()])
        }
        let silence = clip(reference: "", category: "silence")
        try ASRPairedScoring.validate(manifest: ASRPairedManifest(schema_version: 1, clips: [silence]), candidates: [result(text: "hallucinated words")])
        #expect(ASRPairedScoring.isSilence(silence))
        #expect(!ASRPairedScoring.isSilence(marker))
    }

    @Test func rejectsMissingDuplicateAndHashMismatch() throws {
        let manifest = ASRPairedManifest(schema_version: 1, clips: [clip(), clip("two")])
        #expect(throws: ASRPairedValidationError.self) { try ASRPairedScoring.validate(manifest: manifest, candidates: [result()]) }
        #expect(throws: ASRPairedValidationError.self) { try ASRPairedScoring.validate(manifest: manifest, candidates: [result(), result()]) }
        #expect(throws: ASRPairedValidationError.self) { try ASRPairedScoring.validate(manifest: ASRPairedManifest(schema_version: 1, clips: [clip()]), candidates: [result(hash: String(repeating: "b", count: 64))]) }
    }

    @Test func validatesErrorRowsAndTimingAndSingleCandidateIdentity() throws {
        let manifest = ASRPairedManifest(schema_version: 1, clips: [clip()])
        #expect(throws: ASRPairedValidationError.self) { try ASRPairedScoring.validate(manifest: manifest, candidates: [result(status: "error")]) }
        let badTime = ASRPairedCandidateLine(schema_version: 1, clip_id: "one", audio_sha256: hash, text: "",
            recognition_seconds: .infinity, load_seconds: 0, model_id: "qwen", model_revision: "rev1", runtime_revision: "mlx1", model_asset_sha256: ["weights": String(repeating: "c", count: 64)], runtime_source_sha256: String(repeating: "e", count: 64), status: "error", error: "inference failed")
        #expect(throws: ASRPairedValidationError.self) { try ASRPairedScoring.validate(manifest: manifest, candidates: [badTime]) }
        let mixed = ASRPairedManifest(schema_version: 1, clips: [clip(), clip("two")])
        var other = result("two"); other = ASRPairedCandidateLine(schema_version: 1, clip_id: other.clip_id, audio_sha256: hash, text: other.text, recognition_seconds: 0, load_seconds: 0, model_id: "other", model_revision: "rev2", runtime_revision: "mlx1", model_asset_sha256: ["weights": String(repeating: "d", count: 64)], runtime_source_sha256: String(repeating: "f", count: 64), status: "ok", error: nil)
        #expect(throws: ASRPairedValidationError.self) { try ASRPairedScoring.validate(manifest: mixed, candidates: [result(), other]) }
    }

    @Test func repeatedRowsForOneModelBuildOneStableAssetEntry() throws {
        let rows = [result(), result("two")]
        let reportAssets = ASRPairedScoring.candidateAssetReport(rows)
        #expect(reportAssets.count == 1)
        #expect(reportAssets["qwen@rev1 / mlx1"] == ["weights": String(repeating: "c", count: 64)])
        #expect(ASRPairedScoring.assetFingerprint(["z": "2", "a": "1"]) == "a=1;z=2")
        try ASRPairedScoring.validate(manifest: ASRPairedManifest(schema_version: 1, clips: [clip(), clip("two")]), candidates: rows, requireAssetHashes: true)
    }

    @Test func compareResolvesRelativeManifestAudioAgainstManifestDirectory() {
        let audio = ASRPairedRunner.resolveAudioPath("audio/one.wav", manifestPath: "/tmp/run/manifest.json")
        #expect(audio.path == "/tmp/run/audio/one.wav")
        #expect(ASRPairedRunner.resolveAudioPath("/data/one.wav", manifestPath: "/tmp/run/manifest.json").path == "/data/one.wav")
    }

    @Test func rejectsMixedRuntimeSourceFingerprintsAndProtectedReportPaths() throws {
        let manifest = ASRPairedManifest(schema_version: 1, clips: [clip(), clip("two")])
        #expect(throws: ASRPairedValidationError.self) {
            try ASRPairedScoring.validate(manifest: manifest, candidates: [result(), result("two", runtimeHash: String(repeating: "f", count: 64))], requireAssetHashes: true)
        }
        #expect(throws: ASRPairedValidationError.self) {
            try ASRPairedRunner.assertSafeReportTarget(URL(fileURLWithPath: "/tmp/run/input.json"),
                inputFiles: [URL(fileURLWithPath: "/tmp/run/input.json")], protectedDirectory: nil)
        }
        #expect(throws: ASRPairedValidationError.self) {
            try ASRPairedRunner.assertSafeReportTarget(URL(fileURLWithPath: "/models/local/report.json"),
                inputFiles: [], protectedDirectory: URL(fileURLWithPath: "/models/local", isDirectory: true))
        }
    }

    @Test func blankSilenceHasNoWerAndHallucinationIsSeparate() {
        let silence = ASRPairedScoring.wer(reference: "", hypothesis: "an invented sentence")
        #expect(silence.referenceWords == 0)
        #expect(silence.value == nil)
        #expect(ASRPairedScoring.preserves("not", in: "do not remove it"))
        #expect(!ASRPairedScoring.preserves("not", in: "do remove it"))
    }

    @Test func corpusWerIsWeightedByReferenceWordsAndMissingCleanGoldStaysAbsent() throws {
        // Use ordinary lexical tokens here: WhisperEnglishNormalizer intentionally folds
        // spoken digit sequences into serial-number tokens, so number words are not 4 tokens.
        let long = ASRPairedScoring.wer(reference: "apple pear peach plum", hypothesis: "apple pear peach")
        let short = ASRPairedScoring.wer(reference: "yes", hypothesis: "no")
        let weighted = Double(long.errors + short.errors) / Double(long.referenceWords + short.referenceWords)
        #expect(weighted == 0.4)
        #expect(clip(cleaned: nil).cleaned_reference == nil)
        #expect(clip(cleaned: "").cleaned_reference == "")
    }
}
