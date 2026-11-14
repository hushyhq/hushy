import Foundation
import Testing
@testable import MurmurCore

@Suite("Founding members")
struct FoundingMemberTests {
    private func freshDefaults() -> UserDefaults {
        let name = "app.hushy.tests.founding.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        return defaults
    }

    private let before = Date(timeIntervalSince1970: 1_795_000_000)  // 18 November 2026
    private let after = Date(timeIntervalSince1970: 1_797_000_000)   // 11 December 2026

    @Test("the cut-off is 1 December 2026 at 12:00 UTC: 30 November counts in every time zone")
    func cutoff() {
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(identifier: "UTC")!
        let parts = utc.dateComponents([.year, .month, .day, .hour, .minute], from: FoundingMember.cutoff)
        #expect(parts.year == 2026 && parts.month == 12 && parts.day == 1 && parts.hour == 12 && parts.minute == 0)
        var lastPlace = Calendar(identifier: .gregorian)
        lastPlace.timeZone = TimeZone(secondsFromGMT: -12 * 3600)!
        let endOf30th = lastPlace.date(from: DateComponents(year: 2026, month: 11, day: 30, hour: 23, minute: 59))!
        #expect(endOf30th < FoundingMember.cutoff)
    }

    @Test("signed out is never a member")
    func signedOut() {
        #expect(!FoundingMember(defaults: freshDefaults()).isMember(signedIn: false, now: before))
    }

    @Test("before the cut-off every signed-in account is a founding member")
    func beforeCutoff() {
        #expect(FoundingMember(defaults: freshDefaults()).isMember(signedIn: true, now: before))
    }

    @Test("after the cut-off, membership is the first sign-in this Mac saw, and it never moves")
    func firstSignIn() {
        let early = FoundingMember(defaults: freshDefaults())
        early.noteSignedIn(now: before)
        early.noteSignedIn(now: after)
        #expect(early.firstSignedInAt == before)
        #expect(early.isMember(signedIn: true, now: after))

        let late = FoundingMember(defaults: freshDefaults())
        late.noteSignedIn(now: after)
        #expect(!late.isMember(signedIn: true, now: after))
        #expect(!FoundingMember(defaults: freshDefaults()).isMember(signedIn: true, now: after), "nothing recorded")
    }

    @Test("an invite code redeemed before the cut-off also marks a founding member")
    func invite() {
        let defaults = freshDefaults()
        InviteRedemptionStore.save(InviteRedemption(codeID: "c0de", redeemedAt: before, grantDays: 182), defaults: defaults)
        let member = FoundingMember(defaults: defaults)
        member.noteSignedIn(now: after)
        #expect(member.isMember(signedIn: true, now: after))
    }
}
