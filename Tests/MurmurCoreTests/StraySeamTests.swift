import Foundation
import Testing
@testable import MurmurCore

/// A full stop the recogniser put in the middle of a thought, followed by a lowercase continuation, is not a
/// sentence end. When the two halves land in different groups the seam must not turn it into one.
@Suite("Stray full stop at a group seam", .timeLimit(.minutes(1)))
struct StraySeamTests {
    private let first = "We looked at the onboarding flow with the support team on Tuesday and the first thing people see is the settings page which is confusing."
    private let strayLower = "to the point where new users close the window before they finish anything at all on the first day they try it out."
    private let strayUpper = "To the point where new users close the window before they finish anything at all on the first day they try it out."
    private let last = "We should probably move the important choices up front and measure completion before changing anything else."

    @Test("a lowercase continuation after a full stop continues the sentence")
    func lowercaseContinuation() {
        let groups = TextSegmentation.groups([first, strayLower, last].joined(separator: " "))
        #expect(groups.count >= 3)
        let continued = groups.first { $0.text.hasPrefix("to the point") }
        #expect(continued?.continuesSentence == true)
    }

    @Test("a capitalised sentence after a full stop starts a new sentence")
    func capitalisedStartsNewSentence() {
        let groups = TextSegmentation.groups([first, strayUpper, last].joined(separator: " "))
        let next = groups.first { $0.text.hasPrefix("To the point") }
        #expect(next?.continuesSentence == false)
    }

    @Test("a lowercase start after a question or exclamation mark is not a stray full stop")
    func questionMarkKeepsItsBreak() {
        let question = "Did we look at the onboarding flow with the support team on Tuesday when the first thing people see is the settings page which is confusing?"
        let groups = TextSegmentation.groups([question, strayLower, last].joined(separator: " "))
        let next = groups.first { $0.text.hasPrefix("to the point") }
        #expect(next?.continuesSentence == false)
    }

    @Test("stitching joins the two halves with no sentence end and the continuation stays lowercase")
    func stitchJoins() {
        let groups = TextSegmentation.groups([first, strayLower, last].joined(separator: " "))
        let cleaned = groups.map { group -> String in
            // Each group cleaned on its own: capitalised, full-stopped.
            let text = group.text.prefix(1).uppercased() + group.text.dropFirst()
            return text.hasSuffix(".") ? text : text + "."
        }
        let stitched = TextSegmentation.stitch(cleaned, groups: groups)
        #expect(stitched.contains("is confusing, to the point where") || stitched.contains("is confusing to the point where"))
        #expect(!stitched.contains("confusing. To the point"))
    }

    // MARK: Groups cleaned ahead of time

    @Test("a stray full stop still continues the sentence when the first half was cleaned ahead of time")
    func prewarmedFirstHalf() async {
        let text = [first, strayLower, last].joined(separator: " ")
        let groups = TextSegmentation.groups(text)
        let cleaner = SmartCleaner(
            budget: .seconds(5), correctionBudget: .seconds(5), polishedBudget: .seconds(5), segmentBudget: .seconds(5),
            model: EchoModel(), health: ModelHealth())
        let options = CleanupOptions(level: .polished)
        for group in groups where !group.isTail {
            await cleaner.prewarmGroup(group.text, options: options, continuesSentence: group.continuesSentence)
        }
        let output = await cleaner.clean(text, options: options)
        #expect(!output.text.contains("confusing. To the point"))
        #expect(output.text.contains("to the point where"))
    }

    @Test("the seam is judged on the final transcript, not on what streaming saw when the group was cleaned ahead")
    func finalTranscriptDecidesTheSeam() async {
        // Streaming heard a new sentence ("To the point"); the final pass wrote the same words as a continuation.
        let streamed = [first, strayUpper, last].joined(separator: " ")
        let finalText = [first, strayLower, last].joined(separator: " ")
        let streamedGroups = TextSegmentation.groups(streamed)
        #expect(streamedGroups.first { $0.text.hasPrefix("To the point") }?.continuesSentence == false)
        let cleaner = SmartCleaner(
            budget: .seconds(5), correctionBudget: .seconds(5), polishedBudget: .seconds(5), segmentBudget: .seconds(5),
            model: EchoModel(), health: ModelHealth())
        let options = CleanupOptions(level: .polished)
        for group in streamedGroups where !group.isTail {
            await cleaner.prewarmGroup(group.text, options: options, continuesSentence: group.continuesSentence)
        }
        let output = await cleaner.clean(finalText, options: options)
        #expect(!output.text.contains("confusing. To the point"))
        #expect(output.text.contains("to the point where"))
    }

