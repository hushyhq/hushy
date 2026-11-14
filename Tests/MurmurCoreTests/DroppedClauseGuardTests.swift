import Foundation
import Testing
@testable import MurmurCore

/// A model answer that deletes a whole clause before a hedge ("…two gigs I think we should…" →
/// "I think we should…") or drops the leading request ("can you remind me…", "send…") is rejected
/// and the rules draft is used. A fine-tuned candidate (v5.2) learned this; `OutputGuard`'s
/// "dropped too much" floor (a quarter of the draft) let it through. Cases written from scratch
/// around the three reported shapes.
@Suite("DroppedClauseGuard")
struct DroppedClauseGuardTests {
    @Test("rejects an answer that drops a clause or the leading request", arguments: [
        ("The import, it fails on files over 2 gigs, I think we should never let people upload that much.",
         "I think we should never let people upload that much."),
        ("Can you remind me what we decided about the free tier, I think it was 3 seats.",
         "I think the free tier was 3 seats."),
        ("Send it to John, no, Sarah, she also I think needs the file by Monday.",
         "I think Sarah also needs the file by Monday."),
        ("Send it to Sarah, she also I think needs the file by Monday.",
         "I think Sarah also needs the file by Monday."),
        ("The staging database keeps running out of disk every night, honestly we need a bigger volume.",
         "Honestly, we need a bigger volume."),
    ])
    func rejects(draft: String, answer: String) {
        #expect(DroppedClauseGuard.violation(answer: answer, draft: draft) != nil)
    }

    @Test("allows self-corrections, hedge moves and disfluency removal", arguments: [
        ("The review is on Tuesday, I mean Wednesday.", "The review is on Wednesday."),
        ("Our landlord won't, I mean our landlord will fix it.", "Our landlord will fix it."),
        ("We should ship the new onboarding flow on Friday, I mean we should hold it until the audit is done.",
         "We should hold it until the audit is done."),
        ("So basically the import fails on large files.", "The import fails on large files."),
        ("The import fails on files over 2 gigs, I think.", "The import fails on files over 2 gigs."),
        ("Can you send me the deck before the meeting, I think Dana has it.",
         "Can you send me the deck before the meeting? I think Dana has it."),
        ("Send, no, email the report to Dana.", "Email the report to Dana."),
        ("Honestly the build is broken again.", "Honestly, the build is broken again."),
        ("The import it fails on files over two gigs, I think we should cap uploads.",
         "The import fails on files over 2 gigs. I think we should cap uploads."),
        ("Could you please remind me to call the bank tomorrow.", "Please remind me to call the bank tomorrow."),
        ("Can we to cut costs actually drop the second vendor?", "Can we drop the second vendor to cut costs?"),
        ("can you do the dishes by Friday", "Can you do the dishes by Friday?"),
        ("can you have the report ready by noon", "Can you have the report ready by noon?"),
    ])
    func allows(draft: String, answer: String) {
        #expect(DroppedClauseGuard.violation(answer: answer, draft: draft) == nil)
    }

    @Test("a light verb opens a request too: an answer that drops it is a lost request", arguments: [
        ("can you do the dishes by Friday", "The dishes are due by Friday."),
        ("can you have the report ready by noon", "The report is ready by noon."),
        ("could you make the label bigger", "The label is bigger."),
        ("can you take the notes tonight", "The notes are tonight."),
    ])
    func lightVerbRequestDropped(draft: String, answer: String) {
        #expect(DroppedClauseGuard.violation(answer: answer, draft: draft) == DroppedClauseGuard.droppedRequest)
    }

    @Test("wired into SmartCleaner: the dropped request goes back, the dropped hedge goes back, the number the model wrote stays")
    func putBackKeepsTheModelsNumber() async {
        let raw = "can you remind me what we decided about the free tier I think it was three seats"
        let cleaner = SmartCleaner(model: ClauseDroppingModel(text: "I think the free tier was 3 seats."))
        let output = await cleaner.clean(raw, options: CleanupOptions(level: .polished))
        #expect(output.groups.first?.outcome == .used, "\(String(describing: output.groups.first?.guardCode))")
        #expect((output.groups.first?.repairedSpans ?? 0) > 0)
        #expect(output.text == "Can you remind me what we decided about the free tier I think it was 3 seats?", "\(output.text)")
    }
}

/// Always answers with a fixed cleaned text.
private struct ClauseDroppingModel: LanguageModel {
    let text: String
    var identifier: String { "fixed" }
    var availability: LanguageModelAvailability { .available }
    func supportsLanguage(_ languageCode: String) -> Bool { true }
    func prewarm(instructions: String) {}
    func prefixCache(instructions: String) async {}
    func respond(
        instructions: String, prompt: String, schema: GenerationSchemaSpec, options: LanguageModelOptions
    ) async throws -> String {
        let data = try JSONSerialization.data(withJSONObject: ["text": text])
        return String(decoding: data, as: UTF8.self)
    }
}
