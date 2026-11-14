import CryptoKit
import Foundation

/// A locally stored invite-code redemption (founder-approved 2026-09-26, docs/guide/INVITES.md).
/// Pro is active from `redeemedAt` until `redeemedAt + grantDays`; the code id is kept so
/// redeeming the same code again is a no-op rather than a fresh year. Kept separate from any
/// future paid licence: `Entitlements.has(_:)` asks this store *and* (later) the licence, so the
/// two can coexist.
public struct InviteRedemption: Codable, Equatable, Sendable {
    public let codeID: String
    public let redeemedAt: Date
    public let grantDays: Int

    public init(codeID: String, redeemedAt: Date, grantDays: Int) {
        self.codeID = codeID
        self.redeemedAt = redeemedAt
        self.grantDays = grantDays
    }

    public var expiresAt: Date { redeemedAt.addingTimeInterval(TimeInterval(grantDays) * 86_400) }

    /// Active strictly before `expiresAt`: at exactly `redeemedAt + grantDays` the grant is over.
    public func isActive(now: Date) -> Bool { now < expiresAt }
}

/// Persists the single current `InviteRedemption` as JSON under `UserDefaults` key
/// `pro.inviteRedemption`. One record is enough: a later code only replaces the stored one if it
/// would end Pro later, so redeeming an older or shorter code never shortens an active grant.
/// `Entitlements.has(_:)` reads `activeExpiry(now:)`; the app mirrors it into the store for the
/// MCP helper via `AppModel.refreshEntitlementSnapshot()`.
public enum InviteRedemptionStore {
    public static let key = "pro.inviteRedemption"

    /// What a redeem call did.
    public enum Outcome: Equatable, Sendable {
        /// Stored; Pro runs until `redemption.expiresAt`.
        case redeemed(InviteRedemption)
        /// This exact code was already redeemed on this Mac; nothing changed.
        case alreadyRedeemed(InviteRedemption)
        /// The code is valid, but an active redemption already lasts at least as long; kept it.
        case keptLonger(InviteRedemption)

        public var redemption: InviteRedemption {
            switch self {
            case .redeemed(let r), .alreadyRedeemed(let r), .keptLonger(let r): r
            }
        }
    }

    public static func current(defaults: UserDefaults = .standard) -> InviteRedemption? {
        guard let data = defaults.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(InviteRedemption.self, from: data)
    }

    /// When the current invite's Pro lapses, or `nil` if none is active at `now`.
    public static func activeExpiry(now: Date = Date(), defaults: UserDefaults = .standard) -> Date? {
        guard let redemption = current(defaults: defaults), redemption.isActive(now: now) else { return nil }
        return redemption.expiresAt
    }

    public static func save(_ redemption: InviteRedemption, defaults: UserDefaults = .standard) {
        guard let data = try? JSONEncoder().encode(redemption) else { return }
        defaults.set(data, forKey: key)
    }

    public static func clear(defaults: UserDefaults = .standard) {
        defaults.removeObject(forKey: key)
    }

    /// Verifies `code` against `publicKey` (`InviteCode.verify`) and stores the redemption.
    /// Idempotent: the same code id redeemed twice reports `.alreadyRedeemed` with the original
    /// record, never a fresh year.
    public static func redeem(
        _ code: String, publicKey: Curve25519.Signing.PublicKey?, now: Date = Date(), defaults: UserDefaults = .standard
    ) -> Result<Outcome, InviteCode.Error> {
        guard let publicKey else { return .failure(.noPublicKey) }
        switch InviteCode.verify(code, publicKey: publicKey, now: now) {
        case .failure(let error):
            return .failure(error)
        case .success(let payload):
            let existing = current(defaults: defaults)
            if let existing, existing.codeID == payload.codeIDHex { return .success(.alreadyRedeemed(existing)) }
            let fresh = InviteRedemption(codeID: payload.codeIDHex, redeemedAt: now, grantDays: Int(payload.grantDays))
            if let existing, existing.isActive(now: now), existing.expiresAt >= fresh.expiresAt {
                return .success(.keptLonger(existing))
            }
            save(fresh, defaults: defaults)
            return .success(.redeemed(fresh))
        }
    }
}
