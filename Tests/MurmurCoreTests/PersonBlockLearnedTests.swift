import Foundation
import Testing
@testable import MurmurCore

@Suite("Learned terms and habits in cleanup context")
struct PersonBlockLearnedTests {
    @Test func activeTermsRecalledAndDeduplicated() throws {
        let memory = MemoryIndex(entries: [MemoryEntry(kind: .term, value: "Veloria")])
        let learned = [LearnedItem(kind: .term, key: "veloria", value: "Veloria", heardAs: ["Velorria"], status: .active),
                       LearnedItem(kind: .term, key: "nerula", value: "Nerula", status: .forgotten)]
        let prepared = PersonBlockAssembler.Prepared(index: memory, app: "app.test", earlier: [], paused: false, learned: learned)
        let block = try #require(PersonBlockAssembler.finish(prepared, transcript: "ask Velorria and Nerula"))
        #expect(block.terms == ["Veloria"])
    }

    @Test func styleIsAppScopedAndManualNoteWins() throws {
        let items = [LearnedItem(kind: .styleSignal, key: "format:noGreeting", value: "format:noGreeting", appBundleID: "app.test", status: .active, confirmed: true)]
        let index = MemoryIndex(entries: [MemoryEntry(kind: .style, value: "Always include a greeting", appBundleID: "app.test")])
        let prepared = PersonBlockAssembler.Prepared(index: index, app: "app.test", earlier: [], paused: false, learned: items)
        #expect(PersonBlockAssembler.finish(prepared, transcript: "hello")?.style == "Always include a greeting")
        let other = PersonBlockAssembler.Prepared(index: index, app: "app.other", earlier: [], paused: false, learned: items)
        #expect(PersonBlockAssembler.finish(other, transcript: "hello") == nil)
    }

    @Test func scopedTermsReachTheModelOnlyWhereTheyApply() throws {
        let mailOnly = LearnedItem(kind: .term, key: "veloria", value: "Veloria", heardAs: ["Velorria"], status: .active,
                                   scope: .app("com.apple.mail"))
        let workChat = LearnedItem(kind: .term, key: "nerula", value: "Nerula", heardAs: ["Nerulla"], status: .active,
                                   scope: .category(.workMessages))
        let learned = [mailOnly, workChat]
        func terms(in app: String) -> [String] {
            let prepared = PersonBlockAssembler.Prepared(index: MemoryIndex(entries: []), app: app, earlier: [], paused: false, learned: learned)
            return PersonBlockAssembler.finish(prepared, transcript: "ask Velorria and Nerulla")?.terms ?? []
        }
        #expect(terms(in: "com.apple.mail") == ["Veloria"])
        #expect(terms(in: "com.tinyspeck.slackmacgap") == ["Nerula"])
        #expect(terms(in: "com.apple.notes").isEmpty)
    }

    @Test func pausedMemoryProducesNoBlock() {
        let learned = [LearnedItem(kind: .term, key: "veloria", value: "Veloria", status: .active)]
        let prepared = PersonBlockAssembler.Prepared(index: MemoryIndex(entries: []), app: "app.test", earlier: [], paused: true, learned: learned)
        #expect(PersonBlockAssembler.finish(prepared, transcript: "Veloria") == nil)
    }
}
