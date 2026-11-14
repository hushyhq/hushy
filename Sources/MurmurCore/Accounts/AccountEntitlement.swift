import Foundation

public struct AccountEntitlement: Codable, Sendable {
    public let userID: String
    public let isPro: Bool
    public let validUntil: Date?
    public let verifiedAt: Date
    public init(userID: String, isPro: Bool, validUntil: Date?, verifiedAt: Date) {
        self.userID = userID
        self.isPro = isPro; self.validUntil = validUntil; self.verifiedAt = verifiedAt
    }
    public func activeUntil(now: Date, grace: TimeInterval = 7 * 24 * 3600) -> Date? {
        guard isPro, let validUntil, now < validUntil.addingTimeInterval(grace) else { return nil }
        return validUntil.addingTimeInterval(grace)
    }
}

public struct AccountEntitlementStore: Sendable {
    private let keys: any KeyStoreProtocol
    public init(keys: any KeyStoreProtocol = FileKeyStore.account) { self.keys = keys }
    public func load(for userID: String) throws -> AccountEntitlement? {
        guard let bytes = try keys.read(account: "account.entitlement") else { return nil }
        guard let value = try? JSONDecoder().decode(AccountEntitlement.self, from: bytes), value.userID == userID else {
            try clear()
            return nil
        }
        return value
    }
    public func save(_ value: AccountEntitlement) throws { try keys.write(JSONEncoder().encode(value), account: "account.entitlement") }
    public func clear() throws { try keys.delete(account: "account.entitlement") }
}
