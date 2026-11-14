import Foundation
import Synchronization
import Testing
@testable import MurmurCore

/// Every limit the cleaner enforces, set far beyond what the instant fake models need. The tests here check which
/// calls are made and what text comes out, never how long anything takes; a busy or sleeping Mac must not be able to
/// turn a budget into a timeout and change the result.
private let steadyLimit: Duration = .seconds(3600)

/// Task 142's two experiments, both off in the app: neighbour context (A) and one call for a whole dictation (B, with an
/// optional paragraph allowance). The first tests pin that off means the same calls as before; the rest pin what each switch does.
@Suite("Neighbour context and whole-dictation experiments", .timeLimit(.minutes(1)), .serialized)
struct WholeDictationExperimentTests {
    /// Four sentences of 14 to 16 words each: over the 40-word threshold, so release cleans several groups.
    private let sentences = [
        "we should send the quarterly update to the whole team before the end of this week",
        "the budget review moved to thursday afternoon because the finance lead is travelling on wednesday",
        "please keep the customer interviews on the calendar and book the conference room for both of them",
        "after that we can look at the hiring plan and decide who joins the support rotation",
    ]
    private var spoken: String { sentences.joined(separator: ". ") + "." }

    private func cleaner(
        _ model: any LanguageModel, neighbours: Bool = false, whole: Int? = nil, paragraphs: Bool = false
    ) -> SmartCleaner {
        SmartCleaner(
            budget: steadyLimit, correctionBudget: steadyLimit, polishedBudget: steadyLimit, segmentBudget: steadyLimit,
            model: model, health: ModelHealth(), dictationCeiling: steadyLimit, noProgressCeiling: steadyLimit, neighbourContext: neighbours, wholeDictationLimit: whole,
            allowsParagraphBreaks: paragraphs, groupCeiling: steadyLimit)
    }

    private func run(_ cleaner: SmartCleaner, _ text: String? = nil) async -> SmartCleaner.Output {
        await cleaner.clean(text ?? spoken, options: CleanupOptions(level: .polished))
    }

    @Test("with every switch off the calls and the text are exactly what they were")
    func offIsIdentical() async {
        let before = Recorder()
        let after = Recorder()
        let plain = await run(SmartCleaner(
            budget: steadyLimit, correctionBudget: steadyLimit, polishedBudget: steadyLimit, segmentBudget: steadyLimit,
            model: before, health: ModelHealth(), dictationCeiling: steadyLimit, noProgressCeiling: steadyLimit, groupCeiling: steadyLimit))
        let explicit = await run(cleaner(after, neighbours: false, whole: nil, paragraphs: false))
        #expect(plain.text == explicit.text)
        #expect(before.prompts == after.prompts)
        #expect(before.instructions == after.instructions)
        #expect(before.prompts.count > 1)
        #expect(before.prompts.allSatisfy { $0.hasPrefix("Transcript: ") && !$0.contains("Before:") && !$0.contains("After:") })
        #expect(before.instructions.allSatisfy { !$0.contains(CompactCleanupPrompt.contextRule) })
    }

    @Test("neighbour context: a group's call carries the tail of the one before and the head of the one after, and only its own span is the transcript")
    func neighbourContextRidesAlong() async throws {
        let model = Recorder()
        let out = await run(cleaner(model, neighbours: true))
        #expect(out.groups.count > 2)
        let prompts = model.prompts
        #expect(prompts.count == out.groups.count)
        // The first group has no "Before"; the last has no "After"; the ones between have both.
        #expect(!prompts[0].contains("Before:") && prompts[0].contains("After:"))
        #expect(prompts[prompts.count - 1].contains("Before:") && !prompts[prompts.count - 1].contains("After:"))
        let middle = try #require(prompts.dropFirst().first)
        #expect(middle.contains("Before:") && middle.contains("After:"))
        // The transcript line is the group's own text; the context is a bounded number of words.
        for prompt in prompts {
            let lines = prompt.split(separator: "\n").map(String.init)
            let before = lines.first { $0.hasPrefix("Before: ") }.map { $0.dropFirst("Before: ".count).split(separator: " ").count }
            let after = lines.first { $0.hasPrefix("After: ") }.map { $0.dropFirst("After: ".count).split(separator: " ").count }
            #expect((before ?? 0) <= SmartCleaner.neighbourTailWords)
            #expect((after ?? 0) <= SmartCleaner.neighbourHeadWords)
            #expect(lines.last == "Output:")
        }
        // The previous group's context is its cleaned text (here the model echoes the draft, so the same words).
        let tail = try #require(middle.split(separator: "\n").first { $0.hasPrefix("Before: ") })
        #expect(tail.contains("end of this week"))
        // The rule that names the context lines is in the instructions of every call that has context.
        #expect(model.instructions.allSatisfy { $0.contains(CompactCleanupPrompt.contextRule) })
        // The pasted text is the groups' own text: none of the context is repeated.
        #expect(out.text.components(separatedBy: "end of this week").count == 2)
    }

