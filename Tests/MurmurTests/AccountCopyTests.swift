import Foundation
import Testing
@testable import Murmur

@Suite("Account pane copy")
struct AccountCopyTests {
    @Test("the price line is the founder's approved wording, word for word")
    func priceLine() {
        #expect(AccountCopy.priceLine == "What runs on your Mac stays free; if we ever charge, it’s for things we host.")
    }

    @Test("a founding member sees the badge and the pledge; everyone else sees Free and the price line")
    func lines() {
        #expect(AccountCopy.badge(isFoundingMember: true) == "Founding member")
        #expect(AccountCopy.badge(isFoundingMember: false) == "Free")
        #expect(AccountCopy.lines(isFoundingMember: true) == [AccountCopy.priceLine, AccountCopy.foundingPledge])
        #expect(AccountCopy.lines(isFoundingMember: false) == [AccountCopy.priceLine])
    }

    @Test("nothing on the pane names Pro, a price or an upgrade")
    func noPaidWords() {
        let all = [AccountCopy.priceLine, AccountCopy.foundingPledge, AccountCopy.badge(isFoundingMember: true), AccountCopy.badge(isFoundingMember: false)]
        for line in all {
            #expect(line.range(of: #"\bPro\b|\$|Upgrade|See plans|Free plan"#, options: .regularExpression) == nil, "\(line)")
        }
    }

    @Test("returning from browser refreshes once per minute")
    func returnRefresh() {
        let now = Date(timeIntervalSince1970: 1_820_000_000)
        #expect(PlanReturnRefresh.shouldRefresh(last: nil, now: now, signedIn: true))
        #expect(!PlanReturnRefresh.shouldRefresh(last: now.addingTimeInterval(-30), now: now, signedIn: true))
        #expect(PlanReturnRefresh.shouldRefresh(last: now.addingTimeInterval(-60), now: now, signedIn: true))
        #expect(!PlanReturnRefresh.shouldRefresh(last: nil, now: now, signedIn: false))
    }
}
