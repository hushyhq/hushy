import Foundation
import GRDB

/// A named, persistent voice signature: a user-named identity backed by an averaged speaker
/// embedding, used to recognize the same physical person again across notes. Pro-gated
/// (`ProFeature.voiceSignatures`) — see docs/research/speaker-labeling.md §2.6 for the product
/// framing and privacy rationale, and `.claude/DECISIONS.md` for the biometric-consent/deletion
/// decision this table's design follows.
///
/// The embedding is a 256-d L2-normalized `Float` vector (FluidAudio's `DiarizerManager
/// .extractSpeakerEmbedding` output), stored **encrypted at rest** — see
/// `VoiceEmbeddingCodec`/`VoiceSignatureStore` for the encryption boundary. `Voice` itself only
/// ever holds the encrypted bytes (`encryptedEmbedding`) plus the non-secret bookkeeping
/// (`name`, `sampleCount`, timestamps); nothing in this type ever holds a decrypted embedding, so
/// a stray `Voice` value in a log or crash report can't leak biometric material.
public struct Voice: Codable, Sendable, Equatable, Identifiable, Hashable {
    public var id: Int64?
    /// User-given name (e.g. "Dana", "Me"). Never inferred/auto-set beyond the one reserved "You"
    /// row created at enrollment — see `isYou`.
    public var name: String
    /// True only for the single reserved row created by enrolling the user's own voice from Tune
    /// (Voice Lab) recordings. At most one row may have this set — enforced by `VoiceStore`, not
    /// a DB constraint, since SQLite has no partial-unique-on-boolean short of a filtered index,
    /// which GRDB's schema builder here does not need for a single-row invariant this small.
    public var isYou: Bool
    /// AES-GCM ciphertext of the little-endian `Float32` embedding vector (see
    /// `VoiceEmbeddingCodec`), produced by `EncryptedFileStore`'s same on-disk format/key
    /// management so this table has exactly one encryption story in the app, not two.
    public var encryptedEmbedding: Data
    /// How many enrollment/update samples were averaged into `encryptedEmbedding` so far —
    /// informational (surfaced in the Voices list) and used to weight a future re-average.
    public var sampleCount: Int
    public var createdAt: Date
    public var updatedAt: Date

    public init(
        id: Int64? = nil, name: String, isYou: Bool = false, encryptedEmbedding: Data,
        sampleCount: Int = 1, createdAt: Date = Date(), updatedAt: Date = Date()
    ) {
        self.id = id
        self.name = name
        self.isYou = isYou
        self.encryptedEmbedding = encryptedEmbedding
        self.sampleCount = sampleCount
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

extension Voice: FetchableRecord, MutablePersistableRecord {
    public static let databaseTableName = "voice"

    public mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }
}

/// Encodes/decodes a speaker embedding (`[Float]`, 256-d from FluidAudio) as raw little-endian
/// bytes, the plaintext `VoiceSignatureStore` encrypts/decrypts with `EncryptedFileStore`'s AES-GCM
/// primitives (reusing the app's one AES-GCM implementation rather than a second one for this
/// table — see that type's file-format doc comment).
public enum VoiceEmbeddingCodec {
    public static func encode(_ embedding: [Float]) -> Data {
        var data = Data(capacity: embedding.count * MemoryLayout<Float>.size)
        for value in embedding {
            withUnsafeBytes(of: value.bitPattern.littleEndian) { data.append(contentsOf: $0) }
        }
        return data
    }

    public static func decode(_ data: Data) -> [Float] {
        let stride = MemoryLayout<UInt32>.size
        guard data.count % stride == 0 else { return [] }
        var result: [Float] = []
        result.reserveCapacity(data.count / stride)
        var index = data.startIndex
        while index < data.endIndex {
            let end = data.index(index, offsetBy: stride)
            let bits = data[index..<end].withUnsafeBytes { $0.load(as: UInt32.self) }
            result.append(Float(bitPattern: UInt32(littleEndian: bits)))
            index = end
        }
        return result
    }
}

/// Cosine similarity between two embeddings, per docs/research/speaker-labeling.md's matching
/// design. Returns 0 for a degenerate (empty, mismatched-length, or zero-norm) pair rather than
/// throwing — matching is inherently best-effort and a malformed embedding should read as "no
/// match," never crash a diarization pass.
public enum VoiceSimilarity {
    public static func cosine(_ a: [Float], _ b: [Float]) -> Float {
        guard a.count == b.count, !a.isEmpty else { return 0 }
        var dot: Float = 0
        var normA: Float = 0
        var normB: Float = 0
        for i in 0..<a.count {
            dot += a[i] * b[i]
            normA += a[i] * a[i]
            normB += b[i] * b[i]
        }
        let denom = normA.squareRoot() * normB.squareRoot()
        guard denom > 0 else { return 0 }
        return dot / denom
    }

    /// Averages two embeddings weighted by how many samples each already represents, then
    /// re-normalizes to unit length (matching FluidAudio's own L2-normalized embedding
    /// convention) — used when enrolling an additional sample into an existing `Voice`.
    public static func weightedAverage(existing: [Float], existingCount: Int, new: [Float]) -> [Float] {
        guard existing.count == new.count, !existing.isEmpty else { return new }
        let totalWeight = Float(existingCount + 1)
        var combined = [Float](repeating: 0, count: existing.count)
        for i in 0..<existing.count {
            combined[i] = (existing[i] * Float(existingCount) + new[i]) / totalWeight
        }
        let norm = combined.reduce(Float(0)) { $0 + $1 * $1 }.squareRoot()
        guard norm > 0 else { return combined }
        return combined.map { $0 / norm }
    }
}