    @Test("whole dictation: at or under the limit it is one call with no context; over the limit it is the groups again")
    func oneCallUnderTheLimit() async {
        let words = TextStats.wordCount(spoken)
        let one = Recorder()
        let wholeOut = await run(cleaner(one, neighbours: true, whole: words))
        #expect(one.prompts.count == 1)
        #expect(one.prompts[0].hasPrefix("Transcript: ") && !one.prompts[0].contains("Before:"))
        #expect(wholeOut.groups.count == 1)
        #expect(wholeOut.text.contains("quarterly update") && wholeOut.text.contains("support rotation"))

        let many = Recorder()
        let over = await run(cleaner(many, whole: words - 1))
        #expect(many.prompts.count > 1)
        #expect(over.groups.count == many.prompts.count)
    }

    @Test("whole dictation: the whole answer goes through the same checks, so a rejected answer leaves the whole rules text")
    func wholeAnswerIsChecked() async {
        let model = Recorder(transform: { _ in "" })
        let out = await run(cleaner(model, whole: 200))
        #expect(model.prompts.count >= 1)
        #expect(out.groups.count == 1 && out.groups[0].outcome != .used)
        #expect(out.text.contains("quarterly update") && out.text.contains("support rotation"))
    }

    @Test("paragraphs: a blank line in the answer is refused by default and kept when the allowance is on")
    func paragraphAllowance() async {
        let withBreak: @Sendable (String) -> String = { $0.replacingOccurrences(of: "week. ", with: "week.\n\n") }
        let refused = await run(cleaner(Recorder(transform: withBreak), whole: 200))
        #expect(!refused.text.contains("\n"))
        let allowed = await run(cleaner(Recorder(transform: withBreak), whole: 200, paragraphs: true))
        #expect(allowed.text.contains("\n\n"))
        // A single line break, or a bullet, is still structure the speaker never signalled.
        let bullets = await run(cleaner(Recorder(transform: { "- " + $0.replacingOccurrences(of: ". ", with: ".\n- ") }), whole: 200, paragraphs: true))
        #expect(!bullets.text.contains("\n- "))
    }

    @Test("the list guard treats blank lines as paragraphs only when asked to")
    func listGuard() {
        let answer = "We finished the first part of the report.\n\nThe team reviewed the second part this morning."
        #expect(ListStructureGuard.violation(answer: answer, draft: "first thought here second thought here") != nil)
        #expect(ListStructureGuard.violation(answer: answer, draft: "first thought here second thought here", allowingParagraphBreaks: true) == nil)
        #expect(ListStructureGuard.violation(answer: "One.\nTwo.", draft: "one two", allowingParagraphBreaks: true) != nil)
        #expect(ListStructureGuard.violation(answer: "One.\n\n- two", draft: "one two", allowingParagraphBreaks: true) != nil)
        #expect(ListStructureGuard.violation(answer: "Apples.\n\nOranges.", draft: "apples oranges", allowingParagraphBreaks: true) != nil)
        #expect(ListStructureGuard.violation(answer: "We finished the full report this morning.\n\nThanks.", draft: "we finished the full report this morning thanks", allowingParagraphBreaks: true) == nil)
        #expect(ListStructureGuard.violation(answer: "We finished the full report this morning.\n\nRed apples.", draft: "we finished the full report this morning red apples", allowingParagraphBreaks: true) != nil)
        #expect(ListStructureGuard.violation(answer: "We finished the full report this morning.\n\n1.", draft: "we finished the full report this morning one", allowingParagraphBreaks: true) != nil)
        #expect(ListStructureGuard.violation(answer: "We finished the full report this morning\n\nThanks.", draft: "we finished the full report this morning thanks", allowingParagraphBreaks: true) != nil)
        #expect(ListStructureGuard.violation(answer: "We finished the full report this morning.\n\nthanks.", draft: "we finished the full report this morning thanks", allowingParagraphBreaks: true) != nil)
    }

