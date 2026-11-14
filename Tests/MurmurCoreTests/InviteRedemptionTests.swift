import CryptoKit
import Foundation
import Testing
@testable import MurmurCore

/// Redemption lifecycle (`InviteRedemptionStore`) and its effect on `Entitlements` and the MCP
/// snapshot. Uses a throwaway dev keypair and a private `UserDefaults` suite — never the user's
/// real defaults or key.
@Suite("Invite redemption", .serialized)
struct InviteRedemptionTests {
    let signer = Curve25519.Signing.PrivateKey()
    let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func freshDefaults() -> UserDefaults {
        let name = "app.hushy.tests.invites.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        return defaults
    }

    private static let grant = TimeInterval(InviteCode.defaultGrantDays) * 86_400

    private func code(redeemBy: Date? = nil, days: UInt16 = InviteCode.defaultGrantDays) throws -> String {
        try InviteCode.generate(InviteCode.Payload(grantDays: days, issuedAt: now, redeemBy: redeemBy), privateKey: signer)
    }

    @Test("a valid code is stored and Pro runs for exactly the default grant (182 days)")
    func lifecycle() throws {
        let defaults = freshDefaults()
        let outcome = try InviteRedemptionStore.redeem(try code(), publicKey: signer.publicKey, now: now, defaults: defaults).get()
        guard case .redeemed(let redemption) = outcome else { Issue.record("expected .redeemed, got \(outcome)"); return }
        #expect(redemption.redeemedAt == now)
        #expect(redemption.grantDays == 182)
        #expect(InviteRedemptionStore.current(defaults: defaults) == redemption)

        let lastSecond = now.addingTimeInterval(Self.grant - 1)
        let boundary = now.addingTimeInterval(Self.grant)
        #expect(InviteRedemptionStore.activeExpiry(now: now, defaults: defaults) == boundary)
        #expect(InviteRedemptionStore.activeExpiry(now: lastSecond, defaults: defaults) == boundary)
        #expect(InviteRedemptionStore.activeExpiry(now: boundary, defaults: defaults) == nil, "inactive at the instant")

        InviteRedemptionStore.clear(defaults: defaults)
        #expect(InviteRedemptionStore.current(defaults: defaults) == nil)
    }

    @Test("redeeming the same code again is a no-op that reports alreadyRedeemed")
    func idempotent() throws {
        let defaults = freshDefaults()
        let code = try code()
        let first = try InviteRedemptionStore.redeem(code, publicKey: signer.publicKey, now: now, defaults: defaults).get()
        let later = now.addingTimeInterval(100 * 86_400)
        let second = try InviteRedemptionStore.redeem(code, publicKey: signer.publicKey, now: later, defaults: defaults).get()
        #expect(second == .alreadyRedeemed(first.redemption))
        #expect(InviteRedemptionStore.current(defaults: defaults)?.redeemedAt == now, "not a fresh grant")
    }

    @Test("a second code only replaces the stored one if it lasts longer")
    func longerWins() throws {
        let defaults = freshDefaults()
        _ = try InviteRedemptionStore.redeem(try code(), publicKey: signer.publicKey, now: now, defaults: defaults).get()
        // A 30-day code redeemed a day later would end sooner: kept the six months.
        let shorter = try InviteRedemptionStore.redeem(
            try code(days: 30), publicKey: signer.publicKey, now: now.addingTimeInterval(86_400), defaults: defaults).get()
        guard case .keptLonger = shorter else { Issue.record("expected .keptLonger, got \(shorter)"); return }
        // A fresh default-length code redeemed 100 days in ends later: replaces.
        let later = now.addingTimeInterval(100 * 86_400)
        let renewal = try InviteRedemptionStore.redeem(try code(), publicKey: signer.publicKey, now: later, defaults: defaults).get()
        guard case .redeemed(let record) = renewal else { Issue.record("expected .redeemed, got \(renewal)"); return }
        #expect(record.redeemedAt == later)
    }

    @Test("errors pass through: tampered, expired, no key")
    func errors() throws {
        let defaults = freshDefaults()
        var chars = Array(try code())
        chars[8] = chars[8] == "A" ? "B" : "A"
        #expect(InviteRedemptionStore.redeem(String(chars), publicKey: signer.publicKey, now: now, defaults: defaults)
            == .failure(.badSignature))
        let deadline = now.addingTimeInterval(-1)
        #expect(InviteRedemptionStore.redeem(try code(redeemBy: deadline), publicKey: signer.publicKey, now: now, defaults: defaults)
            == .failure(.expired(redeemBy: deadline)))
        #expect(InviteRedemptionStore.redeem(try code(), publicKey: nil, now: now, defaults: defaults) == .failure(.noPublicKey))
        #expect(InviteRedemptionStore.current(defaults: defaults) == nil, "nothing stored on failure")
    }

    @Test("Entitlements turn Pro features on for the grant and off after it")
    func entitlementOnAndOff() throws {
        let defaults = freshDefaults()
        defaults.set(false, forKey: Entitlements.debugUnlockedKey)
        #expect(Entitlements.proActiveUntil(now: now, defaults: defaults) == nil)

        _ = try InviteRedemptionStore.redeem(try code(), publicKey: signer.publicKey, now: now, defaults: defaults).get()
        let expiry = now.addingTimeInterval(Self.grant)
        #expect(Entitlements.proActiveUntil(now: now, defaults: defaults) == expiry)
        #expect(Entitlements.proActiveUntil(now: expiry.addingTimeInterval(-1), defaults: defaults) == expiry)
        #expect(Entitlements.proActiveUntil(now: expiry, defaults: defaults) == nil)
    }

    @Test("has(_:) follows redemption in injected defaults, independent of the debug override")
    func hasFollowsRedemption() throws {
        let defaults = freshDefaults()
        defaults.set(false, forKey: Entitlements.debugUnlockedKey)
        #expect(Entitlements.proActiveUntil(now: now, defaults: defaults) == nil)

        _ = try InviteRedemptionStore.redeem(try code(), publicKey: signer.publicKey, now: now, defaults: defaults).get()
        #expect(Entitlements.proActiveUntil(now: now, defaults: defaults) != nil)
        #expect(Entitlements.proActiveUntil(now: now.addingTimeInterval(Self.grant), defaults: defaults) == nil, "off after the grant")
        #expect(Entitlements.has(.voiceActions, now: now.addingTimeInterval(Self.grant), defaults: defaults), "voice actions stay free")
    }

    @Test("the invite expiry mirrors into the MCP snapshot and expires there too")
    func mcpSnapshot() throws {
        let defaults = freshDefaults()
        defaults.set(false, forKey: Entitlements.debugUnlockedKey)
        _ = try InviteRedemptionStore.redeem(try code(), publicKey: signer.publicKey, now: now, defaults: defaults).get()
        let store = try Store()
        try store.writeProSnapshot(activeUntil: Entitlements.proActiveUntil(now: now, defaults: defaults))
        let expiry = now.addingTimeInterval(Self.grant)
        #expect(try store.proSnapshotActiveUntil() == expiry)
    }
}
