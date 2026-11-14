import CryptoKit
import Foundation
import Testing
@testable import MurmurCore

/// While the service is open every signed-in account has Pro (`Entitlements.proActiveUntil`),
/// from the cached answer in `OpenServiceStore`. A private defaults suite and in-memory account
/// stores: never the real defaults, Keychain or app folder.
@Suite("Open service entitlement", .serialized, .timeLimit(.minutes(1)))
struct OpenServiceEntitlementTests {
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    let day: TimeInterval = 86_400
    let person = AccountSession(userID: "person", accessToken: "access", refreshToken: "refresh", expiresAt: .distantFuture, email: "person@example.com")

    private struct Rig {
        let defaults: UserDefaults
        let accounts = AccountSessionStore(keys: InMemoryKeyStore())
        let entitlements = AccountEntitlementStore(keys: InMemoryKeyStore())
        var service: OpenServiceStore { OpenServiceStore(defaults: defaults) }

        init() {
            let name = "app.hushy.tests.openservice.\(UUID().uuidString)"
            defaults = UserDefaults(suiteName: name)!
            defaults.removePersistentDomain(forName: name)
            defaults.set(false, forKey: Entitlements.debugUnlockedKey)
        }

        func until(_ date: Date) -> Date? {
            Entitlements.proActiveUntil(now: date, defaults: defaults, accounts: accounts, entitlements: entitlements)
        }
        /// Whether the grant behind the former Pro is active (`Entitlements.proActiveUntil`). Every
        /// feature is free now; the grant is still mirrored for the MCP helper.
        func proActive(at date: Date) -> Bool {
            Entitlements.proActiveUntil(now: date, defaults: defaults, accounts: accounts, entitlements: entitlements) != nil
        }
    }

    @Test("a signed-in account has Pro while the last answer is open")
    func openMeansProForSignedInAccounts() throws {
        let rig = Rig()
        try rig.accounts.save(person)
        rig.service.record(open: true, now: now)
        #expect(rig.until(now) == now.addingTimeInterval(OpenServiceStore.offlineGrace))
        #expect(rig.proActive(at: now))
    }

    @Test("nobody signed in, no Pro, even when the service is open")
    func signedOutHasNothing() {
        let rig = Rig()
        rig.service.record(open: true, now: now)
        #expect(rig.until(now) == nil)
        #expect(!rig.proActive(at: now))
    }

    @Test("an account that signs out loses it at once, and gets it back on signing in")
    func signingOutEndsIt() throws {
        let rig = Rig()
        try rig.accounts.save(person)
        rig.service.record(open: true, now: now)
        #expect(rig.proActive(at: now))
        try rig.accounts.clear()
        #expect(!rig.proActive(at: now))
        try rig.accounts.save(person)
        #expect(rig.proActive(at: now))
    }

    @Test("no answer yet, or a closed one, means no free Pro")
    func closedOrUnknownIsFree() throws {
        let rig = Rig()
        try rig.accounts.save(person)
        #expect(rig.until(now) == nil)
        rig.service.record(open: false, now: now)
        #expect(rig.until(now) == nil)
        #expect(!rig.proActive(at: now))
    }

    @Test("a closed answer replaces an open one at once")
    func closedReplacesOpen() throws {
        let rig = Rig()
        try rig.accounts.save(person)
        rig.service.record(open: true, now: now)
        rig.service.record(open: false, now: now.addingTimeInterval(day))
        #expect(rig.until(now.addingTimeInterval(day)) == nil)
    }

    @Test("offline, the last open answer keeps Pro for thirty days, then it lapses")
    func offlineKeepsTheLastAnswerForAMonth() throws {
        let rig = Rig()
        try rig.accounts.save(person)
        rig.service.record(open: true, now: now)
        let end = now.addingTimeInterval(OpenServiceStore.offlineGrace)
        #expect(rig.until(now.addingTimeInterval(29 * day)) == end)
        #expect(rig.until(end.addingTimeInterval(-1)) == end)
        #expect(rig.until(end) == nil)
        // Reading it again later pushes the end out.
        rig.service.record(open: true, now: now.addingTimeInterval(20 * day))
        #expect(rig.until(end) == end.addingTimeInterval(20 * day))
    }

    @Test("a pasted invite code still works with no open service, and the later end wins")
    func pastedInviteCoexists() throws {
        let rig = Rig()
        try rig.accounts.save(person)
        let signer = Curve25519.Signing.PrivateKey()
        let code = try InviteCode.generate(InviteCode.Payload(grantDays: InviteCode.defaultGrantDays, issuedAt: now), privateKey: signer)
        _ = try InviteRedemptionStore.redeem(code, publicKey: signer.publicKey, now: now, defaults: rig.defaults).get()
        let inviteEnd = now.addingTimeInterval(TimeInterval(InviteCode.defaultGrantDays) * day)
        #expect(rig.until(now) == inviteEnd)
        rig.service.record(open: true, now: now)
        #expect(rig.until(now) == inviteEnd, "six months of invite outlast thirty days of open service")
        rig.service.record(open: false, now: now.addingTimeInterval(day))
        #expect(rig.until(now.addingTimeInterval(day)) == inviteEnd, "closing the service leaves the invite alone")
    }

    @Test("a paid account's end still counts beside the open service")
    func paidAccountCoexists() throws {
        let rig = Rig()
        try rig.accounts.save(person)
        let paidEnd = now.addingTimeInterval(365 * day)
        try rig.entitlements.save(AccountEntitlement(userID: person.userID, isPro: true, validUntil: paidEnd, verifiedAt: now))
        rig.service.record(open: true, now: now)
        #expect(rig.until(now) == paidEnd.addingTimeInterval(7 * day))
    }

    @Test("the answer is stored with its time, and an unreadable record reads as none")
    func storeRoundTrip() {
        let rig = Rig()
        #expect(rig.service.last() == nil)
        rig.service.record(open: true, now: now)
        #expect(rig.service.last() == OpenServiceAnswer(open: true, checkedAt: now))
        rig.defaults.set(Data("garbage".utf8), forKey: OpenServiceStore.key)
        #expect(rig.service.last() == nil)
        #expect(rig.service.activeUntil(now: now) == nil)
    }
}
