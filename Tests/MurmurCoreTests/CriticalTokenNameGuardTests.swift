import Foundation
import Testing
@testable import MurmurCore

/// The name check in `CriticalTokenGuard` must allow a name to move to the start of the sentence
/// when a leading filler is removed, and still reject a name that was changed or dropped.
@Suite("CriticalTokenGuard names after a leading filler")
struct CriticalTokenNameGuardTests {
    @Test("removing a capitalised leading filler before a name is not a changed name",
          arguments: [
              ("So Marcus will present the chart on Wednesday.", "Marcus will present the chart on Wednesday."),
              ("Okay so Aisha will handle the customer emails.", "Aisha will handle the customer emails."),
              ("Basically Jamal wants to discuss the benefits package.", "Jamal wants to discuss the benefits package."),
              ("Like The farmers market on Maple Street has strawberries.", "The farmers market on Maple Street has strawberries."),
              ("Yeah so Priya and Tom are out on Friday.", "Priya and Tom are out on Friday."),
          ])
    func leadingFillerRemoved(draft: String, answer: String) {
        #expect(CriticalTokenGuard.violation(answer: answer, draft: draft) == nil)
    }

    @Test("a changed or dropped name is still rejected")
    func realNameChanges() {
        #expect(CriticalTokenGuard.violation(answer: "Marcos will present the chart.", draft: "So Marcus will present the chart.") == "changed name")
        #expect(CriticalTokenGuard.violation(answer: "Send the invoice to Sara.", draft: "Send the invoice to Sarah.") == "changed name")
        #expect(CriticalTokenGuard.violation(answer: "Will present the chart.", draft: "So Marcus will present the chart.") == "changed name")
        #expect(CriticalTokenGuard.violation(answer: "Loop in the design team.", draft: "Loop in Priya and the design team.") == "changed name")
    }

    @Test("the whole guard stack accepts the filler removal (the pair that used to be rejected)")
    func trainingPairNowAccepted() {
        let result = TrainingPairCheck.check(
            raw: "so marcus will present the revenue chart at the summit on wednesday",
            target: "Marcus will present the revenue chart at the summit on Wednesday.", level: .clean)
        #expect(result.rejection == nil)
    }

    @Test("sentence-initial capitals count only on the answer side")
    func nameSets() {
        #expect(CriticalTokenGuard.capitalizedNames(in: "Marcus called Priya.") == ["priya"])
        #expect(CriticalTokenGuard.capitalizedNames(in: "Marcus called Priya.", includingSentenceInitial: true) == ["marcus", "priya"])
    }
}
