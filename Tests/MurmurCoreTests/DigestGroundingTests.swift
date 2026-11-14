import Foundation
import Testing
@testable import MurmurCore

@Suite("Digest grounding")
struct DigestGroundingTests {
    static let transcript = """
        Priya: Okay, Marcus, can you fix the login crash by Wednesday?
        Speaker 2: Sure. And I'll ask Dana for the mockups.
        You: I'll send the deck on the nineteenth.
        """
    let source = DigestGrounding.Source(Self.transcript)

    @Test("an owner who is a speaker, You, or a name said in the meeting stays", arguments: ["Priya", "Speaker 2", "You", "Marcus", "dana", ""])
    func knownOwners(owner: String) {
        let item = DigestGrounding.grounded(DigestActionItem(owner: owner, task: "Do it", due: ""), in: source)
        #expect(item.owner == owner)
    }

    @Test("an owner nobody in the meeting is called becomes unassigned, and the task stays")
    func inventedOwner() {
        let item = DigestGrounding.grounded(DigestActionItem(owner: "Jordan", task: "Fix the login crash", due: "Wednesday"), in: source)
        #expect(item.owner.isEmpty)
        #expect(item.task == "Fix the login crash")
        #expect(item.due == "Wednesday")
    }

    @Test("a due date whose day or number was said stays; one that was never said goes", arguments: [
        ("by Wednesday", true), ("the 19th", true), ("next week", true), ("Friday", false), ("March 3", false),
    ])
    func dues(due: String, kept: Bool) {
        let item = DigestGrounding.grounded(DigestActionItem(owner: "Marcus", task: "Fix it", due: due), in: source)
        #expect(item.due == (kept ? due : ""))
    }

    @Test("the summary leaves an invented owner unassigned in the note's fields")
    func throughTheSummary() async {
        let model = FixedDigestModel(json: #"{"title":"Sync","keyPoints":["Login crash"],"decisions":[],"actionItems":[{"owner":"Jordan","task":"Fix the login crash","due":"Friday"},{"owner":"Marcus","task":"Fix the login crash on old phones","due":"Wednesday"}]}"#)
        let long = Array(repeating: Self.transcript, count: 12).joined(separator: "\n")
        let (output, _) = await NoteSummarizer.summarize(long, fallbackTitle: "Note", model: model)
        #expect(output.actionDetails?.map(\.owner) == ["", "Marcus"])
        #expect(output.actionDetails?.map(\.due) == ["", "Wednesday"])
    }

    @Test("decisions read from the summary's Decided lines, in order")
    func records() {
        let summary = "- Login crash is top priority\n- Decided: Ship on the 19th\n- Decided: Keep three screens"
        #expect(MeetingRecords.decisions(in: summary).map(\.text) == ["Ship on the 19th", "Keep three screens"])
    }
}

private struct FixedDigestModel: LanguageModel {
    let json: String
    var identifier: String { "fixed-digest" }
    var availability: LanguageModelAvailability { .available }
    var contextTokens: Int { 32_768 }
    func supportsLanguage(_ languageCode: String) -> Bool { true }
    func prewarm(instructions: String) {}
    func prefixCache(instructions: String) async {}
    func respond(instructions: String, prompt: String, schema: GenerationSchemaSpec, options: LanguageModelOptions) async throws -> String {
        json
    }
}
