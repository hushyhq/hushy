import Foundation
#if canImport(Security)
import Security
#endif

/// Abstraction over "somewhere safe to keep a small secret," so the real Keychain-backed
/// implementation can be swapped for an in-memory fake in tests without touching the real
/// login Keychain.
public protocol KeyStoreProtocol: Sendable {
    /// Reads the secret stored under `account`, or nil if nothing is stored yet.
    func read(account: String) throws -> Data?
    /// Stores (overwriting any previous value) the secret under `account`.
    func write(_ data: Data, account: String) throws
    /// Removes the secret under `account`, if present. Not an error if it was already absent.
    func delete(account: String) throws
}

public enum KeyStoreError: Error, LocalizedError {
    case unhandledStatus(OSStatus)
    case fileNotWritten

    public var errorDescription: String? {
        switch self {
        case .fileNotWritten:
            return "Hushy could not save to its own folder."
        case .unhandledStatus(let status):
            #if canImport(Security)
            return (SecCopyErrorMessageString(status, nil) as String?) ?? "Keychain error \(status)"
            #else
            return "Keychain error \(status)"
            #endif
        }
    }
}

#if canImport(Security)
/// The real Keychain-backed key store.
///
/// Items are `kSecClassGenericPassword`, scoped to `service`, with
/// `kSecAttrAccessibleWhenUnlockedThisDeviceOnly` (never synced to iCloud Keychain, never
/// readable before first unlock) and `kSecAttrSynchronizable: false` made explicit. Updates
/// re-assert the accessibility class, so an item created under an older, looser class is
/// tightened the next time it's written.
///
/// **Data-protection keychain.** When `useDataProtectionKeychain` is true (the default only when
/// the running binary is entitled for it — see `dataProtectionKeychainAvailable` and
/// docs/guide/RELEASE.md), items live in the iOS-style data-protection keychain, which enforces
/// the accessibility class and access groups by code signature rather than per-item ACL
/// prompts. Existing items in the legacy file-based login keychain stay readable: they are
/// migrated on first read (`MigratingKeyStore`) and the legacy copy deleted. Ad-hoc/dev builds
/// without the entitlement keep using the login keychain exactly as before.
public struct KeychainKeyStore: KeyStoreProtocol {
    /// The Keychain "service" all of this app's items are scoped under. A distinct value is
    /// used in tests so test runs never collide with (or depend on) real user Keychain state.
    public let service: String
    public let usesDataProtectionKeychain: Bool
    private let backend: any KeyStoreProtocol

    /// The service of the recording-encryption key. Named so the uninstall plan lists the same one.
    public static let encryptionService = "app.hushy.encryption"

    public init(service: String = Self.encryptionService, useDataProtectionKeychain: Bool = Self.dataProtectionKeychainAvailable) {
        self.service = service
        self.usesDataProtectionKeychain = useDataProtectionKeychain
        let legacy = KeychainItemStore(service: service, dataProtection: false)
        backend = useDataProtectionKeychain
            ? MigratingKeyStore(primary: KeychainItemStore(service: service, dataProtection: true), legacy: legacy)
            : legacy
    }

    /// True when this process is signed with a keychain access group / application identifier —
    /// what macOS requires for the data-protection keychain. Developer ID builds get it from a
    /// provisioning profile; ad-hoc dev builds don't, and must keep using the login keychain.
    public static let dataProtectionKeychainAvailable: Bool = {
        guard let task = SecTaskCreateFromSelf(nil) else { return false }
        for key in ["keychain-access-groups", "com.apple.application-identifier"] {
            if SecTaskCopyValueForEntitlement(task, key as CFString, nil) != nil { return true }
        }
        return false
    }()

    public func read(account: String) throws -> Data? { try backend.read(account: account) }
    public func write(_ data: Data, account: String) throws { try backend.write(data, account: account) }
    public func delete(account: String) throws { try backend.delete(account: account) }
}

/// One keychain flavor (legacy login keychain, or data-protection keychain) for one service.
struct KeychainItemStore: KeyStoreProtocol {
    let service: String
    let dataProtection: Bool

    func read(account: String) throws -> Data? {
        var query = baseQuery(account: account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        switch status {
        case errSecSuccess:
            return result as? Data
        case errSecItemNotFound:
            return nil
        default:
            throw KeyStoreError.unhandledStatus(status)
        }
    }

    func write(_ data: Data, account: String) throws {
        if try read(account: account) != nil {
            let query = baseQuery(account: account)
            // Re-assert the accessibility class on update, not just on add.
            let update: [String: Any] = [
                kSecValueData as String: data,
                kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
            ]
            let status = SecItemUpdate(query as CFDictionary, update as CFDictionary)
            guard status == errSecSuccess else { throw KeyStoreError.unhandledStatus(status) }
            return
        }
        var query = baseQuery(account: account)
        query[kSecValueData as String] = data
        query[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        let status = SecItemAdd(query as CFDictionary, nil)
        guard status == errSecSuccess else { throw KeyStoreError.unhandledStatus(status) }
    }

    func delete(account: String) throws {
        let query = baseQuery(account: account)
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeyStoreError.unhandledStatus(status)
        }
    }

    private func baseQuery(account: String) -> [String: Any] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrSynchronizable as String: false,
        ]
        if dataProtection { query[kSecUseDataProtectionKeychain as String] = true }
        return query
    }
}
#endif