    // MARK: A question mark the words do not make

    private func runOnGroups(_ first: String, _ second: String) -> [TextSegmentation.Group] {
        [TextSegmentation.Group(text: first, index: 0, isTail: false),
         TextSegmentation.Group(text: second, index: 1, isTail: true, continuesSentence: true)]
    }

    @Test("a short clause a rising voice can make a question keeps the model's mark")
    func intonationQuestionStays() {
        let groups = runOnGroups("you can send it", "I will check the numbers before we talk to the customer")
        let stitched = TextSegmentation.stitch(
            ["You can send it?", "I will check the numbers before we talk to the customer."], groups: groups)
        #expect(stitched.contains("send it? I will") || stitched.contains("send it? i will"))
    }

    @Test("the same clause loses the mark when the next piece goes on with it")
    func continuedClauseLosesTheMark() {
        let groups = runOnGroups("you can send it", "because the review is done and nobody objected")
        let stitched = TextSegmentation.stitch(
            ["You can send it?", "Because the review is done and nobody objected."], groups: groups)
        #expect(!stitched.contains("send it?"))
    }

    @Test("a long statement keeps losing the mark, as before")
    func longStatementLosesTheMark() {
        let groups = runOnGroups(
            "you can send it to the whole team and then ask each of them to come back to us later", "I think that works")
        let stitched = TextSegmentation.stitch(
            ["You can send it to the whole team and then ask each of them to come back to us later?", "I think that works."],
            groups: groups)
        #expect(!stitched.contains("later?"))
    }

    @Test("a question mark a model put on a piece that is not a question becomes a full stop")
    func invoiceQuestionMark() {
        let groups = runOnGroups(
            "when a customer writes in about a billing problem the agent has to open three tabs just to find the invoice",
            "I think we can fix that by putting the invoice and the plan on the same screen")
        let stitched = TextSegmentation.stitch(
            ["When a customer writes in about a billing problem, the agent has to open three tabs just to find the invoice?",
             "I think we can fix that by putting the invoice and the plan on the same screen."], groups: groups)
        #expect(stitched.contains("find the invoice. I think"))
        #expect(!stitched.contains("invoice?"))
    }

    @Test("a real question at the end of a piece keeps its question mark")
    func realQuestionStays() {
        let groups = runOnGroups(
            "so the plan was to ship on Friday and then somebody asked should we wait for the docs",
            "and I said probably yes because support has nothing to point customers to")
        let stitched = TextSegmentation.stitch(
            ["So the plan was to ship on Friday, and then somebody asked, should we wait for the docs?",
             "And I said probably yes because support has nothing to point customers to."], groups: groups)
        #expect(stitched.contains("for the docs?"))
    }

    @Test("a question the speaker marked in the recogniser's own text keeps its question mark")
    func spokenQuestionMarkStays() {
        let groups = runOnGroups(
            "do you think the new onboarding flow is clear enough for people who have never used the app?",
            "I would say it is not")
        let stitched = TextSegmentation.stitch(
            ["Do you think the new onboarding flow is clear enough for people who have never used the app?", "I would say it is not."],
            groups: groups)
        #expect(stitched.contains("the app?"))
    }
}

/// Answers with the transcript it was given, so only the rules and the seam handling shape the text.
private final class EchoModel: LanguageModel {
    var identifier: String { "echo" }
    var availability: LanguageModelAvailability { .available }
    func supportsLanguage(_ languageCode: String) -> Bool { true }
    func prewarm(instructions: String) {}
    func prefixCache(instructions: String) async {}
    func respond(
        instructions: String, prompt: String, schema: GenerationSchemaSpec, options: LanguageModelOptions
    ) async throws -> String {
        guard schema.name == SmartCleaner.Cleaned.generationSchema.name else { throw LanguageModelError.unsupportedSchema(schema.name) }
        let draft = prompt.replacingOccurrences(of: "Transcript: ", with: "").replacingOccurrences(of: "\nOutput:", with: "")
        return String(decoding: try JSONEncoder().encode(["text": draft]), as: UTF8.self)
    }
}
