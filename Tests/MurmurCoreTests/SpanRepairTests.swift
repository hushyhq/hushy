import Foundation
import Testing
@testable import MurmurCore

/// A check that objects to a place in the text no longer costs the whole answer: the span it objects
/// to goes back to what the speaker said, the rest of the model's work stays.
@Suite("Span repair", .timeLimit(.minutes(1)))
struct SpanRepairTests {
    private let draft = "so we need to send the invoice for 4150 dollars to marta by friday"

    @Test("only the hunk that trips the check is put back")
    func revertsOnlyTheOffendingHunk() throws {
        let answer = "So we need to send the invoice for 4510 dollars to Marta by Friday."
        let repaired = try #require(SpanRepair.repair(draft: draft, answer: answer, objects: { $0.contains("4510") }))
        #expect(repaired.text.contains("4150"))
        #expect(!repaired.text.contains("4510"))
        #expect(repaired.text.contains("Marta") && repaired.text.contains("Friday."))
        #expect(repaired.reverted == 1)
    }

    @Test("nothing is repaired when the draft already trips the check")
    func draftAlreadyFailing() {
        let answer = "So we need to send the invoice for 4510 dollars to Marta by Friday."
        #expect(SpanRepair.repair(draft: draft, answer: answer, objects: { $0.contains("4") }) == nil)
    }

    @Test("nothing is repaired when no single hunk trips the check")
    func collectiveObjection() {
        let answer = "So we need to send the invoice for 4150 dollars to Marta by Friday."
        #expect(SpanRepair.repair(draft: draft, answer: answer, objects: { $0.contains("Marta") && $0.contains("Friday") }) == nil)
    }

    @Test("nothing is repaired when every hunk is guilty, since that is the draft again")
    func everyHunkGuilty() {
        let answer = "so we need to send the invoice for 4510 dollars to marta by friday"
        #expect(SpanRepair.repair(draft: draft, answer: answer, objects: { $0.contains("4510") }) == nil)
    }

    @Test("a repeated word the model removed stays removed while the changed number goes back")
    func repeatedWord() throws {
        let draft = "we we need the the report for 4150 dollars"
        let answer = "We need the report for 4510 dollars."
        let repaired = try #require(SpanRepair.repair(draft: draft, answer: answer, objects: { $0.contains("4510") }))
        #expect(repaired.text.contains("4150") && !repaired.text.contains("4510"))
        #expect(!repaired.text.lowercased().contains("we we") && !repaired.text.lowercased().contains("the the"))
    }

    @Test("punctuation at the edge of a reverted hunk comes back with the draft's word")
    func punctuationAtTheEdge() throws {
        let draft = "send it to priya, by friday for 4150."
        let answer = "Send it to Priya by Friday for 4510."
        let repaired = try #require(SpanRepair.repair(draft: draft, answer: answer, objects: { $0.contains("4510") }))
        #expect(repaired.text.hasSuffix("4150."))
        #expect(repaired.text.contains("Priya") && repaired.text.contains("Friday"))
    }

    @Test("an emoji and accented letters pass through a repair untouched")
    func nonASCII() throws {
        let draft = "send the résumé to zoë 😀 for 4150 euros"
        let answer = "Send the résumé to Zoë 😀 for 4510 euros."
        let repaired = try #require(SpanRepair.repair(draft: draft, answer: answer, objects: { $0.contains("4510") }))
        #expect(repaired.text.contains("😀") && repaired.text.contains("résumé") && repaired.text.contains("Zoë"))
        #expect(repaired.text.contains("4150") && !repaired.text.contains("4510"))
    }

    @Test("runs of spaces and tabs in the draft collapse to single spaces and nothing else moves")
    func whitespace() throws {
        let draft = "we  need\tto send   4150 dollars"
        let answer = "We need to send 4510 dollars."
        let repaired = try #require(SpanRepair.repair(draft: draft, answer: answer, objects: { $0.contains("4510") }))
        #expect(repaired.text == "We need to send 4150 dollars.")
    }

    @Test("an answer with line breaks is left whole")
    func lineBreaksAreLayout() {
        let answer = "So we need to send the invoice for 4510 dollars\nto Marta by Friday."
        #expect(SpanRepair.repair(draft: draft, answer: answer, objects: { $0.contains("4510") }) == nil)
    }

