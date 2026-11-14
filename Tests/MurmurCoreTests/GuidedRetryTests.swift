import Foundation
import Synchronization
import Testing
@testable import MurmurCore

/// A check that objects because the model's answer left something out puts that span back when it can, and
/// otherwise tells the model what was lost and asks once more. The plain text stands only if that fails too.
@Suite("Guided retry after a check objects", .timeLimit(.minutes(1)), .serialized)
struct GuidedRetryTests {
    private let spoken = "the demo failed on plan c since the staging key had expired so we should write that down for Thursday"

    private func cleaner(_ model: any LanguageModel, repairsSpans: Bool = true, asksAgain: Bool = true) -> SmartCleaner {
        SmartCleaner(
            budget: .seconds(6), correctionBudget: .seconds(6), polishedBudget: .seconds(6), segmentBudget: .seconds(6),
            model: model, health: ModelHealth(), repairsSpans: repairsSpans, asksAgain: asksAgain)
    }

    private func run(_ cleaner: SmartCleaner) async -> SmartCleaner.Output {
        await cleaner.clean(spoken, options: CleanupOptions(level: .polished))
    }

    @Test("a dropped letter is put back without asking again when it can be")
    func spanPutsItBack() async {
        let model = NoteModel(first: { $0.replacingOccurrences(of: "plan c", with: "the plan") }, afterNote: { $0 })
        let output = await run(cleaner(model))
        #expect(output.text.contains("plan c"))
        #expect(output.groups.first?.askedAgain == AskedAgain.none)
        #expect((output.groups.first?.repairedSpans ?? 0) > 0)
        #expect(model.calls == 1)
    }

    @Test("when nothing can be put back alone the model is told what it lost and asked once more")
    func askedAgainRescues() async {
        let model = NoteModel(first: { $0.replacingOccurrences(of: "plan c", with: "the plan") }, afterNote: { $0 })
        let output = await run(cleaner(model, repairsSpans: false))
        #expect(output.text.contains("plan c"))
        #expect(output.groups.first?.askedAgain == .passed)
        #expect(output.groups.first?.outcome == .used)
        #expect(model.calls == 2)
        #expect(model.lastNote?.contains("\"c\"") == true)
    }

    @Test("a second answer that fails the same check falls back to the plain text")
    func askedAgainFallsBack() async {
        let model = NoteModel(first: { $0.replacingOccurrences(of: "plan c", with: "the plan") },
                              afterNote: { $0.replacingOccurrences(of: "plan c", with: "the plan") })
        let output = await run(cleaner(model, repairsSpans: false))
        #expect(output.groups.first?.askedAgain == .sameCheck)
        #expect(output.groups.first?.outcome == .rejectedByGuard)
        #expect(output.text.contains("plan c"))
        #expect(model.calls == 2)
    }

    @Test("a failing second call falls back and is counted")
    func askedAgainFails() async {
        let model = NoteModel(first: { $0.replacingOccurrences(of: "plan c", with: "the plan") }, afterNote: { $0 }, failsAfterNote: true)
        let output = await run(cleaner(model, repairsSpans: false))
        #expect(output.groups.first?.askedAgain == .failed)
        #expect(output.text.contains("plan c"))
    }

    @Test("a second answer that fails a different check is told apart from one that fails the same check")
    func askedAgainOtherCheck() async {
        let model = NoteModel(first: { $0.replacingOccurrences(of: "plan c", with: "the plan") },
                              afterNote: { $0.replacingOccurrences(of: "Thursday", with: "Friday") })
        let output = await run(cleaner(model, repairsSpans: false))
        #expect(output.groups.first?.askedAgain == .otherCheck)
        #expect(output.groups.first?.outcome == .rejectedByGuard)
    }

    @Test("a second call that does not answer in time is counted as timed out")
    func askedAgainTimesOut() async {
        let model = NoteModel(first: { $0.replacingOccurrences(of: "plan c", with: "the plan") }, afterNote: { $0 }, sleepsAfterNote: true)
        let slow = SmartCleaner(
            budget: .milliseconds(700), correctionBudget: .milliseconds(700), polishedBudget: .milliseconds(700),
            segmentBudget: .milliseconds(700), model: model, health: ModelHealth(), repairsSpans: false)
        let output = await run(slow)
        #expect(output.groups.first?.askedAgain == .timedOut)
        #expect(output.text.contains("plan c"))
    }

    @Test("with no time left in the group the model is not asked, and that is counted")
    func askedAgainNoTime() async {
        let model = NoteModel(first: { $0.replacingOccurrences(of: "plan c", with: "the plan") }, afterNote: { $0 })
        let tight = SmartCleaner(
            budget: .seconds(6), correctionBudget: .seconds(6), polishedBudget: .seconds(6), segmentBudget: .seconds(6),
            model: model, health: ModelHealth(), repairsSpans: false, groupCeiling: .milliseconds(1_500))
        let output = await run(tight)
        #expect(output.groups.first?.askedAgain == .noTime)
        #expect(model.calls == 1)
    }