    @Test("head and tail helpers keep whole words and give nothing for empty text")
    func headAndTail() {
        #expect(SmartCleaner.tail(of: "a b c d e", words: 2) == "d e")
        #expect(SmartCleaner.head(of: "a b c d e", words: 2) == "a b")
        #expect(SmartCleaner.tail(of: "  ", words: 2) == nil)
        #expect(SmartCleaner.head(of: nil, words: 2) == nil)
        #expect(SmartCleaner.tail(of: "a b", words: 12) == "a b")
    }
}

/// Answers `transform(draft)` for every cleanup call and records the prompts and instructions it was given.
private final class Recorder: LanguageModel {
    private let transform: @Sendable (String) -> String
    private let log = Mutex<(prompts: [String], instructions: [String])>(([], []))
    init(transform: @escaping @Sendable (String) -> String = { $0 }) { self.transform = transform }
    var prompts: [String] { log.withLock { $0.prompts } }
    var instructions: [String] { log.withLock { $0.instructions } }
    var identifier: String { "recorder" }
    var availability: LanguageModelAvailability { .available }
    func supportsLanguage(_ languageCode: String) -> Bool { true }
    func prewarm(instructions: String) {}
    func prefixCache(instructions: String) async {}
    func respond(
        instructions: String, prompt: String, schema: GenerationSchemaSpec, options: LanguageModelOptions
    ) async throws -> String {
        guard schema.name == SmartCleaner.Cleaned.generationSchema.name else { throw LanguageModelError.unsupportedSchema(schema.name) }
        log.withLock { $0.prompts.append(prompt); $0.instructions.append(instructions) }
        let transcript = prompt.split(separator: "\n", omittingEmptySubsequences: false)
            .first { $0.hasPrefix("Transcript: ") }.map { String($0.dropFirst("Transcript: ".count)) } ?? prompt
        return String(decoding: try JSONEncoder().encode(["text": transform(transcript)]), as: UTF8.self)
    }
}

@Suite("Group contract experiment", .timeLimit(.minutes(1)), .serialized)
struct GroupContractExperimentTests {
    private let spoken = "We should send the quarterly update to the whole team before the end of this week. The budget review moved to Thursday afternoon because the finance lead is travelling on Wednesday. Please keep the customer interviews on the calendar and book the conference room for both of them."

    private func cleaner(_ model: any LanguageModel, enabled: Bool) -> SmartCleaner {
        SmartCleaner(budget: steadyLimit, correctionBudget: steadyLimit, polishedBudget: steadyLimit,
                     segmentBudget: steadyLimit, model: model, health: ModelHealth(), dictationCeiling: steadyLimit, noProgressCeiling: steadyLimit, groupContract: enabled, groupCeiling: steadyLimit)
    }

    @Test func offIsIdentical() async {
        let plain = ContractRecorder()
        let explicit = ContractRecorder()
        let a = await SmartCleaner(model: plain, health: ModelHealth()).clean(spoken, options: CleanupOptions(level: .polished))
        let b = await cleaner(explicit, enabled: false).clean(spoken, options: CleanupOptions(level: .polished))
        #expect(a.text == b.text)
        #expect(plain.calls.map(\.prompt) == explicit.calls.map(\.prompt))
        #expect(plain.calls.map(\.schema) == explicit.calls.map(\.schema))
    }

    @Test func promptsAndParagraphs() async {
        let model = ContractRecorder(paragraphAt: 1)
        let output = await cleaner(model, enabled: true).clean(spoken, options: CleanupOptions(level: .polished))
        let calls = model.calls
        #expect(calls.count > 1)
        #expect(calls[0].prompt.hasPrefix("Left context: none\nTranscript: "))
        #expect(calls.dropFirst().allSatisfy { $0.prompt.hasPrefix("Left context: ") && !$0.prompt.hasPrefix("Left context: none") })
        #expect(calls.allSatisfy { $0.schema == SmartCleaner.groupCleanedSchema.name })
        #expect(output.text.contains("\n\n"))
    }

    @Test func singleGroupUsesFirstPieceForm() async {
        let model = ContractRecorder(paragraphAt: 0)
        let output = await cleaner(model, enabled: true).clean("Please send the report today.", options: CleanupOptions(level: .polished))
        #expect(model.calls.count == 1)
        #expect(model.calls[0].prompt.hasPrefix("Left context: none\nTranscript: "))
        #expect(!output.text.contains("\n\n"))
    }