    @Test("only guards that point at a place are repairable; whole-answer guards are not")
    func allowlist() {
        for code: GuardCode in [.keptRetractedItem, .listWithoutSignal, .spokenLayoutChanged, .rankedBelowRules, .emptyAnswer, .other] {
            #expect(!SpanRepair.localCodes.contains(code))
        }
        #expect(SpanRepair.localCodes.contains(.changedDigits))
    }

    @Test("a model that changes a number and fixes the rest keeps the fixes and the spoken number")
    func throughTheCleaner() async {
        let model = ScriptedModel(json: #"{"text": "So we need to send the invoice for 4510 dollars to Marta by Friday."}"#)
        let spoken = "so we need to send the invoice for 4150 dollars to marta by friday"
        let output = await SmartCleaner(model: model, health: ModelHealth())
            .clean(spoken, options: CleanupOptions(level: .clean))
        #expect(output.text.contains("4150"))
        #expect(!output.text.contains("4510"))
        #expect(output.groups.first?.outcome == .used)
        #expect(output.groups.first?.repairedSpans == 1)
        let summary = CleanupOutcomeSummary(groups: output.groups, level: .clean)
        #expect(summary?.code.hasPrefix("ran-repaired") == true)
    }

    @Test("a changed protected term goes back and the rest of the answer stays, with every check run again")
    func protectedTermIsRepaired() async {
        var options = CleanupOptions(level: .clean)
        options.protectedTerms = ["Kubernetes"]
        let model = ScriptedModel(json: #"{"text": "So we need to deploy Kubernetis on Friday, please."}"#)
        let output = await SmartCleaner(model: model, health: ModelHealth())
            .clean("so we need to deploy Kubernetes on friday please", options: options)
        #expect(output.text.contains("Kubernetes"))
        #expect(!output.text.contains("Kubernetis"))
        #expect(output.groups.first?.outcome == .used, "\(String(describing: output.groups.first?.guardCode))")
        #expect((output.groups.first?.repairedSpans ?? 0) >= 1)
    }

    @Test("an answer that keeps a retracted item is never repaired")
    func retractionStaysWhole() async {
        let model = ScriptedModel(json: #"{"text": "Add milk, no wait, add eggs to the list."}"#)
        let output = await SmartCleaner(model: model, health: ModelHealth())
            .clean("add milk no wait add eggs to the list", options: CleanupOptions(level: .clean))
        #expect(output.groups.first?.repairedSpans == 0)
    }
}

/// The small-judge experiment sorts changed spans by what they touch, from closed word lists only.
@Suite("Small span judge spans", .timeLimit(.minutes(1)))
struct SmallSpanJudgeSpanTests {
    @Test("a changed number, a new not and a changed name are told apart from plain edits")
    func categories() {
        let draft = "we owe 4150 dollars and we can send it to priya on friday"
        let number = SmallSpanJudge.spans(draft: draft, answer: "We owe 4510 dollars and we can send it to priya on friday.")
        #expect(number.contains { $0.touchesNumber })
        let negation = SmallSpanJudge.spans(draft: draft, answer: "We owe 4150 dollars and we can not send it to priya on friday.")
        #expect(negation.contains { $0.touchesNegation })
        let name = SmallSpanJudge.spans(draft: draft, answer: "We owe 4150 dollars and we can send it to Pria on friday.")
        #expect(name.contains { $0.touchesName })
        let plain = SmallSpanJudge.spans(draft: draft, answer: "We owe 4150 dollars, and we can send it to Priya on Friday.")
        #expect(plain.allSatisfy { !$0.touchesNumber && !$0.touchesNegation && !$0.touchesName })
    }
}

private final class ScriptedModel: LanguageModel {
    private let json: String
    init(json: String) { self.json = json }
    var identifier: String { "scripted" }
    var availability: LanguageModelAvailability { .available }
    func supportsLanguage(_ languageCode: String) -> Bool { true }
    func prewarm(instructions: String) {}
    func prefixCache(instructions: String) async {}
    func respond(
        instructions: String, prompt: String, schema: GenerationSchemaSpec, options: LanguageModelOptions
    ) async throws -> String { json }
}
