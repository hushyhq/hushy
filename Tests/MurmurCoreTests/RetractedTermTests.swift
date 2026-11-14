import Foundation
import Testing
@testable import MurmurCore

/// A protected term the speaker took back ("to Sarah, no wait, to Priya") is not one the answer owes them. Dropping it
/// used to read as "changed protected term" and the person got the raw text. A term the speaker kept stays protected.
@Suite("Retracted protected terms", .timeLimit(.minutes(1)))
struct RetractedTermTests {
    private struct Scripted: LanguageModel {
        let answer: String
        var identifier: String { "scripted-retraction" }
        var availability: LanguageModelAvailability { .available }
        func supportsLanguage(_ languageCode: String) -> Bool { true }
        func prewarm(instructions: String) {}
        func prefixCache(instructions: String) async {}
        func respond(instructions: String, prompt: String, schema: GenerationSchemaSpec, options: LanguageModelOptions) async throws -> String {
            let data = try JSONSerialization.data(withJSONObject: ["text": answer])
            return String(decoding: data, as: UTF8.self)
        }
    }

    private func clean(_ raw: String, answer: String, terms: [String]) async -> SmartCleaner.Output {
        var options = CleanupOptions(level: .clean)
        options.protectedTerms = terms
        return await SmartCleaner(model: Scripted(answer: answer), health: ModelHealth(), wholeTranscript: { true })
            .clean(raw, options: options, strategy: .model)
    }

    private let sarahRaw = "Send the invoice to Sarah no wait to Priya by Friday"
    private let sarahAnswer = "Send the invoice to Priya by Friday."

    @Test("the retracted name is dropped and the model's answer is kept")
    func retractedName() async {
        for terms in [["Sarah"], ["Sarah", "Priya"]] {
            let output = await clean(sarahRaw, answer: sarahAnswer, terms: terms)
            #expect(output.text == sarahAnswer, "terms=\(terms) \(output.text) \(String(describing: output.groups.first?.guardCode))")
            #expect(output.groups.first?.outcome == .used)
        }
    }

    @Test("a retracted two-word term is dropped when the replacement is protected too")
    func retractedProduct() async {
        let output = await clean(
            "I use Wispr Flow no wait Superwhisper for dictation", answer: "I use Superwhisper for dictation.",
            terms: ["Wispr Flow", "Superwhisper"])
        #expect(output.text == "I use Superwhisper for dictation.", "\(output.text)")
        #expect(output.groups.first?.outcome == .used)
    }

    @Test("the cue words scratch that and I mean retract a term the same way")
    func otherCues() async {
        let scratch = await clean("Ask Sarah scratch that ask Priya", answer: "Ask Priya.", terms: ["Sarah"])
        #expect(scratch.text == "Ask Priya.", "\(scratch.text)")
        let mean = await clean("Email Sarah I mean Priya about the budget", answer: "Email Priya about the budget.", terms: ["Sarah"])
        #expect(mean.text == "Email Priya about the budget.", "\(mean.text)")
    }

    @Test("a term dropped without any retraction is still refused")
    func droppedWithoutRetraction() async {
        let output = await clean(
            "Send the invoice to Sarah by Friday", answer: "Send the invoice to Priya by Friday.", terms: ["Sarah"])
        #expect(!output.text.contains("Priya"), "\(output.text)")
        #expect(output.text.contains("Sarah"), "\(output.text)")
    }

    @Test("a cue after a term that the answer does not replace leaves the term protected")
    func cueWithoutReplacement() async {
        let output = await clean(
            "I like Sarah actually she is great at this", answer: "She is great at this.", terms: ["Sarah"])
        #expect(output.text.contains("Sarah"), "\(output.text)")
    }

    @Test("a respelled term is still refused beside a retraction of another")
    func respelledNextToRetraction() async {
        let output = await clean(
            "Send the invoice to Sarah no wait to Priya by Friday", answer: "Send the invoice to Pria by Friday.",
            terms: ["Sarah", "Priya"])
        #expect(!output.text.contains("Pria "), "\(output.text)")
    }

    @Test("the guard itself: retracted terms are exempt, kept terms are not")
    func guardLevel() {
        let draft = "Send the invoice to Sarah no wait. To Priya by Friday"
        #expect(ProtectedTermGuard.violation(
            answer: sarahAnswer, draft: draft, raw: sarahRaw, terms: ["Sarah", "Priya"]) == nil)
        #expect(ProtectedTermGuard.violation(
            answer: "Send the invoice by Friday.", draft: draft, raw: sarahRaw, terms: ["Sarah", "Priya"]) != nil)
        #expect(ProtectedTermGuard.violation(
            answer: sarahAnswer, draft: draft, terms: ["Sarah"]) != nil)
    }
}
