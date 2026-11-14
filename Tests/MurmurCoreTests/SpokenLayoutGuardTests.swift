import Testing
@testable import MurmurCore

@Suite("Spoken layout guard")
struct SpokenLayoutGuardTests {
    @Test("restores flattened breaks without changing words, punctuation or case")
    func restoresFlattenedBreaks() {
        #expect(SpokenLayoutGuard.restoringFlattenedBreaks(
            answer: "Alpha is ready. Beta is next. Gamma is blocked.",
            draft: "Alpha is ready\nBeta is next\n\nGamma is blocked."
        ) == "Alpha is ready.\nBeta is next.\n\nGamma is blocked.")
        #expect(SpokenLayoutGuard.restoringFlattenedBreaks(
            answer: "Ship now. Ship now. Ship later.", draft: "Ship now\nShip now\n\nShip later."
        ) == "Ship now.\nShip now.\n\nShip later.")
        #expect(SpokenLayoutGuard.restoringFlattenedBreaks(
            answer: "مرحبا الآن. نراك غداً.", draft: "مرحبا الآن\nنراك غداً."
        ) == "مرحبا الآن.\nنراك غداً.")
    }

    @Test("does not reconstruct changed words, moved breaks or ambiguous delimiters")
    func refusesAmbiguousRestoration() {
        let draft = "Alpha is ready\nBeta is next."
        for answer in ["Alpha is ready. Beta is delayed.", "Beta is next. Alpha is ready.",
                       "Alpha\nis ready. Beta is next.", "Alpha is ready. (Beta is next.)"] {
            #expect(SpokenLayoutGuard.restoringFlattenedBreaks(answer: answer, draft: draft) == answer)
            #expect(SpokenLayoutGuard.violation(answer: answer, draft: draft) == SpokenLayoutGuard.reason)
        }
    }

    @Test("keeps explicit line and paragraph breaks in their original positions")
    func keepsBreakPositions() {
        let draft = "The trial ends on Friday\n\nBilling starts Monday."
        #expect(SpokenLayoutGuard.violation(answer: draft, draft: draft) == nil)
        #expect(SpokenLayoutGuard.violation(
            answer: "The trial ends on Friday. Billing starts Monday.", draft: draft
        ) == SpokenLayoutGuard.reason)
        #expect(SpokenLayoutGuard.violation(
            answer: "The trial ends\n\nFriday. Billing starts Monday.", draft: draft
        ) == SpokenLayoutGuard.reason)
    }

    @Test("does not impose layout on a draft without explicit breaks")
    func noBreakInDraft() {
        #expect(SpokenLayoutGuard.violation(
            answer: "The trial ends on Friday.\nBilling starts Monday.",
            draft: "The trial ends on Friday. Billing starts Monday."
        ) == nil)
    }
}
