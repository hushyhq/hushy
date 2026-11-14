import CryptoKit
import Foundation
import Testing
@testable import MurmurCore

/// Covers `VoiceSignatureStore`'s encryption round-trip (the "encryption round-trip" test this
/// task requires) and `VoiceEmbeddingCodec`'s byte-level encoding, using `InMemoryKeyStore` so no
/// real Keychain is touched.
@Suite("VoiceSignatureStore")
struct VoiceSignatureStoreTests {
    private func makeStore() -> VoiceSignatureStore {
        VoiceSignatureStore(keyManager: EncryptionKeyManager(keyStore: InMemoryKeyStore()))
    }

    @Test("encrypt then decrypt round-trips an embedding exactly")
    func roundTripsEmbedding() throws {
        let store = makeStore()
        let embedding: [Float] = (0..<256).map { Float($0) / 256 - 0.5 }
        let encrypted = try store.encrypt(embedding)
        let decrypted = try store.decrypt(encrypted)
        #expect(decrypted == embedding)
    }

    @Test("encrypted bytes never contain the plaintext embedding's byte pattern")
    func encryptedBytesDoNotLeakPlaintext() throws {
        let store = makeStore()
        // A distinctive, easy-to-spot-if-leaked value.
        let embedding: [Float] = Array(repeating: 0.123456, count: 256)
        let plaintext = VoiceEmbeddingCodec.encode(embedding)
        let encrypted = try store.encrypt(embedding)
        #expect(!encrypted.contains(subsequence: plaintext))
    }

    @Test("decrypting tampered ciphertext throws tamperedData, never returns wrong floats")
    func tamperedCiphertextThrows() throws {
        let store = makeStore()
        var encrypted = try store.encrypt([Float](repeating: 1, count: 256))
        // Flip a byte well inside the ciphertext (past the nonce) to simulate corruption/tampering.
        let flipIndex = encrypted.index(encrypted.startIndex, offsetBy: 20)
        encrypted[flipIndex] ^= 0xFF
        #expect(throws: EncryptionError.self) { try store.decrypt(encrypted) }
    }

    @Test("two stores backed by different keys cannot decrypt each other's ciphertext")
    func differentKeysCannotCrossDecrypt() throws {
        let storeA = makeStore()
        let storeB = makeStore()
        let encrypted = try storeA.encrypt([Float](repeating: 0.5, count: 256))
        #expect(throws: EncryptionError.self) { try storeB.decrypt(encrypted) }
    }
}

@Suite("VoiceEmbeddingCodec")
struct VoiceEmbeddingCodecTests {
    @Test("encode/decode round-trips arbitrary float vectors, including negatives and zero")
    func roundTripsFloats() {
        let embedding: [Float] = [0, -1, 1, 0.333_333, -0.999_999, Float.leastNonzeroMagnitude]
        let encoded = VoiceEmbeddingCodec.encode(embedding)
        let decoded = VoiceEmbeddingCodec.decode(encoded)
        #expect(decoded == embedding)
    }

    @Test("decode of empty data returns an empty array")
    func decodeEmptyData() {
        #expect(VoiceEmbeddingCodec.decode(Data()) == [])
    }

    @Test("decode of misaligned data (not a multiple of 4 bytes) returns an empty array rather than crashing")
    func decodeMisalignedDataIsSafe() {
        #expect(VoiceEmbeddingCodec.decode(Data([1, 2, 3])) == [])
    }
}

private extension Data {
    /// Naive subsequence search, adequate for a small (1 KB) test fixture.
    func contains(subsequence needle: Data) -> Bool {
        guard !needle.isEmpty, needle.count <= count else { return false }
        let haystack = Array(self)
        let pattern = Array(needle)
        guard haystack.count >= pattern.count else { return false }
        for start in 0...(haystack.count - pattern.count) {
            if Array(haystack[start..<(start + pattern.count)]) == pattern { return true }
        }
        return false
    }
}
