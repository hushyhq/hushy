import CryptoKit
import Foundation
import Testing
@testable import MurmurCore

@Suite("EncryptionKeyManager")
struct EncryptionKeyManagerTests {
    @Test("generates a 256-bit key on first use")
    func generatesKeyOnFirstUse() throws {
        let store = InMemoryKeyStore()
        let manager = EncryptionKeyManager(keyStore: store)
        #expect(try manager.hasKey() == false)

        let key = try manager.loadOrCreateKey()
        #expect(key.bitCount == 256)
        #expect(try manager.hasKey() == true)
    }

    @Test("returns the same key on repeated calls")
    func returnsSameKeyOnRepeatedCalls() throws {
        let store = InMemoryKeyStore()
        let manager = EncryptionKeyManager(keyStore: store)
        let first = try manager.loadOrCreateKey()
        let second = try manager.loadOrCreateKey()
        #expect(first.rawBytes == second.rawBytes)
    }

    @Test("deleteKey removes the key so a later load creates a new one")
    func deleteKeyRemovesKey() throws {
        let store = InMemoryKeyStore()
        let manager = EncryptionKeyManager(keyStore: store)
        let first = try manager.loadOrCreateKey()
        try manager.deleteKey()
        #expect(try manager.hasKey() == false)
        let second = try manager.loadOrCreateKey()
        #expect(first.rawBytes != second.rawBytes)
    }

    @Test("recovery key round-trips through restoreKey")
    func recoveryKeyRoundTrips() throws {
        let store = InMemoryKeyStore()
        let manager = EncryptionKeyManager(keyStore: store)
        let original = try manager.loadOrCreateKey()
        let recovery = try manager.recoveryKeyString()

        // Simulate a fresh install / lost Keychain item, then restore from the recovery key.
        try manager.deleteKey()
        #expect(try manager.hasKey() == false)
        try manager.restoreKey(fromRecoveryKey: recovery)
        let restored = try manager.loadOrCreateKey()
        #expect(restored.rawBytes == original.rawBytes)
    }

    @Test("recovery key string is human-friendly: uppercase, hyphenated, no ambiguous characters")
    func recoveryKeyFormat() throws {
        let store = InMemoryKeyStore()
        let manager = EncryptionKeyManager(keyStore: store)
        _ = try manager.loadOrCreateKey()
        let recovery = try manager.recoveryKeyString()

        #expect(recovery.contains("-"))
        let disallowed = Set("ILOUilou ")
        #expect(recovery.allSatisfy { !disallowed.contains($0) })
    }

    @Test("restoring garbage text throws invalidRecoveryKey")
    func restoringGarbageThrows() throws {
        let store = InMemoryKeyStore()
        let manager = EncryptionKeyManager(keyStore: store)
        #expect(throws: EncryptionError.self) {
            try manager.restoreKey(fromRecoveryKey: "not-a-real-key")
        }
    }

    @Test("exporting a recovery key before any key exists throws noKeyToExport")
    func exportingWithoutKeyThrows() throws {
        let store = InMemoryKeyStore()
        let manager = EncryptionKeyManager(keyStore: store)
        #expect(throws: EncryptionError.self) {
            _ = try manager.recoveryKeyString()
        }
    }
}

@Suite("RecoveryKeyCodec")
struct RecoveryKeyCodecTests {
    @Test("encode/decode round-trips arbitrary byte sequences")
    func roundTripsArbitraryBytes() {
        for length in [1, 15, 16, 32, 33, 64] {
            let bytes = Data((0..<length).map { UInt8(($0 * 37 + 11) % 256) })
            let encoded = RecoveryKeyCodec.encode(bytes)
            let decoded = RecoveryKeyCodec.decode(encoded)
            #expect(decoded == bytes, "length \(length)")
        }
    }

    @Test("decode is case-insensitive and tolerates stray whitespace")
    func decodeToleratesFormatting() {
        let bytes = Data(repeating: 0xAB, count: 32)
        let encoded = RecoveryKeyCodec.encode(bytes)
        let messy = " " + encoded.lowercased().replacingOccurrences(of: "-", with: " - ") + " "
        #expect(RecoveryKeyCodec.decode(messy) == bytes)
    }

    @Test("decode rejects characters outside the alphabet")
    func decodeRejectsInvalidCharacters() {
        #expect(RecoveryKeyCodec.decode("not$valid!chars") == nil)
    }
}

private extension SymmetricKey {
    var rawBytes: Data { withUnsafeBytes { Data($0) } }
}