    @Test func prewarmedGroupUsesPreviousRulesDraft() async throws {
        let groups = TextSegmentation.groups(spoken)
        #expect(groups.count > 1)
        let model = ContractRecorder(paragraphAt: 1)
        let subject = cleaner(model, enabled: true)
        let options = CleanupOptions(level: .polished)
        for group in groups where !group.isTail {
            await subject.prewarmGroup(group.text, options: options, continuesSentence: group.continuesSentence,
                                       previousRaw: group.index > 0 ? groups[group.index - 1].text : nil)
        }
        let output = await subject.clean(spoken, options: options)
        #expect(output.groupSources.first == .prewarmHit)
        let calls = model.calls
        #expect(calls.count == groups.count)
        for group in groups where group.index > 0 {
            let previousDraft = TextCleaner(options: options).clean(groups[group.index - 1].text).text
            let ownDraft = TextCleaner(options: options).clean(group.text).text
            let expected = CompactCleanupPrompt.groupUserPrompt(draft: ownDraft, previousDraft: previousDraft)
            #expect(calls[group.index].prompt == expected)
        }
    }

    @Test func refusedLineBreakFallsBackWithoutParagraph() async {
        let model = ContractRecorder(paragraphAt: 1, lineBreakAt: 1)
        let output = await cleaner(model, enabled: true).clean(spoken, options: CleanupOptions(level: .polished))
        #expect(output.groups.contains { $0.outcome == .rejectedByGuard })
        #expect(!output.text.contains("\n\n"))
    }

    @Test func guidedRetryKeepsGroupSchemaAndAcceptedFlag() async {
        let raw = "The release plan is ready for review by everyone on the project team today, and the details have been checked carefully by our colleagues. "
            + "The demo failed on plan c since the staging key had expired, so we should write that down for Thursday and send the update to everyone tomorrow."
        let model = ScriptedContractModel { draft, call in
            let text = draft.contains("plan c") && call == 1
                ? draft.replacingOccurrences(of: "plan c", with: "the plan") : draft
            return (text, draft.contains("plan c") && call == 1)
        }
        let subject = SmartCleaner(budget: steadyLimit, correctionBudget: steadyLimit, polishedBudget: steadyLimit,
            segmentBudget: steadyLimit, model: model, health: ModelHealth(), dictationCeiling: steadyLimit, noProgressCeiling: steadyLimit, repairsSpans: false, groupContract: true, groupCeiling: steadyLimit)
        let output = await subject.clean(raw, options: CleanupOptions(level: .polished))
        #expect(model.calls.count >= 3)
        #expect(model.calls.allSatisfy { $0.schema == SmartCleaner.groupCleanedSchema.name })
        #expect(output.groups.contains { $0.askedAgain == .passed })
        #expect(!output.text.contains("\n\n"))
    }

    @Test func guidedRetryRefusesEscapedNewlineAndFallsBack() async {
        let raw = "The demo failed on plan c since the staging key had expired so we should write that down for Thursday."
        let model = ScriptedContractModel { draft, call in
            call == 0 ? (draft.replacingOccurrences(of: "plan c", with: "the plan"), false)
                      : (draft + "\nextra", true)
        }
        let subject = SmartCleaner(budget: steadyLimit, correctionBudget: steadyLimit, polishedBudget: steadyLimit,
            segmentBudget: steadyLimit, model: model, health: ModelHealth(), dictationCeiling: steadyLimit, noProgressCeiling: steadyLimit, repairsSpans: false, groupContract: true, groupCeiling: steadyLimit)
        let output = await subject.clean(raw, options: CleanupOptions(level: .polished))
        #expect(model.calls.count == 2)
        #expect(model.calls.allSatisfy { $0.schema == SmartCleaner.groupCleanedSchema.name })
        #expect(output.groups.first?.outcome == .rejectedByGuard)
        #expect(!output.text.contains("\n"))
    }

    @Test func paragraphReachesPipelineResult() async {
        let model = ContractRecorder(paragraphAt: 1)
        let pipeline = DictationPipeline(transcriber: ContractTranscriber(), cleaner: cleaner(model, enabled: true))
        let result = await pipeline.clean(spoken,
            settings: PipelineSettings(cleanupOptions: CleanupOptions(level: .polished), style: (.workMessages, .formal)))
        #expect(result.text.contains("\n\n"))
    }

    @Test func secondPassKeepsGroupSchemaAndItsOwnFlag() async {
        let raw = "The project schedule is ready for everyone to review today, and all of the details have been checked by the team carefully. "
            + "We could like hide the sidebar for new users and move the menu up front after the release."
        let first = ScriptedContractModel(identifier: "first-contract") { draft, _ in (draft, true) }
        let second = ScriptedContractModel(identifier: "second-contract") { draft, _ in
            (draft.replacingOccurrences(of: " like ", with: " "), false)
        }
        let subject = SmartCleaner(budget: steadyLimit, correctionBudget: steadyLimit, polishedBudget: steadyLimit,
            segmentBudget: steadyLimit, model: first, health: ModelHealth(), dictationCeiling: steadyLimit, noProgressCeiling: steadyLimit, groupContract: true, groupCeiling: steadyLimit, secondOpinion: second)
        let output = await subject.clean(raw, options: CleanupOptions(level: .polished))
        #expect(!second.calls.isEmpty)
        #expect(second.calls.allSatisfy { $0.schema == SmartCleaner.groupCleanedSchema.name })
        #expect(output.groups.contains { $0.secondPass == .used })
        #expect(!output.text.contains("\n\n"))
    }

