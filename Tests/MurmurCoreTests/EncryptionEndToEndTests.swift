import CryptoKit
import Foundation
import Testing
@testable import MurmurCore

/// A manual-style end-to-end check of the encryption feature against a real on-disk store and
/// real audio files, seeded the way `HUSHY_HOME`-pointed manual testing would: a temp "app data"
/// directory, a handful of dictation rows, and a fake audio file, then verifying (1) the
/// ciphertext contains none of the plaintext, (2) decrypting with the right key recovers it
/// exactly, (3) search over the (unencrypted) text columns still works throughout, and (4)
/// turning encryption back off restores plaintext audio. This exercises the same path the task
/// asked to verify manually with `sqlite3`/HUSHY_HOME, just automated so it runs in CI too.
@Suite("Encryption end-to-end (temp store + real audio files)")
struct EncryptionEndToEndTests {
    @Test("seeded dictations remain searchable, and audio round-trips through encrypt/decrypt undetected as plaintext")
    func endToEndEncryptionFlow() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("hushy-e2e-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        let dbURL = root.appendingPathComponent("murmur.sqlite")
        let store = try Store(url: dbURL)
        for index in 0..<5 {
            let dictation = Dictation(
                rawText: "raw \(index)", text: "hello world \(index)", appBundleID: "com.test", appName: "Test",
                durationSeconds: 3.0, status: .inserted)
            _ = try store.save(dictation)
        }
        #expect(try store.recentDictations().count == 5)

        // A fake audio file, standing in for a saved dictation's WAV.
        let audioDir = root.appendingPathComponent("Audio", isDirectory: true)
        try FileManager.default.createDirectory(at: audioDir, withIntermediateDirectories: true)
        let wav = audioDir.appendingPathComponent("fake.wav")
        let secretMarker = "SECRET_SPEECH_CONTENT"
        try Data("FAKE_WAV_AUDIO_BYTES_\(secretMarker)".utf8).write(to: wav)

        let keyManager = EncryptionKeyManager(keyStore: InMemoryKeyStore())
        let key = try keyManager.loadOrCreateKey()

        // Enable: encrypt every audio file.
        let progress = try AudioEncryptionMigrator.encryptAll(under: [audioDir], key: key)
        #expect(progress.filesTotal == 1)
        #expect(progress.lastError == nil)

        let encryptedURL = wav.appendingPathExtension("enc")
        #expect(!FileManager.default.fileExists(atPath: wav.path), "plaintext should be gone after a verified migration")
        #expect(FileManager.default.fileExists(atPath: encryptedURL.path))

        // The database file (and its DB-native `sqlite3`-openability) is out of scope for this
        // design — see the accompanying report — so what must hold is: the *audio* ciphertext on
        // disk contains no recognizable plaintext, matching "unreadable without the key."
        let onDisk = try Data(contentsOf: encryptedURL)
        #expect(onDisk.range(of: Data(secretMarker.utf8)) == nil, "ciphertext must not contain the plaintext marker")

        // Decrypting with the right key recovers the exact original bytes.
        let decrypted = try EncryptedFileStore.read(encryptedURL, key: key)
        #expect(String(data: decrypted, encoding: .utf8) == "FAKE_WAV_AUDIO_BYTES_\(secretMarker)")

        // History/search keep working throughout — encryption here never touches text columns.
        #expect(try store.searchDictations("hello").count == 5)

        // Disable: decrypt back to plaintext, verified.
        let reverted = try AudioEncryptionMigrator.decryptAll(under: [audioDir], key: key)
        #expect(reverted.filesTotal == 1)
        #expect(reverted.lastError == nil)
        #expect(FileManager.default.fileExists(atPath: wav.path))
        #expect(!FileManager.default.fileExists(atPath: encryptedURL.path))
        #expect(try Data(contentsOf: wav) == Data("FAKE_WAV_AUDIO_BYTES_\(secretMarker)".utf8))

        // Search still works after disabling, unaffected throughout.
        #expect(try store.searchDictations("hello").count == 5)
    }
}
