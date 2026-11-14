import CryptoKit
import Foundation
import Testing
@testable import MurmurCore

@Suite("EncryptedFileStore")
struct EncryptedFileStoreTests {
    private func tempURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("EncryptedFileStoreTests-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent("audio.wav.enc")
    }

    @Test("round-trips arbitrary data through write and read")
    func roundTrips() throws {
        let key = SymmetricKey(size: .bits256)
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let original = Data((0..<10_000).map { UInt8($0 % 256) })

        try EncryptedFileStore.write(original, to: url, key: key)
        let decrypted = try EncryptedFileStore.read(url, key: key)
        #expect(decrypted == original)
    }

    @Test("encrypted file is not readable as plaintext")
    func encryptedFileIsNotPlaintext() throws {
        let key = SymmetricKey(size: .bits256)
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let original = Data("this is definitely secret speech content".utf8)

        try EncryptedFileStore.write(original, to: url, key: key)
        let onDisk = try Data(contentsOf: url)
        #expect(!onDisk.isEmpty)
        #expect(onDisk != original)
        // The plaintext bytes shouldn't appear anywhere in the ciphertext.
        #expect(onDisk.range(of: original) == nil)
    }

    @Test("wrong key fails to decrypt instead of returning garbage silently")
    func wrongKeyFailsToDecrypt() throws {
        let key = SymmetricKey(size: .bits256)
        let wrongKey = SymmetricKey(size: .bits256)
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        try EncryptedFileStore.write(Data("hello".utf8), to: url, key: key)

        #expect(throws: EncryptionError.self) {
            _ = try EncryptedFileStore.read(url, key: wrongKey)
        }
    }

    @Test("tampering with ciphertext is detected, not silently accepted")
    func detectsTampering() throws {
        let key = SymmetricKey(size: .bits256)
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        try EncryptedFileStore.write(Data("hello world".utf8), to: url, key: key)

        var bytes = try Data(contentsOf: url)
        // Flip a byte well past the magic+nonce header, inside the ciphertext/tag region.
        let flipIndex = bytes.count - 1
        bytes[flipIndex] ^= 0xFF
        try bytes.write(to: url)

        #expect(throws: EncryptionError.self) {
            _ = try EncryptedFileStore.read(url, key: key)
        }
    }

    @Test("isEncrypted detects the magic header, not just the extension")
    func isEncryptedDetectsMagicHeader() throws {
        let key = SymmetricKey(size: .bits256)
        let encryptedURL = tempURL()
        let plainURL = encryptedURL.deletingLastPathComponent().appendingPathComponent("plain.wav")
        defer { try? FileManager.default.removeItem(at: encryptedURL.deletingLastPathComponent()) }

        try EncryptedFileStore.write(Data("secret".utf8), to: encryptedURL, key: key)
        try FileManager.default.createDirectory(at: plainURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("RIFF....WAVEfmt ".utf8).write(to: plainURL)

        #expect(EncryptedFileStore.isEncrypted(at: encryptedURL))
        #expect(!EncryptedFileStore.isEncrypted(at: plainURL))
    }

    @Test("readAudioData transparently handles a mix of legacy plaintext and new encrypted files")
    func readAudioDataHandlesMixedFiles() throws {
        let key = SymmetricKey(size: .bits256)
        let dir = tempURL().deletingLastPathComponent()
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        let encryptedURL = dir.appendingPathComponent("new.wav.enc")
        let plainURL = dir.appendingPathComponent("old.wav")
        let plainBytes = Data("legacy plaintext wav bytes".utf8)
        let secretBytes = Data("new encrypted wav bytes".utf8)
        try EncryptedFileStore.write(secretBytes, to: encryptedURL, key: key)
        try plainBytes.write(to: plainURL)

        #expect(try EncryptedFileStore.readAudioData(at: encryptedURL, key: key) == secretBytes)
        #expect(try EncryptedFileStore.readAudioData(at: plainURL, key: key) == plainBytes)
    }

    @Test("encryptedURL appends .enc to the plaintext path")
    func encryptedURLAppendsExtension() {
        let plain = URL(fileURLWithPath: "/tmp/chunk-0001.wav")
        #expect(EncryptedFileStore.encryptedURL(for: plain).lastPathComponent == "chunk-0001.wav.enc")
    }
}