    @Test func broadGrammarDoesNotLeaveGroupSchemaForVerification() async {
        let model = ScriptedContractModel { draft, _ in
            (draft.replacingOccurrences(of: "a file", with: "the file"), false)
        }
        let subject = cleaner(model, enabled: true)
        _ = await subject.clean("I sent a file to Ada.",
            options: CleanupOptions(level: .clean, grammarContract: .generalMinimal))
        #expect(!model.calls.isEmpty)
        #expect(model.calls.allSatisfy { $0.schema == SmartCleaner.groupCleanedSchema.name })
    }
}

private struct ContractTranscriber: Transcriber {
    func transcribe(_ samples: [Float]) async throws -> String { "" }
}

private final class ScriptedContractModel: LanguageModel {
    struct Call: Sendable { let prompt: String; let schema: String }
    private let log = Mutex<[Call]>([])
    let identifier: String
    private let answer: @Sendable (String, Int) -> (String, Bool)
    init(identifier: String = "scripted-contract", answer: @escaping @Sendable (String, Int) -> (String, Bool)) {
        self.identifier = identifier
        self.answer = answer
    }
    var calls: [Call] { log.withLock { $0 } }
    var availability: LanguageModelAvailability { .available }
    func supportsLanguage(_ languageCode: String) -> Bool { true }
    func prewarm(instructions: String) {}
    func prefixCache(instructions: String) async {}
    func respond(instructions: String, prompt: String, schema: GenerationSchemaSpec, options: LanguageModelOptions) async throws -> String {
        let index = log.withLock { calls -> Int in
            let index = calls.count
            calls.append(Call(prompt: prompt, schema: schema.name))
            return index
        }
        let draft = prompt.components(separatedBy: "\nTranscript: ").last?
            .components(separatedBy: "\nOutput:").first ?? prompt
        let (text, flag) = answer(draft, index)
        return String(decoding: try JSONEncoder().encode(ContractAnswer(text: text, newParagraph: flag)), as: UTF8.self)
    }
    private struct ContractAnswer: Encodable {
        let text: String
        let newParagraph: Bool
        enum CodingKeys: String, CodingKey { case text, newParagraph = "new_paragraph" }
    }
}

private final class ContractRecorder: LanguageModel {
    struct Call: Sendable { let prompt: String; let schema: String }
    private let log = Mutex<[Call]>([])
    let paragraphAt: Int?
    let lineBreakAt: Int?
    init(paragraphAt: Int? = nil, lineBreakAt: Int? = nil) {
        self.paragraphAt = paragraphAt
        self.lineBreakAt = lineBreakAt
    }
    var calls: [Call] { log.withLock { $0 } }
    var identifier: String { "contract-recorder" }
    var availability: LanguageModelAvailability { .available }
    func supportsLanguage(_ languageCode: String) -> Bool { true }
    func prewarm(instructions: String) {}
    func prefixCache(instructions: String) async {}
    func respond(instructions: String, prompt: String, schema: GenerationSchemaSpec, options: LanguageModelOptions) async throws -> String {
        let index = log.withLock { calls -> Int in
            let index = calls.count
            calls.append(Call(prompt: prompt, schema: schema.name))
            return index
        }
        let draft = prompt.components(separatedBy: "\nTranscript: ").last?
            .components(separatedBy: "\nOutput:").first
            ?? prompt.replacingOccurrences(of: "Transcript: ", with: "").components(separatedBy: "\nOutput:")[0]
        if schema.name == SmartCleaner.groupCleanedSchema.name {
            let piece = lineBreakAt == index ? draft + "\nextra" : draft
            return String(decoding: try JSONEncoder().encode(GroupAnswer(text: piece, newParagraph: paragraphAt == index)), as: UTF8.self)
        }
        return String(decoding: try JSONEncoder().encode(["text": draft]), as: UTF8.self)
    }
    private struct GroupAnswer: Encodable {
        let text: String
        let newParagraph: Bool
        enum CodingKeys: String, CodingKey { case text, newParagraph = "new_paragraph" }
    }
}
