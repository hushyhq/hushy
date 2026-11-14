import CryptoKit
import Foundation

/// Encrypts and decrypts audio files on disk with AES-GCM, using Hushy's single data
/// encryption key (see `EncryptionKeyManager`).
///
/// File format: `[4-byte little-endian magic "HENC"][12-byte nonce][ciphertext][16-byte tag]`.
/// `AES.GCM.SealedBox.combined` already lays out `nonce || ciphertext || tag`, so this is just
/// that combined representation prefixed with a magic number to distinguish an encrypted file
/// from a legacy plaintext WAV without depending on the filename alone. Encrypted files are
/// saved with a `.wav.enc` extension; `isEncrypted(at:)` and `decryptedExtension` help callers
/// that need to handle a mix of old plaintext and new encrypted files during the transition.
public enum EncryptedFileStore {
    static let magic: [UInt8] = Array("HENC".utf8)

    /// Encrypts `data` and writes it to `url`, creating intermediate directories as needed.
    /// Uses a fresh random nonce every call, per CryptoKit's default `AES.GCM.seal` behavior.
    public static func write(_ data: Data, to url: URL, key: SymmetricKey) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard let sealed = try? AES.GCM.seal(data, using: key), let combined = sealed.combined else {
            throw EncryptionError.encryptionFailed
        }
        var out = Data(magic)
        out.append(combined)
        try out.write(to: url, options: .atomic)
    }

    /// Reads and decrypts a file written by `write(_:to:key:)`. Throws `.tamperedData` if the
    /// authentication tag doesn't match (corruption or tampering), never silently returning
    /// wrong bytes.
    public static func read(_ url: URL, key: SymmetricKey) throws -> Data {
        let raw = try Data(contentsOf: url)
        guard raw.count > magic.count, Array(raw.prefix(magic.count)) == magic else {
            throw EncryptionError.decryptionFailed
        }
        let combined = raw.dropFirst(magic.count)
        do {
            let sealed = try AES.GCM.SealedBox(combined: combined)
            return try AES.GCM.open(sealed, using: key)
        } catch is CryptoKitError {
            throw EncryptionError.tamperedData
        }
    }

    /// Whether the file at `url` looks like one written by `write(_:to:key:)` (by magic number,
    /// not just extension, since a rename or an old build's file could disagree with either).
    public static func isEncrypted(at url: URL) -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? handle.close() }
        guard let prefix = try? handle.read(upToCount: magic.count) else { return false }
        return Array(prefix) == magic
    }

    /// `foo.wav` → `foo.wav.enc`. Used when writing a new encrypted file next to (or replacing)
    /// a plaintext one.
    public static func encryptedURL(for plainURL: URL) -> URL {
        plainURL.appendingPathExtension("enc")
    }

    /// Reads either an encrypted (`.wav.enc`, detected by magic) or legacy plaintext WAV file at
    /// `url`, transparently handling the mixed old/new-file transition described in the task:
    /// callers that used to do a plain `Data(contentsOf:)` can call this instead and not care
    /// which era a given file is from.
    public static func readAudioData(at url: URL, key: SymmetricKey) throws -> Data {
        if isEncrypted(at: url) {
            return try read(url, key: key)
        }
        return try Data(contentsOf: url)
    }
}
