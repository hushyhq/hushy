import Foundation
import GRDB
import Testing
@testable import MurmurCore

@Suite("Edit learning requires style consent")
struct EditLearningConsentTests {
    @Test func repeatedHabitWaitsForChoiceAndNeverReoffersAfterDismissal() throws {
        var items: [LearnedItem] = []
        for id in 1...3 {
            let capture = CorrectionCapture(dictationID: Int64(id), appBundleID: "app.mail", capturedAt: Date(), events: [
                CorrectionEvent(kind: .formatting, before: "Hello.", after: "hello.")])
            items = Learner.observe(capture, existing: items, knownTerms: [])
        }
        let offered = try #require(items.first)
        #expect(offered.isReadySuggestion)
        #expect(offered.status == .candidate)
        #expect(PreferenceHints.from(items, bundleID: "app.mail").isEmpty)
        let accepted = Learner.confirm(offered)
        #expect(PreferenceHints.from([accepted], bundleID: "app.mail").prefersLowercase)
        #expect(PreferenceHints.from([accepted], bundleID: "app.other").isEmpty)
        let dismissed = Learner.forget(offered)
        let again = CorrectionCapture(dictationID: 4, appBundleID: "app.mail", capturedAt: Date(), events: [
            CorrectionEvent(kind: .formatting, before: "Hello.", after: "hello.")])
        #expect(Learner.observe(again, existing: [dismissed], knownTerms: []).isEmpty)
    }

    @Test func legacyUnconfirmedActiveHabitDoesNotApply() {
        let old = LearnedItem(kind: .styleSignal, key: "format:lowercased", value: "format:lowercased",
                              appBundleID: "app.mail", status: .active, confidence: 1)
        #expect(PreferenceHints.from([old], bundleID: "app.mail").isEmpty)
    }

    @Test func memoryOffContainsOnlyLearnedTermsAndApprovedStyle() throws {
        let store = try Store()
        try store.writer.write { db in
            var term = LearnedItem(kind: .term, key: "veloria", value: "Veloria", heardAs: ["Velorria"], status: .active)
            try term.insert(db)
            var style = LearnedItem(kind: .styleSignal, key: "format:noGreeting", value: "format:noGreeting",
                                    appBundleID: "app.mail", status: .active, confirmed: true)
            try style.insert(db)
        }
        let prepared = try PersonBlockAssembler.prepareLearned(history: store, app: "app.mail")
        let block = try #require(PersonBlockAssembler.finish(prepared, transcript: "ask Velorria"))
        #expect(block.terms == ["Veloria"])
        #expect(block.style == "No greeting.")
        #expect(block.profile == nil)
        #expect(block.earlier.isEmpty)
        #expect(block.edits.isEmpty)
        #expect(block.screen == nil)
        #expect(block.usedLines == 2)
    }
}
