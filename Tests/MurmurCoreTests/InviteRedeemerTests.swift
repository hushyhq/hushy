import CryptoKit
import Foundation
import Testing
@testable import MurmurCore

/// The one redeem-and-describe path Settings and onboarding share. Throwaway key pair and a
/// private defaults suite: never the real key, never standard defaults.
@Suite("Invite redeemer", .serialized, .timeLimit(.minutes(1)))
struct InviteRedeemerTests {
    let signer = Curve25519.Signing.PrivateKey()
    let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func freshDefaults() -> UserDefaults {
        let name = "app.hushy.tests.redeemer.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        return defaults
    }

    private func code(redeemBy: Date? = nil, days: UInt16 = InviteCode.defaultGrantDays) throws -> String {
        try InviteCode.generate(InviteCode.Payload(grantDays: days, issuedAt: now, redeemBy: redeemBy), privateKey: signer)
    }

    private func redeem(_ text: String, defaults: UserDefaults, at date: Date? = nil) -> InviteRedeemResult? {
        InviteRedeemer.redeem(text, publicKey: signer.publicKey, now: date ?? now, defaults: defaults)
    }

    @Test("a valid code redeems with the right end date and stores it")
    func valid() throws {
        let defaults = freshDefaults()
        let result = redeem(try code(), defaults: defaults)
        let until = now.addingTimeInterval(TimeInterval(InviteCode.defaultGrantDays) * 86_400)
        #expect(result == .redeemed(until: until))
        #expect(result?.isSuccess == true)
        #expect(result?.until == until)
        #expect(InviteRedemptionStore.activeExpiry(now: now, defaults: defaults) == until)
    }

    @Test("surrounding spaces and newlines are ignored")
    func trimmed() throws {
        let result = redeem("  \(try code())\n", defaults: freshDefaults())
        #expect(result?.isSuccess == true)
    }

    @Test("a blank entry does nothing")
    func blank() {
        #expect(redeem("   ", defaults: freshDefaults()) == nil)
    }

    @Test("a malformed code gives the store's own sentence and stores nothing")
    func malformed() {
        let defaults = freshDefaults()
        let result = redeem("not a code", defaults: defaults)
        #expect(result == .failed(.malformed))
        #expect(result?.message == InviteCode.Error.malformed.message)
        #expect(result?.isSuccess == false)
        #expect(InviteRedemptionStore.current(defaults: defaults) == nil)
    }

    @Test("a code signed by another key is 'isn't valid'")
    func wrongKey() throws {
        let other = Curve25519.Signing.PrivateKey()
        let foreign = try InviteCode.generate(InviteCode.Payload(grantDays: 182, issuedAt: now), privateKey: other)
        #expect(redeem(foreign, defaults: freshDefaults()) == .failed(.badSignature))
    }

    @Test("an expired code says when it expired")
    func expired() throws {
        let by = now.addingTimeInterval(-86_400)
        let result = redeem(try code(redeemBy: by), defaults: freshDefaults())
        #expect(result == .failed(.expired(redeemBy: by)))
        #expect(result?.message.contains("expired") == true)
    }

    @Test("redeeming the same code twice reports it was already redeemed, with the original end date")
    func alreadyRedeemed() throws {
        let defaults = freshDefaults()
        let text = try code()
        guard case .redeemed(let until)? = redeem(text, defaults: defaults) else { Issue.record("first redeem failed"); return }
        let again = redeem(text, defaults: defaults, at: now.addingTimeInterval(86_400))
        #expect(again == .alreadyRedeemed(until: until))
        #expect(again?.message.contains("already redeemed") == true)
    }

    @Test("a shorter code does not shorten an active grant")
    func keptLonger() throws {
        let defaults = freshDefaults()
        guard case .redeemed(let until)? = redeem(try code(), defaults: defaults) else { Issue.record("first redeem failed"); return }
        let shorter = redeem(try code(days: 30), defaults: defaults, at: now.addingTimeInterval(86_400))
        #expect(shorter == .keptLonger(until: until))
    }

    @Test("a build without a public key says codes aren't enabled")
    func noKey() throws {
        let result = InviteRedeemer.redeem(try code(), publicKey: nil, now: now, defaults: freshDefaults())
        #expect(result == .failed(.noPublicKey))
    }

    @Test("no sentence promises Pro any more")
    func noProWording() throws {
        let defaults = freshDefaults()
        let text = try code()
        let results = [redeem(text, defaults: defaults), redeem(text, defaults: defaults), redeem(try code(days: 30), defaults: defaults)]
        for result in results.compactMap({ $0 }) { #expect(!result.message.contains("Pro"), "\(result.message)") }
    }
}

@Suite("Invite grant wording", .timeLimit(.minutes(1)))
struct InviteGrantWordingTests {
    @Test("the default grant reads as six months")
    func sixMonths() {
        #expect(InviteCode.defaultGrantDays == 182)
        #expect(InviteCode.defaultGrantDescription == "six months")
    }
}
