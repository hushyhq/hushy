import CryptoKit
import Foundation

/// Encrypts/decrypts voice-signature embeddings at rest and mediates every read/write of the
/// `voice` table, so no other type in the app ever holds a plaintext embedding or a raw `Voice`
/// row with decrypted bytes.
///
/// **Key management decision (documented per this task's instruction — see also
/// `.claude/DECISIONS.md`): reuses Hushy's existing data-encryption key (`EncryptionKeyManager`),
/// not a new dedicated Keychain key.** Rationale:
/// - `EncryptionKeyManager` already generates, stores (login Keychain,
///   `kSecAttrAccessibleWhenUnlockedThisDeviceOnly`), and rotates/recovers exactly one 256-bit
///   AES-GCM key for this app, and `EncryptedFileStore` already implements the on-disk
///   `AES.GCM` format Hushy uses for audio. A voice embedding is 256 `Float32`s (1 KB) — reusing
///   the same key and the same sealed-box format means this task adds zero new key-management
///   surface, zero new Keychain items, and zero new recovery-key story for the user to reason
///   about. The task's instruction was "the app's existing key management if usable, otherwise a
///   Keychain key" — it is usable here, so a second key was not introduced.
/// - The one caveat: `EncryptionKeyManager.loadOrCreateKey()` is not gated behind
///   `FeatureFlags.recordingEncryption` — it always returns *a* key (creating one on first use)
///   regardless of whether the user has turned on the recording-encryption toggle, since voice
///   signatures need to be encrypted unconditionally (this is Pro biometric data, not an optional
///   hardening toggle the way recording encryption is). This does mean the very first time any
///   user enrolls a voice, a DEK gets created in the Keychain even if they never turned on
///   recording encryption — that's an intentional, documented side effect, not a bug: the DEK
///   existing costs nothing (it isn't used for anything else unless recording encryption is also
///   turned on) and avoids maintaining a second key for one small table.
public struct VoiceSignatureStore: Sendable {
    private let keyManager: EncryptionKeyManager

    public init(keyManager: EncryptionKeyManager) {
        self.keyManager = keyManager
    }

    /// Encrypts a plaintext embedding (256 floats from `DiarizerManager.extractSpeakerEmbedding`)
    /// for storage in `Voice.encryptedEmbedding`.
    public func encrypt(_ embedding: [Float]) throws -> Data {
        let key = try keyManager.loadOrCreateKey()
        let plaintext = VoiceEmbeddingCodec.encode(embedding)
        guard let sealed = try? AES.GCM.seal(plaintext, using: key), let combined = sealed.combined else {
            throw EncryptionError.encryptionFailed
        }
        return combined
    }

    /// Decrypts a `Voice.encryptedEmbedding` back to plaintext floats for similarity matching.
    /// Never logs or otherwise surfaces the plaintext beyond the immediate caller's use (cosine
    /// similarity, or re-averaging for an embedding update) — see `Voice`'s own doc comment.
    public func decrypt(_ data: Data) throws -> [Float] {
        let key = try keyManager.loadOrCreateKey()
        do {
            let sealed = try AES.GCM.SealedBox(combined: data)
            let plaintext = try AES.GCM.open(sealed, using: key)
            return VoiceEmbeddingCodec.decode(plaintext)
        } catch is CryptoKitError {
            throw EncryptionError.tamperedData
        }
    }
}
