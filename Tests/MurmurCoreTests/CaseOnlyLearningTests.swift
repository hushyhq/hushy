import Foundation
import Testing
@testable import MurmurCore

@Suite struct CaseOnlyLearningTests {
    @Test func forgettingAppCasingDoesNotHideGlobalMemoryTerm() throws {
        let global = MemoryEntry(kind: .term, value: "Notes", heardAs: ["nots"], origin: .learned)
        let forgotten = LearnedItem(kind: .term, key: "notes", value: "Notes", appBundleID: "app.learned", status: .forgotten)
        let prepared = PersonBlockAssembler.Prepared(index: MemoryIndex(entries: [global]), app: "app.other",
            earlier: [], paused: false, learned: [forgotten])
        let block = try #require(PersonBlockAssembler.finish(prepared, transcript: "please open nots"))
        #expect(block.terms == ["Notes"])
    }

    @Test(arguments: ["notes", "mail", "music", "pages", "preview"])
    func commonWordNeedsTwoFixesAndStaysInApp(_ word: String) throws {
        let typed = word.capitalized
        let original = "please open \(word) for me"
        let fixed = "please open \(typed) for me"
        let evidence = TermEvidence(dictionary: [], screenTerms: [], appNames: [typed])
        func capture(_ id: Int64) throws -> CorrectionCapture {
            try #require(CorrectionCapture.deriveLatest(inserted: original, raw: original,
                snapshots: [.init(value: fixed, elapsed: 4), .init(value: fixed, elapsed: 8)],
                context: LearningContext(appBundleID: "app.learned"), dictationID: id, evidence: evidence,
                isCommonWord: { $0 == word }))
        }
        let first = Learner.observe(try capture(1), existing: [], knownTerms: [])
        #expect(first.first?.status == .candidate)
        #expect(first.first?.appBundleID == "app.learned")
        let second = Learner.observe(try capture(2), existing: first, knownTerms: [])
        #expect(second.first?.status == .active)
        let global = LearnedPersonalization.personalizer(dictionary: [], snippets: [], learned: second)
        #expect(global.apply(original).text == original)
        #expect(global.vocabulary.isEmpty)
        #expect(global.scoped(to: "app.learned").apply(original).text == fixed)
        #expect(global.scoped(to: "app.learned").scoped(to: "app.other").apply(original).text == original)
        let prepared = PersonBlockAssembler.Prepared(index: MemoryIndex(entries: []), app: "app.other",
                                                     earlier: [], paused: false, learned: second)
        #expect(PersonBlockAssembler.finish(prepared, transcript: original) == nil)
    }
}
