import CryptoKit
import Foundation

/// Owns Hushy's single data-encryption key (DEK): a 256-bit random key generated once,
/// stored in the login Keychain, and used both to encrypt audio files directly (CryptoKit
/// AES-GCM) and to derive the passphrase for the encrypted disk image that holds the database
/// (see `EncryptedVolume`).
///
/// There is exactly one DEK per install. Losing both the Keychain item and the recovery key
/// means the data is unrecoverable — this is stated plainly in the Settings UI copy, not just
/// here.
public final class EncryptionKeyManager: Sendable {
    /// Keychain account name for the DEK. Distinct from the recovery-key marker so the two
    /// can be checked/rotated independently if that's ever needed.
    private static let dekAccount = "data-encryption-key"

    private let keyStore: any KeyStoreProtocol

    public init(keyStore: any KeyStoreProtocol) {
        self.keyStore = keyStore
    }

    /// Returns the existing DEK, or generates and stores a new random 256-bit key if none
    /// exists yet. Safe to call repeatedly; only the first call on a fresh install writes.
    public func loadOrCreateKey() throws -> SymmetricKey {
        if let existing = try keyStore.read(account: Self.dekAccount) {
            guard existing.count == Self.keyByteCount else {
                throw EncryptionError.corruptKeyMaterial
            }
            return SymmetricKey(data: existing)
        }
        let key = SymmetricKey(size: .bits256)
        try keyStore.write(key.withUnsafeBytes { Data($0) }, account: Self.dekAccount)
        return key
    }

    /// Whether a DEK has already been generated (without generating one).
    public func hasKey() throws -> Bool {
        try keyStore.read(account: Self.dekAccount) != nil
    }

    /// Permanently removes the DEK from the Keychain. Used when disabling encryption after the
    /// plaintext copy has been verified and the encrypted copy securely deleted, and by tests.
    public func deleteKey() throws {
        try keyStore.delete(account: Self.dekAccount)
    }

    /// Encodes the current DEK as a one-time recovery key: a base32, hyphen-grouped string
    /// (e.g. `"K3F9-7QRT-..."`), shown once in Settings with a "Copy" button. This is the *same*
    /// key material as the Keychain item, re-encoded for a human to write down or paste back —
    /// it is not a separate escrow key. Losing both means the data cannot be decrypted.
    public func recoveryKeyString() throws -> String {
        guard let raw = try keyStore.read(account: Self.dekAccount) else {
            throw EncryptionError.noKeyToExport
        }
        return RecoveryKeyCodec.encode(raw)
    }

    /// Restores the DEK from a recovery key string the user pasted back in (e.g. after
    /// reinstalling, or recovering a Keychain that lost the item). Overwrites any existing key.
    public func restoreKey(fromRecoveryKey text: String) throws {
        guard let raw = RecoveryKeyCodec.decode(text), raw.count == Self.keyByteCount else {
            throw EncryptionError.invalidRecoveryKey
        }
        try keyStore.write(raw, account: Self.dekAccount)
    }

    private static let keyByteCount = 32
}

public enum EncryptionError: Error, LocalizedError {
    case corruptKeyMaterial
    case noKeyToExport
    case invalidRecoveryKey
    case encryptionFailed
    case decryptionFailed
    case tamperedData

    public var errorDescription: String? {
        switch self {
        case .corruptKeyMaterial: "The stored encryption key is invalid."
        case .noKeyToExport: "No encryption key has been created yet."
        case .invalidRecoveryKey: "That recovery key doesn't look right. Check for typos."
        case .encryptionFailed: "Couldn't encrypt the file."
        case .decryptionFailed: "Couldn't decrypt the file."
        case .tamperedData: "This file's contents don't match what was encrypted (it may be corrupted or tampered with)."
        }
    }
}

/// Encodes/decodes 32-byte key material as a human-friendly recovery string: Crockford base32
/// (no ambiguous characters: no I, L, O, U), grouped in blocks of 4 separated by hyphens, so a
/// user can read it aloud or type it back with fewer transcription errors than raw base64.
enum RecoveryKeyCodec {
    private static let alphabet = Array("0123456789ABCDEFGHJKMNPQRSTVWXYZ")
    private static let reverse: [Character: Int] = Dictionary(uniqueKeysWithValues: alphabet.enumerated().map { ($1, $0) })

    static func encode(_ data: Data) -> String {
        var bits = 0
        var value = 0
        var output = ""
        for byte in data {
            value = (value << 8) | Int(byte)
            bits += 8
            while bits >= 5 {
                bits -= 5
                output.append(alphabet[(value >> bits) & 0x1F])
            }
        }
        if bits > 0 {
            output.append(alphabet[(value << (5 - bits)) & 0x1F])
        }
        return output.chunked(into: 4).joined(separator: "-")
    }

    static func decode(_ text: String) -> Data? {
        let cleaned = text.uppercased().filter { !$0.isWhitespace && $0 != "-" }
        guard !cleaned.isEmpty else { return nil }
        var bits = 0
        var value = 0
        var bytes: [UInt8] = []
        for char in cleaned {
            guard let index = reverse[char] else { return nil }
            value = (value << 5) | index
            bits += 5
            if bits >= 8 {
                bits -= 8
                bytes.append(UInt8((value >> bits) & 0xFF))
            }
        }
        return Data(bytes)
    }
}

private extension String {
    func chunked(into size: Int) -> [String] {
        var result: [String] = []
        var index = startIndex
        while index < endIndex {
            let end = self.index(index, offsetBy: size, limitedBy: endIndex) ?? endIndex
            result.append(String(self[index..<end]))
            index = end
        }
        return result
    }
}
