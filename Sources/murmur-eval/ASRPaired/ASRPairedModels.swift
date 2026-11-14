import Foundation
import MurmurCore

struct ASRPairedCases: Decodable {
    let schema_version: Int
    let clips: [ASRPairedCaseInput]
}

struct ASRPairedCaseInput: Decodable {
    let id: String
    let audio_path: String?
    let spoken_text: String?
    let reference: String
    let cleaned_reference: String?
    let group: String?
    let category: String?
    let critical_terms: [String]?
}

struct ASRPairedManifest: Codable, Sendable {
    let schema_version: Int
    let clips: [ASRPairedManifestClip]
}

struct ASRPairedManifestClip: Codable, Sendable {
    let id: String
    let audio_path: String
    let audio_sha256: String
    let reference: String
    let cleaned_reference: String?
    let group: String?
    let category: String?
    let critical_terms: [String]?
}

struct ASRPairedCandidateLine: Decodable {
    let schema_version: Int
    let clip_id: String
    let audio_sha256: String
    let text: String
    let recognition_seconds: Double
    let load_seconds: Double
    let model_id: String
    let model_revision: String
    let runtime_revision: String
    let model_asset_sha256: [String: String]?
    let runtime_source_sha256: String?
    let status: String
    let error: String?
}

enum ASRPairedValidationError: Error, LocalizedError {
    case invalid(String)
    var errorDescription: String? {
        if case .invalid(let message) = self { return message }
        return nil
    }
}

struct ASRPairedWER: Sendable {
    let errors: Int
    let referenceWords: Int
    var value: Double? { referenceWords == 0 ? nil : Double(errors) / Double(referenceWords) }
}

enum ASRPairedScoring {
    static func wer(reference: String, hypothesis: String) -> ASRPairedWER {
        let refs = WhisperEnglishNormalizer.words(reference)
        guard !refs.isEmpty else { return ASRPairedWER(errors: 0, referenceWords: 0) }
        let hyps = WhisperEnglishNormalizer.words(hypothesis)
        return ASRPairedWER(errors: EvalMetrics.editDistance(refs, hyps), referenceWords: refs.count)
    }

    static func words(_ text: String) -> [String] {
        WhisperEnglishNormalizer.words(text)
    }

    static func preserves(_ term: String, in text: String) -> Bool {
        let wanted = words(term), actual = words(text)
        guard !wanted.isEmpty else { return true }
        guard actual.count >= wanted.count else { return false }
        return (0...(actual.count - wanted.count)).contains { Array(actual[$0..<$0 + wanted.count]) == wanted }
    }

    static func validateReference(_ reference: String, category: String?, clipID: String) throws {
        guard reference.range(of: "IGNORE_TIME_SEGMENT_IN_SCORING", options: [.caseInsensitive]) == nil else {
            throw ASRPairedValidationError.invalid("clip \(clipID) uses the non-scoring IGNORE_TIME_SEGMENT_IN_SCORING sentinel")
        }
        let hasWords = !words(reference).isEmpty
        if category == "silence" {
            guard !hasWords else {
                throw ASRPairedValidationError.invalid("silence clip \(clipID) must have an empty reference")
            }
        } else {
            guard hasWords else {
                throw ASRPairedValidationError.invalid("clip \(clipID) has no scorable reference; only true silence may use an empty reference with category=silence")
            }
        }
    }

    static func isSilence(_ clip: ASRPairedManifestClip) -> Bool {
        clip.category == "silence"
    }

