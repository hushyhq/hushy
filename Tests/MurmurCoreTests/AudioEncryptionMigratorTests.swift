import CryptoKit
import Foundation
import Testing
@testable import MurmurCore

/// Thread-safe accumulator for progress callbacks, since `onProgress` is `@Sendable`.
private final class ProgressBox: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [AudioEncryptionMigrator.Progress] = []

    func append(_ value: AudioEncryptionMigrator.Progress) {
        lock.lock()
        values.append(value)
        lock.unlock()
    }

    var snapshots: [AudioEncryptionMigrator.Progress] {
        lock.lock()
        defer { lock.unlock() }
        return values
    }
}

@Suite("AudioEncryptionMigrator")
struct AudioEncryptionMigratorTests {
    private func tempDir() -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("AudioEncryptionMigratorTests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    @Test("encrypts every plaintext wav under a directory and removes the plaintext")
    func encryptsAllFiles() throws {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let key = SymmetricKey(size: .bits256)
        let fileA = dir.appendingPathComponent("a.wav")
        let fileB = dir.appendingPathComponent("sub", isDirectory: true).appendingPathComponent("b.wav")
        try FileManager.default.createDirectory(at: fileB.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("audio A".utf8).write(to: fileA)
        try Data("audio B".utf8).write(to: fileB)

        let progress = try AudioEncryptionMigrator.encryptAll(under: [dir], key: key)
        #expect(progress.filesTotal == 2)
        #expect(progress.filesDone == 2)
        #expect(progress.lastError == nil)

        #expect(!FileManager.default.fileExists(atPath: fileA.path))
        #expect(!FileManager.default.fileExists(atPath: fileB.path))
        let encA = fileA.appendingPathExtension("enc")
        let encB = fileB.appendingPathExtension("enc")
        #expect(try EncryptedFileStore.read(encA, key: key) == Data("audio A".utf8))
        #expect(try EncryptedFileStore.read(encB, key: key) == Data("audio B".utf8))
    }

    @Test("is idempotent: running twice does not double-encrypt or error")
    func idempotentOnRerun() throws {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let key = SymmetricKey(size: .bits256)
        let file = dir.appendingPathComponent("a.wav")
        try Data("audio".utf8).write(to: file)

        _ = try AudioEncryptionMigrator.encryptAll(under: [dir], key: key)
        let second = try AudioEncryptionMigrator.encryptAll(under: [dir], key: key)
        // Second pass finds only the already-encrypted file and skips it cleanly.
        #expect(second.filesTotal == 1)
        #expect(second.lastError == nil)
        #expect(try EncryptedFileStore.read(dir.appendingPathComponent("a.wav.enc"), key: key) == Data("audio".utf8))
    }

    @Test("resumable: encrypting again after simulating an interruption finishes the remaining files")
    func resumesAfterInterruption() throws {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let key = SymmetricKey(size: .bits256)
        let fileA = dir.appendingPathComponent("a.wav")
        let fileB = dir.appendingPathComponent("b.wav")
        try Data("A".utf8).write(to: fileA)
        try Data("B".utf8).write(to: fileB)

        // Simulate "a" already migrated (as if the process died after finishing it).
        try EncryptedFileStore.write(Data("A".utf8), to: fileA.appendingPathExtension("enc"), key: key)
        try FileManager.default.removeItem(at: fileA)

        let progress = try AudioEncryptionMigrator.encryptAll(under: [dir], key: key)
        #expect(progress.filesTotal == 2) // a.wav.enc (skipped) + b.wav (encrypted)
        #expect(try EncryptedFileStore.read(fileB.appendingPathExtension("enc"), key: key) == Data("B".utf8))
        #expect(!FileManager.default.fileExists(atPath: fileB.path))
    }

    @Test("decryptAll reverses encryptAll")
    func decryptReversesEncrypt() throws {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let key = SymmetricKey(size: .bits256)
        let file = dir.appendingPathComponent("a.wav")
        let original = Data("round trip me".utf8)
        try original.write(to: file)

        _ = try AudioEncryptionMigrator.encryptAll(under: [dir], key: key)
        #expect(!FileManager.default.fileExists(atPath: file.path))

        let progress = try AudioEncryptionMigrator.decryptAll(under: [dir], key: key)
        #expect(progress.filesTotal == 1)
        #expect(progress.lastError == nil)
        #expect(FileManager.default.fileExists(atPath: file.path))
        #expect(try Data(contentsOf: file) == original)
        #expect(!FileManager.default.fileExists(atPath: file.appendingPathExtension("enc").path))
    }

    @Test("reports progress via the callback as files complete")
    func reportsProgress() throws {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let key = SymmetricKey(size: .bits256)
        for index in 0..<5 {
            try Data("file \(index)".utf8).write(to: dir.appendingPathComponent("f\(index).wav"))
        }

        let box = ProgressBox()
        _ = try AudioEncryptionMigrator.encryptAll(under: [dir], key: key) { box.append($0) }
        let snapshots = box.snapshots
        // Initial snapshot (0 done) plus one per completed file.
        #expect(snapshots.count == 6)
        #expect(snapshots.last?.filesDone == 5)
        #expect(snapshots.allSatisfy { $0.filesTotal == 5 })
    }

    @Test("empty directory produces zero-total progress with no error")
    func emptyDirectoryIsANoOp() throws {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let key = SymmetricKey(size: .bits256)
        let progress = try AudioEncryptionMigrator.encryptAll(under: [dir], key: key)
        #expect(progress.filesTotal == 0)
        #expect(progress.filesDone == 0)
    }
}