/// Reads through to a legacy store and migrates: a value found only in `legacy` is copied into
/// `primary` and then removed from `legacy`. Writes go to `primary` (clearing any legacy copy);
/// deletes clear both. Used to move existing login-keychain items into the data-protection
/// keychain without losing them; pure over `KeyStoreProtocol`, so it's tested with in-memory
/// stores.
public struct MigratingKeyStore: KeyStoreProtocol {
    let primary: any KeyStoreProtocol
    let legacy: any KeyStoreProtocol

    public init(primary: any KeyStoreProtocol, legacy: any KeyStoreProtocol) {
        self.primary = primary
        self.legacy = legacy
    }

    public func read(account: String) throws -> Data? {
        if let data = try primary.read(account: account) { return data }
        guard let data = try legacy.read(account: account) else { return nil }
        // Copy first; only drop the legacy item once the new one is safely written. If the copy
        // fails, the legacy value is still returned and stays where it was.
        do {
            try primary.write(data, account: account)
            try? legacy.delete(account: account)
        } catch {}
        return data
    }

    public func write(_ data: Data, account: String) throws {
        try primary.write(data, account: account)
        try? legacy.delete(account: account)
    }

    public func delete(account: String) throws {
        try primary.delete(account: account)
        try legacy.delete(account: account)
    }
}

/// An in-memory key store for tests and previews. Never touches the real Keychain.
public final class InMemoryKeyStore: KeyStoreProtocol, @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String: Data] = [:]

    public init() {}

    public func read(account: String) throws -> Data? {
        lock.withLock { storage[account] }
    }

    public func write(_ data: Data, account: String) throws {
        lock.withLock { storage[account] = data }
    }

    public func delete(account: String) throws {
        lock.withLock { _ = storage.removeValue(forKey: account) }
    }
}

private extension NSLock {
    func withLock<T>(_ body: () -> T) -> T {
        lock()
        defer { unlock() }
        return body()
    }
}

/// Keeps small secrets in one file in the app's folder, readable only by the person's macOS
/// account (mode 0600) and left out of backups.
///
/// The account session, approval and entitlement live here instead of the Keychain: a build
/// without a Team ID is a different Keychain client from the build before it, so every update
/// made macOS ask for the login password before the app could read its own items. A file is
/// weaker than the Keychain (any process running as the person can read it); the founder chose
/// it on 2026-10-10 until there is a Developer ID.
public struct FileKeyStore: KeyStoreProtocol {
    private static let lock = NSLock()
    private let url: URL

    public init(url: URL) { self.url = url }

    var fileURL: URL { url }

    /// The account store's file in the app's folder (follows `HUSHY_HOME`).
    public static var account: FileKeyStore {
        FileKeyStore(url: AppPaths.supportDirectory.appendingPathComponent("account.keys"))
    }

    public func read(account: String) throws -> Data? {
        try Self.lock.withLock { try load()[account] }
    }

    /// A file that cannot be read is replaced, so a damaged file never blocks signing in.
    public func write(_ data: Data, account: String) throws {
        try Self.lock.withLock {
            var items = (try? load()) ?? [:]
            items[account] = data
            try save(items)
        }
    }

    public func delete(account: String) throws {
        try Self.lock.withLock {
            var items = (try? load()) ?? [:]
            guard items.removeValue(forKey: account) != nil else { return }
            try save(items)
        }
    }

    private func load() throws -> [String: Data] {
        guard FileManager.default.fileExists(atPath: url.path) else { return [:] }
        return try JSONDecoder().decode([String: Data].self, from: Data(contentsOf: url))
    }

    /// Written to a private temporary file first and renamed over the old one, so the file is
    /// never half-written and never readable by anyone else, even for a moment.
    private func save(_ items: [String: Data]) throws {
        let files = FileManager.default
        try files.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let temporary = url.appendingPathExtension("tmp")
        try? files.removeItem(at: temporary)
        let bytes = try JSONEncoder().encode(items)
        guard files.createFile(atPath: temporary.path, contents: bytes, attributes: [.posixPermissions: 0o600]),
              rename(temporary.path, url.path) == 0 else {
            try? files.removeItem(at: temporary)
            throw KeyStoreError.fileNotWritten
        }
        var saved = url
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? saved.setResourceValues(values)
    }
}
