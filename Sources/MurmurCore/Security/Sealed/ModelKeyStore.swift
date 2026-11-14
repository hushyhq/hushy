import Foundation
#if canImport(Security)
import Security
#endif

/// Where a sealed model's 256-bit key rests on this Mac: one item per model id.
public protocol ModelKeyStoring: Sendable {
    func key(for modelID: String) throws -> Data?
    func save(_ key: Data, for modelID: String) throws
    func remove(modelID: String) throws
}

/// Keys in memory, for tests. Never touches the Keychain.
public final class InMemoryModelKeyStore: ModelKeyStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var keys: [String: Data] = [:]
    public init() {}

    public func key(for modelID: String) throws -> Data? { lock.withLock { keys[modelID] } }
    public func save(_ key: Data, for modelID: String) throws { lock.withLock { keys[modelID] = key } }
    public func remove(modelID: String) throws { lock.withLock { _ = keys.removeValue(forKey: modelID) } }
}

private extension NSLock {
    func withLock<T>(_ body: () -> T) -> T {
        lock()
        defer { unlock() }
        return body()
    }
}

#if canImport(Security)
/// The Keychain-backed key store.
///
/// - **Not synchronised, this device only.** `kSecAttrSynchronizable` is false and the item is
///   `kSecAttrAccessibleWhenUnlockedThisDeviceOnly`: it never reaches iCloud Keychain or a backup restored elsewhere.
/// - **Bound to Hushy's code signature.**
///   - In the *data-protection keychain* (used when the app is signed with an application identifier, see
///     `KeychainKeyStore.dataProtectionKeychainAvailable`) the item belongs to the app's access group
///     (`<team id>.<bundle id>`). The system hands it to a binary signed by that team and bundle id only, and asks
///     nobody: any other process gets "not found", scripts and other apps of the same user included.
///   - In the *file keychain* (an unsigned or ad-hoc build) the item's access list names this app alone, as a trusted
///     application. The system identifies it by its designated requirement (for a Developer ID build: the team id and
///     bundle id, which survives updates). Any other process, `security find-generic-password` included, is refused
///     unless the person types their login password.
/// - Works offline: reading touches no network.
public struct KeychainModelKeyStore: ModelKeyStoring, @unchecked Sendable {
    public static let service = SealedFormat.keychainService

    public let service: String
    /// nil = the person's default keychain search list. Tests pass a temporary keychain.
    private let keychain: SecKeychain?
    private let dataProtection: Bool
    private let accessGroup: String?

    public init(service: String = Self.service, keychain: SecKeychain? = nil,
                useDataProtectionKeychain: Bool = KeychainKeyStore.dataProtectionKeychainAvailable,
                accessGroup: String? = nil) {
        self.service = service
        self.keychain = keychain
        self.dataProtection = useDataProtectionKeychain && keychain == nil
        self.accessGroup = accessGroup
    }

    public func key(for modelID: String) throws -> Data? {
        var query = baseQuery(modelID)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        switch status {
        case errSecSuccess: return result as? Data
        case errSecItemNotFound: return nil
        default: throw KeyStoreError.unhandledStatus(status)
        }
    }

    public func save(_ key: Data, for modelID: String) throws {
        // Delete then add: the access list can only be set when an item is created.
        try remove(modelID: modelID)
        var query = baseQuery(modelID)
        query[kSecValueData as String] = key
        query[kSecAttrLabel as String] = "Hushy model key"
        query[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        if !dataProtection {
            query[kSecAttrAccess as String] = try Self.accessForThisAppOnly()
            if let keychain { query[kSecUseKeychain as String] = keychain }
        }
        let status = SecItemAdd(query as CFDictionary, nil)
        guard status == errSecSuccess else { throw KeyStoreError.unhandledStatus(status) }
    }

    public func remove(modelID: String) throws {
        let status = SecItemDelete(baseQuery(modelID) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw KeyStoreError.unhandledStatus(status) }
    }

    private func baseQuery(_ modelID: String) -> [String: Any] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: modelID,
            kSecAttrSynchronizable as String: false,
        ]
        if dataProtection {
            query[kSecUseDataProtectionKeychain as String] = true
            if let accessGroup { query[kSecAttrAccessGroup as String] = accessGroup }
        } else if let keychain {
            query[kSecMatchSearchList as String] = [keychain]
        }
        return query
    }

    /// An access list whose only trusted application is the running one (nil path = this process).
    private static func accessForThisAppOnly() throws -> SecAccess {
        var app: SecTrustedApplication?
        var status = SecTrustedApplicationCreateFromPath(nil, &app)
        guard status == errSecSuccess, let app else { throw KeyStoreError.unhandledStatus(status) }
        var access: SecAccess?
        status = SecAccessCreate("Hushy model key" as CFString, [app] as CFArray, &access)
        guard status == errSecSuccess, let access else { throw KeyStoreError.unhandledStatus(status) }
        return access
    }
}
#endif