    @Test("the second ask goes to the second-opinion model when it is switched on for it")
    func askedAgainOnTheSecondModel() async {
        let first = NoteModel(first: { $0.replacingOccurrences(of: "plan c", with: "the plan") }, afterNote: { $0 })
        let second = NoteModel(first: { $0 }, afterNote: { $0 })
        let both = SmartCleaner(
            budget: .seconds(6), correctionBudget: .seconds(6), polishedBudget: .seconds(6), segmentBudget: .seconds(6),
            model: first, health: ModelHealth(), repairsSpans: false, retriesOnSecondOpinion: true, secondOpinion: second)
        let output = await run(both)
        #expect(output.groups.first?.askedAgain == .passed)
        #expect(first.lastNote == nil)
        #expect(second.lastNote?.contains("\"c\"") == true)
    }

    @Test("without the switch the second ask stays on the first model")
    func askedAgainOnTheFirstModel() async {
        let first = NoteModel(first: { $0.replacingOccurrences(of: "plan c", with: "the plan") }, afterNote: { $0 })
        let second = NoteModel(first: { $0 }, afterNote: { $0 })
        let both = SmartCleaner(
            budget: .seconds(6), correctionBudget: .seconds(6), polishedBudget: .seconds(6), segmentBudget: .seconds(6),
            model: first, health: ModelHealth(), repairsSpans: false, secondOpinion: second)
        _ = await run(both)
        #expect(first.lastNote != nil)
        #expect(second.lastNote == nil)
    }

    @Test("switched off, the model is not asked again")
    func switchedOff() async {
        let model = NoteModel(first: { $0.replacingOccurrences(of: "plan c", with: "the plan") }, afterNote: { $0 })
        let output = await run(cleaner(model, repairsSpans: false, asksAgain: false))
        #expect(model.calls == 1)
        #expect(output.groups.first?.askedAgain == AskedAgain.none)
    }

    @Test("an answer that passes every check is never asked again")
    func cleanAnswer() async {
        let model = NoteModel(first: { $0 }, afterNote: { $0 })
        let output = await run(cleaner(model))
        #expect(model.calls == 1)
        #expect(output.groups.first?.askedAgain == AskedAgain.none)
    }

    @Test("the note names what was lost and only for checks about lost words")
    func noteText() {
        #expect(GuidedRetry.note(code: .droppedIdentifier, reason: "dropped identifier: c")?.contains("\"c\"") == true)
        #expect(GuidedRetry.note(code: .droppedPurposePhrase, reason: "dropped purpose phrase: confirm")?.contains("to confirm") == true)
        #expect(GuidedRetry.note(code: .droppedContentWords, reason: "dropped content words: [\"vendor\", \"date\"]")?.contains("\"vendor\", \"date\"") == true)
        #expect(GuidedRetry.note(code: .droppedContrastiveActually, reason: "dropped contrastive actually")?.contains("actually") == true)
        #expect(GuidedRetry.note(code: .collapsedDoubledWord, reason: "collapsed a legitimate doubled word: very very")?.contains("very") == true)
        #expect(GuidedRetry.note(code: .keptRetractedItem, reason: "kept retracted item: off the dry cleaning")?.contains("dry cleaning") == true)
        #expect(GuidedRetry.note(code: .changedDigits, reason: "changed digits: 3") == nil)
        #expect(GuidedRetry.note(code: .droppedIdentifier, reason: "dropped identifier") == nil)
    }
}

/// Answers `first` until the instructions carry the note about what was left out, then `afterNote`.
private final class NoteModel: LanguageModel {
    private let first: @Sendable (String) -> String
    private let afterNote: @Sendable (String) -> String
    private let failsAfterNote: Bool
    private let sleepsAfterNote: Bool
    private let state = Mutex((calls: 0, note: String?.none))
    init(first: @escaping @Sendable (String) -> String, afterNote: @escaping @Sendable (String) -> String, failsAfterNote: Bool = false, sleepsAfterNote: Bool = false) {
        self.first = first; self.afterNote = afterNote; self.failsAfterNote = failsAfterNote; self.sleepsAfterNote = sleepsAfterNote
    }
    var calls: Int { state.withLock { $0.calls } }
    var lastNote: String? { state.withLock { $0.note } }
    var identifier: String { "note-model" }
    var availability: LanguageModelAvailability { .available }
    func supportsLanguage(_ languageCode: String) -> Bool { true }
    func prewarm(instructions: String) {}
    func prefixCache(instructions: String) async {}
    func respond(
        instructions: String, prompt: String, schema: GenerationSchemaSpec, options: LanguageModelOptions
    ) async throws -> String {
        guard schema.name == SmartCleaner.Cleaned.generationSchema.name else { throw LanguageModelError.unsupportedSchema(schema.name) }
        let note = instructions.range(of: "Your previous answer left out").map { String(instructions[$0.lowerBound...]) }
        state.withLock { $0.calls += 1; if let note { $0.note = note } }
        if note != nil, sleepsAfterNote { try await Task.sleep(for: .seconds(10)) }
        if note != nil, failsAfterNote { throw LanguageModelError.unsupportedSchema("scripted failure") }
        let draft = prompt.replacingOccurrences(of: "Transcript: ", with: "").replacingOccurrences(of: "\nOutput:", with: "")
        return String(decoding: try JSONEncoder().encode(["text": (note == nil ? first : afterNote)(draft)]), as: UTF8.self)
    }
}
