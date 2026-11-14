import Testing
@testable import MurmurCore

@Suite("CapitalizedNameGuard")
struct CapitalizedNameGuardTests {
    @Test("a paragraph break does not turn adjacent words into a changed name")
    func paragraphBreakDoesNotJoinNameTokens() {
        let draft = "The trial ends on Friday\n\nBilling starts Monday."
        let answer = "The trial ends on Friday. Billing starts Monday."

        #expect(!CapitalizedNameGuard.changedNames(answer: answer, draft: draft))
    }

    @Test("a name moved to sentence initial still counts as preserved")
    func movedNameAtSentenceInitialIsPreserved() {
        let draft = "So Marcus will present the revised plan."
        let answer = "Marcus will present the revised plan."

        #expect(!CapitalizedNameGuard.changedNames(answer: answer, draft: draft))
    }

    @Test("a genuinely changed capitalized name is still detected")
    func changedNameIsDetected() {
        let draft = "Send it to Sarah tomorrow."
        let answer = "Send it to Karen tomorrow."

        #expect(CapitalizedNameGuard.changedNames(answer: answer, draft: draft))
    }

    @Test("sentence-initial words in the draft remain ambiguous")
    func sentenceInitialDraftWordIsNotAssumedToBeAName() {
        let draft = "Billing starts Monday."
        let answer = "Invoices start Monday."

        #expect(!CapitalizedNameGuard.changedNames(answer: answer, draft: draft))
    }
}
