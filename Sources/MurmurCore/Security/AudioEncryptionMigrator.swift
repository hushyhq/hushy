import CryptoKit
import Foundation

/// Encrypts (or decrypts) every audio WAV file under the app's data directories, one file at a
/// time, so the whole thing can be interrupted (app quit, crash, sleep) and resumed without
/// redoing work or losing a file.
///
/// The plaintext original is never deleted until the encrypted copy has been read back and
/// byte-for-byte verified — mirroring the DB migration's "never delete the plaintext until the
/// encrypted copy is verified" rule. `Store.rebaseMediaPaths`-style path bookkeeping isn't
/// needed here since the path in the database is the *folder*/*file* path, and encryption keeps
/// the same base name with an added `.enc` extension — callers that resolve an `audioPath`
/// already do so through `EncryptedFileStore.readAudioData`, which checks both.
public enum AudioEncryptionMigrator {
    public struct Progress: Sendable, Equatable {
        public var filesTotal: Int
        public var filesDone: Int
        public var lastError: String?

        public init(filesTotal: Int, filesDone: Int, lastError: String? = nil) {
            self.filesTotal = filesTotal
            self.filesDone = filesDone
            self.lastError = lastError
        }
    }

    /// Encrypts every plaintext `.wav` file found under `directories` (recursively) in place:
    /// writes `name.wav.enc` next to it, verifies the round trip, then deletes `name.wav`.
    /// Files that are already encrypted (by `EncryptedFileStore.isEncrypted`) are skipped, so
    /// calling this twice in a row (e.g. after an interruption) is safe and cheap.
    @discardableResult
    public static func encryptAll(
        under directories: [URL], key: SymmetricKey, fileManager: FileManager = .default,
        onProgress: (@Sendable (Progress) -> Void)? = nil
    ) throws -> Progress {
        let files = wavFiles(under: directories, fileManager: fileManager)
        var progress = Progress(filesTotal: files.count, filesDone: 0, lastError: nil)
        onProgress?(progress)
        for file in files {
            if EncryptedFileStore.isEncrypted(at: file) {
                progress.filesDone += 1
                onProgress?(progress)
                continue
            }
            do {
                try encryptOneFile(file, key: key, fileManager: fileManager)
            } catch {
                progress.lastError = error.localizedDescription
            }
            progress.filesDone += 1
            onProgress?(progress)
        }
        return progress
    }

    /// Reverses `encryptAll`: decrypts every `.wav.enc` file back to plaintext `.wav`, verifies,
    /// then deletes the encrypted copy. Used when the user turns encryption back off.
    @discardableResult
    public static func decryptAll(
        under directories: [URL], key: SymmetricKey, fileManager: FileManager = .default,
        onProgress: (@Sendable (Progress) -> Void)? = nil
    ) throws -> Progress {
        let files = encFiles(under: directories, fileManager: fileManager)
        var progress = Progress(filesTotal: files.count, filesDone: 0, lastError: nil)
        onProgress?(progress)
        for file in files {
            do {
                try decryptOneFile(file, key: key, fileManager: fileManager)
            } catch {
                progress.lastError = error.localizedDescription
            }
            progress.filesDone += 1
            onProgress?(progress)
        }
        return progress
    }

    private static func encryptOneFile(_ plainURL: URL, key: SymmetricKey, fileManager: FileManager) throws {
        let plaintext = try Data(contentsOf: plainURL)
        let encryptedURL = EncryptedFileStore.encryptedURL(for: plainURL)
        try EncryptedFileStore.write(plaintext, to: encryptedURL, key: key)
        // Verify before touching the original: read the encrypted copy back and compare bytes.
        let verified = try EncryptedFileStore.read(encryptedURL, key: key)
        guard verified == plaintext else {
            try? fileManager.removeItem(at: encryptedURL)
            throw EncryptionError.encryptionFailed
        }
        try SecureDelete.remove(plainURL, fileManager: fileManager)
    }

    private static func decryptOneFile(_ encryptedURL: URL, key: SymmetricKey, fileManager: FileManager) throws {
        let plaintext = try EncryptedFileStore.read(encryptedURL, key: key)
        let plainURL = encryptedURL.deletingPathExtension()
        try plaintext.write(to: plainURL, options: .atomic)
        let verified = try Data(contentsOf: plainURL)
        guard verified == plaintext else {
            try? fileManager.removeItem(at: plainURL)
            throw EncryptionError.decryptionFailed
        }
        try SecureDelete.remove(encryptedURL, fileManager: fileManager)
    }

    /// Every plaintext `.wav` file plus every already-encrypted `.wav.enc` file, so a resumed
    /// run can report an accurate total (and skip the ones already done) instead of only ever
    /// seeing the files it hasn't touched yet.
    private static func wavFiles(under directories: [URL], fileManager: FileManager) -> [URL] {
        allFiles(under: directories, fileManager: fileManager).filter {
            let ext = $0.pathExtension.lowercased()
            return ext == "wav" || (ext == "enc" && $0.deletingPathExtension().pathExtension.lowercased() == "wav")
        }
    }

    private static func encFiles(under directories: [URL], fileManager: FileManager) -> [URL] {
        allFiles(under: directories, fileManager: fileManager).filter { $0.pathExtension.lowercased() == "enc" }
    }

    private static func allFiles(under directories: [URL], fileManager: FileManager) -> [URL] {
        directories.flatMap { directory -> [URL] in
            guard let enumerator = fileManager.enumerator(at: directory, includingPropertiesForKeys: [.isRegularFileKey]) else {
                return []
            }
            var result: [URL] = []
            for case let url as URL in enumerator {
                if (try? url.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true {
                    result.append(url)
                }
            }
            return result
        }
    }
}

/// Overwrites a file's contents before removing it, so the plaintext doesn't linger recoverable
/// on disk after "deletion" (SSD wear-leveling means this is best-effort, not a guarantee, but
/// it's strictly better than a bare `removeItem`, and matches the `secure_delete` pragma turned
/// on for the database).
enum SecureDelete {
    static func remove(_ url: URL, fileManager: FileManager = .default) throws {
        if let size = try? fileManager.attributesOfItem(atPath: url.path)[.size] as? Int, size > 0 {
            if let handle = try? FileHandle(forWritingTo: url) {
                let zeros = Data(repeating: 0, count: min(size, 4 * 1024 * 1024))
                var remaining = size
                while remaining > 0 {
                    let chunk = min(remaining, zeros.count)
                    handle.write(zeros.prefix(chunk))
                    remaining -= chunk
                }
                try? handle.synchronize()
                try? handle.close()
            }
        }
        try fileManager.removeItem(at: url)
    }
}