    static func validate(manifest: ASRPairedManifest, candidates: [ASRPairedCandidateLine], requireAssetHashes: Bool = false) throws {
        guard manifest.schema_version == 1 else { throw ASRPairedValidationError.invalid("manifest schema_version must be 1") }
        let ids = manifest.clips.map(\.id)
        guard !ids.isEmpty, Set(ids).count == ids.count, ids.allSatisfy({ !$0.isEmpty }) else {
            throw ASRPairedValidationError.invalid("manifest clip IDs must be non-empty and unique")
        }
        for clip in manifest.clips {
            try validateReference(clip.reference, category: clip.category, clipID: clip.id)
        }
        let resultIDs = candidates.map(\.clip_id)
        guard Set(resultIDs).count == resultIDs.count else { throw ASRPairedValidationError.invalid("candidate results contain duplicate clip_id") }
        guard Set(resultIDs) == Set(ids) else {
            throw ASRPairedValidationError.invalid("candidate clip membership mismatch (missing: \(Set(ids).subtracting(resultIDs).sorted()), extra: \(Set(resultIDs).subtracting(ids).sorted()))")
        }
        let hashes = Dictionary(uniqueKeysWithValues: manifest.clips.map { ($0.id, $0.audio_sha256) })
        for item in candidates {
            guard item.schema_version == 1 else { throw ASRPairedValidationError.invalid("candidate schema_version must be 1 for \(item.clip_id)") }
            guard hashes[item.clip_id] == item.audio_sha256 else { throw ASRPairedValidationError.invalid("audio_sha256 mismatch for \(item.clip_id)") }
            guard item.audio_sha256.count == 64, item.audio_sha256.allSatisfy({ $0.isHexDigit }) else { throw ASRPairedValidationError.invalid("invalid audio_sha256 for \(item.clip_id)") }
            guard item.recognition_seconds.isFinite, item.recognition_seconds >= 0,
                  item.load_seconds.isFinite, item.load_seconds >= 0 else {
                throw ASRPairedValidationError.invalid("candidate timings must be finite and non-negative for \(item.clip_id)")
            }
            guard item.status == "ok" || item.status == "error" else { throw ASRPairedValidationError.invalid("candidate status must be ok or error for \(item.clip_id)") }
            guard (item.status == "ok" && item.error == nil) || (item.status == "error" && !(item.error ?? "").isEmpty) else {
                throw ASRPairedValidationError.invalid("candidate status/error mismatch for \(item.clip_id)")
            }
            if let assets = item.model_asset_sha256 {
                guard !assets.isEmpty, assets.values.allSatisfy({ $0.count == 64 && $0.allSatisfy(\.isHexDigit) }) else {
                    throw ASRPairedValidationError.invalid("invalid model_asset_sha256 for \(item.clip_id)")
                }
            }
            if requireAssetHashes, item.model_asset_sha256?.isEmpty != false {
                throw ASRPairedValidationError.invalid("candidate model_asset_sha256 is required for \(item.clip_id)")
            }
            if let sourceHash = item.runtime_source_sha256 {
                guard sourceHash.count == 64, sourceHash.allSatisfy(\.isHexDigit) else {
                    throw ASRPairedValidationError.invalid("invalid runtime_source_sha256 for \(item.clip_id)")
                }
            }
            if requireAssetHashes, item.runtime_source_sha256?.isEmpty != false {
                throw ASRPairedValidationError.invalid("candidate runtime_source_sha256 is required for \(item.clip_id)")
            }
            guard !item.model_id.isEmpty, !item.model_revision.isEmpty, !item.runtime_revision.isEmpty else {
                throw ASRPairedValidationError.invalid("candidate model and runtime identities are required for \(item.clip_id)")
            }
        }
        let identities = Set(candidates.map {
            "\($0.model_id)@\($0.model_revision)|\($0.runtime_revision)|\(assetFingerprint($0.model_asset_sha256 ?? [:]))|\($0.runtime_source_sha256 ?? "")"
        })
        guard identities.count == 1 else { throw ASRPairedValidationError.invalid("candidate results mix model or runtime identities") }
    }

    static func assetFingerprint(_ assets: [String: String]) -> String {
        assets.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: ";")
    }

    static func candidateAssetReport(_ candidates: [ASRPairedCandidateLine]) -> [String: [String: String]] {
        var report: [String: [String: String]] = [:]
        for item in candidates {
            guard let assets = item.model_asset_sha256 else { continue }
            let identity = "\(item.model_id)@\(item.model_revision) / \(item.runtime_revision)"
            report[identity] = assets
        }
        return report
    }

    static func candidateRuntimeSourceHash(_ candidates: [ASRPairedCandidateLine]) -> String? {
        candidates.first?.runtime_source_sha256
    }
}
