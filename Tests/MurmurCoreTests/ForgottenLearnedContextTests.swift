import Testing
@testable import MurmurCore

@Suite struct ForgottenLearnedContextTests {
    @Test func importedTermDoesNotSurviveForgetInLearnedWords() {
        let index = MemoryIndex(entries: [MemoryEntry(kind: .term, value: "Veloria", origin: .learned)])
        let forgotten = LearnedItem(kind: .term, key: "veloria", value: "Veloria", status: .forgotten)
        let prepared = PersonBlockAssembler.Prepared(index: index, app: "app.test", earlier: [], paused: false, learned: [forgotten])
        #expect(PersonBlockAssembler.finish(prepared, transcript: "ask Veloria") == nil)
    }

    @Test func punctuationKeysUseTheSameMemoryNormalization() {
        let index = MemoryIndex(entries: [MemoryEntry(kind: .term, value: "foo.bar", origin: .learned)])
        let forgotten = LearnedItem(kind: .term, key: "foo.bar", value: "foo.bar", status: .forgotten)
        let prepared = PersonBlockAssembler.Prepared(index: index, app: "app.test", earlier: [], paused: false, learned: [forgotten])
        #expect(PersonBlockAssembler.finish(prepared, transcript: "open foo.bar") == nil)
    }

    @Test func explicitMemoryTermSurvivesForgetOfAutomaticLearning() {
        let index = MemoryIndex(entries: [MemoryEntry(kind: .term, value: "Veloria", origin: .typed)])
        let forgotten = LearnedItem(kind: .term, key: "veloria", value: "Veloria", status: .forgotten)
        let prepared = PersonBlockAssembler.Prepared(index: index, app: "app.test", earlier: [], paused: false, learned: [forgotten])
        #expect(PersonBlockAssembler.finish(prepared, transcript: "ask Veloria")?.terms == ["Veloria"])
    }
}
