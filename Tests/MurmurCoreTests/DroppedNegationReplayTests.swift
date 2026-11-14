import Foundation
import Testing
@testable import MurmurCore

private struct ScriptedModel: LanguageModel {
    let answer: String
    var identifier: String { "scripted-negation" }
    var availability: LanguageModelAvailability { .available }
    func supportsLanguage(_ languageCode: String) -> Bool { true }
    func prewarm(instructions: String) {}
    func prefixCache(instructions: String) async {}
    func respond(
        instructions: String, prompt: String, schema: GenerationSchemaSpec, options: LanguageModelOptions
    ) async throws -> String {
        String(decoding: try JSONEncoder().encode(["text": answer]), as: UTF8.self)
    }
}

private struct NullTranscriberForNegation: Transcriber {
    func transcribe(_ samples: [Float]) async throws -> String { "" }
}

/// A model answer that loses "not" or "never" says the opposite of what was said. These replay such answers through the
/// real cleaner (whole-transcript and rules-draft paths) and through each path's guard, so a flip is never pasted.
@Suite("A dropped negation is never pasted", .timeLimit(.minutes(2)))
struct DroppedNegationReplayTests {
    /// (what was said, a model answer that drops its negation)
    static let flips: [(raw: String, answer: String)] = [
        ("we do not need the report", "We do need the report."),
        ("I never said that", "I said that."),
        ("actually we can't ship friday", "Actually we can ship Friday."),
        ("we do not need the second licence for the pilot", "We do need the second licence for the pilot."),
        ("Actually, I did not approve the 500 dollars.", "Actually, I approved the 500 dollars."),
        ("no wait I mean we won't ship it", "No wait, I mean we will ship it."),
        ("I can't make it sorry I have a dentist appointment", "I can make it, sorry, I have a dentist appointment."),
        ("there is no time left for the demo", "There is time left for the demo."),
        ("the meeting is on friday I guess not saturday", "The meeting is on Saturday."),
        ("it's not ready for the demo", "It's ready for the demo."),
    ]

    /// (what was said, a faithful rewrite that keeps its meaning)
    static let faithful: [(raw: String, answer: String)] = [
        ("we do not need the report", "We don't need the report."),
        ("I will not be able to make it on Friday", "I won't be able to make it on Friday."),
        ("I can not come to the meeting", "I cannot come to the meeting."),
        ("um I never said that", "I never said that."),
        ("actually we can't ship friday", "Actually, we can't ship Friday."),
    ]

    private func cleaned(_ raw: String, answer: String, wholeTranscript: Bool) async -> PipelineResult {
        let cleaner = SmartCleaner(model: ScriptedModel(answer: answer), health: ModelHealth(), wholeTranscript: { wholeTranscript })
        let pipeline = DictationPipeline(transcriber: NullTranscriberForNegation(), cleaner: cleaner)
        return await pipeline.clean(raw, settings: PipelineSettings(cleanupOptions: CleanupOptions(level: .polished)))
    }

    private static func negations(_ text: String) -> Int { NegationPolarity.count(in: text) }

    @Test("whole-transcript path: an answer that drops a negation is refused or put right", arguments: flips.indices)
    func intentPipeline(_ index: Int) async {
        let (raw, answer) = Self.flips[index]
        let result = await cleaned(raw, answer: answer, wholeTranscript: true)
        #expect(result.text != answer, "pasted the flip for \(raw)")
        #expect(Self.negations(result.text) >= 1, "\(raw) -> \(result.text)")
    }

    @Test("whole-transcript guard refuses the flip in every register", arguments: flips.indices)
    func intentGuard(_ index: Int) {
        let (raw, answer) = Self.flips[index]
        for register in [nil] + IntentRegister.allCases.map(Optional.some) {
            if case .accepted(let text, _) = IntentOutputGuard.check(answer, raw: raw, register: register) {
                Issue.record("accepted \(text) for \(raw) under \(String(describing: register))")
            }
        }
    }

    @Test("rules-draft path: an answer that drops a negation is refused or put right", arguments: flips.indices)
    func legacyPipeline(_ index: Int) async {
        let (raw, answer) = Self.flips[index]
        let result = await cleaned(raw, answer: answer, wholeTranscript: false)
        #expect(result.text != answer, "pasted the flip for \(raw)")
        #expect(Self.negations(result.text) >= 1, "\(raw) -> \(result.text)")
    }

    @Test("rules-draft guard refuses the flip", arguments: flips.indices)
    func legacyGuard(_ index: Int) {
        let (raw, answer) = Self.flips[index]
        let draft = TextCleaner(options: CleanupOptions(level: .polished)).clean(raw).text
        if case .accepted(let text, _) = OutputGuard.check(answer, raw: raw, draft: draft, profile: .grammarRepair) {
            Issue.record("accepted \(text) for \(raw) (draft \(draft))")
        }
    }

    @Test("a faithful rewrite that keeps the negation still passes both guards", arguments: faithful.indices)
    func faithfulRewrites(_ index: Int) {
        let (raw, answer) = Self.faithful[index]
        for register in [nil] + IntentRegister.allCases.map(Optional.some) {
            if case .rejected(let reason) = IntentOutputGuard.check(answer, raw: raw, register: register) {
                Issue.record("intent refused \(answer) for \(raw) under \(String(describing: register)): \(reason)")
            }
        }
        let draft = TextCleaner(options: CleanupOptions(level: .polished)).clean(raw).text
        if case .rejected(let reason) = OutputGuard.check(answer, raw: raw, draft: draft, profile: .grammarRepair) {
            Issue.record("rules-draft guard refused \(answer) for \(raw) (draft \(draft)): \(reason)")
        }
    }

    @Test("a contrast the answer leaves out whole is no lost negation on the whole-transcript path")
    func contrastLeftOut() {
        let raw = "I want to send three emails not one one the day before and one on launch day"
        let answer = "I want to send three emails: one the day before and one on launch day."
        if case .rejected(let reason) = IntentOutputGuard.check(answer, raw: raw) { Issue.record("refused: \(reason)") }
    }

    @Test("a negation the speaker took back may still go")
    func retractedNegation() {
        let cases: [(raw: String, answer: String)] = [
            ("We do not ship in June, hold on, November.", "We ship in November."),
            ("don't send it to Maria, sorry, send it to Rahul", "Send it to Rahul."),
        ]
        for (raw, answer) in cases {
            if case .rejected(let reason) = IntentOutputGuard.check(answer, raw: raw) {
                Issue.record("refused \(answer) for \(raw): \(reason)")
            }
        }
        let raw = "Approve this request, no, actually do not approve it."
        if case .rejected(let reason) = OutputGuard.check("Do not approve this request.", raw: raw, draft: raw, profile: .grammarRepair) {
            Issue.record("refused the corrected negation: \(reason)")
        }
    }
}
