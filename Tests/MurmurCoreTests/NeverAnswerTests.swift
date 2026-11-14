import Foundation
import Testing
@testable import MurmurCore

/// The first rule of the product: what is delivered is what was said, rewritten, never a reply to it. A model that
/// answers the speaker is refused whatever the input looks like, and the rules draft is delivered "as heard".
/// Every text here is invented.
@Suite("Never an answer")
struct NeverAnswerTests {
    private static let polished = CleanupOptions(level: .polished)

    /// What is left of a short question to "you" when the start of the recording is lost, and shorter pieces still.
    static let heard = [
        "me", "for me", "to me", "to you", "you to me", "help me", "to help me", "able to help me",
        "are you able to help me", "can you", "are you there", "what do you think", "tomorrow", "of the", "elp me",
    ]
    /// Things a model says back instead of rewriting.
    static let replies = [
        "I failed to understand that.", "I am confused by that.", "That is unclear to me.", "Okay.", "Sure, go ahead.",
        "Yes, I can do that.", "I can help you with that.", "I am able to help you.", "Sorry, what was the question?",
        "Could you repeat that please?",
    ]

    private func deliver(_ raw: String, modelSays answer: String, requiresRewrite: Bool = true) async -> SmartCleaner.Output {
        await SmartCleaner(model: FixedAnswer(text: answer), requiresRewrite: requiresRewrite).clean(raw, options: Self.polished)
    }

    private func rulesText(_ raw: String) async -> String {
        await SmartCleaner(model: NullLanguageModel()).clean(raw, options: Self.polished, strategy: .rules).text
    }

    // MARK: How it got through

    @Test("the checks before the last one let a reply to a short piece through: none asks that the input survive")
    func earlierChecksAcceptAReply() {
        // Two words the model brought ("failed", "understand") are within the two any answer may add, the rest are
        // small words that cost nothing at this level, and the piece holds no word the drop checks count.
        for piece in ["me", "for me", "to me", "you to me", "elp me"] {
            let draft = TextCleaner(options: Self.polished).clean(piece).text
            let verdict = OutputGuard.check("I failed to understand that.", raw: piece, draft: draft, profile: .grammarRepair)
            guard case .accepted = verdict else { Issue.record("expected the earlier checks to accept, for \(piece)"); continue }
        }
    }

    @Test("without the last check the reply is what gets delivered")
    func withoutTheCheckTheReplyIsDelivered() async {
        let output = await deliver("for me", modelSays: "I failed to understand that.", requiresRewrite: false)
        #expect(output.usedModel)
        #expect(output.text == "I failed to understand that.")
        #expect(output.groups.first?.account?.isRewrite == false)
    }

    // MARK: The property

    @Test("replies fail the account for every short piece")
    func repliesFailTheAccount() {
        for piece in Self.heard {
            let draft = TextCleaner(options: Self.polished).clean(piece).text
            for reply in Self.replies {
                #expect(!RewriteAccount.measure(reply, against: draft, also: piece).isRewrite)
            }
        }
    }

    @Test("the guard refuses a reply for a short piece")
    func aReplyIsNeverDelivered() async {
        let piece = "for me"
        let output = await deliver(piece, modelSays: "I failed to understand that.")
        #expect(output.text == (await rulesText(piece)))
        #expect(!output.usedModel)
    }

    @Test("the refusal is named, counted in numbers and marked as heard")
    func theRefusalIsNamedAndMarked() async {
        let output = await deliver("to help me", modelSays: "I am confused by that.")
        #expect(output.text == "To help me.")
        #expect(output.groups.first?.outcome == .rejectedByGuard)
        #expect(output.groups.first?.guardCode == .notARewrite)
        #expect(output.deliveredAsHeard)
        #expect(output.rejection?.hasPrefix("not a rewrite: draft=3 answer=5 in-order=0 elsewhere=0 new=5 share=0") == true)
        #expect(ModelOutcome.logLabel(usedModel: false, rejection: output.rejection) == "rejected-by-guard(not-a-rewrite)")
        // Counts only: nothing that was said or answered is in the reason.
        for word in ["help", "confused"] { #expect(output.rejection?.contains(word) == false) }
    }

    @Test("a reply is not mended word by word into something that looks like the dictation")
    func aReplyIsNotMended() async {
        let output = await deliver("what do you think", modelSays: "I am not sure what you mean.")
        #expect(output.text == "What do you think?")
        #expect(output.groups.first?.guardCode == .notARewrite)
    }

    @Test("a long dictation answered with a reply falls back to the rules text too")
    func aLongReplyIsRefused() async {
        let raw = "so the harbour office opens at nine and the ferry leaves before noon can you check whether the tickets "
            + "cover both crossings and tell me what the return costs"
        let output = await deliver(raw, modelSays: "Sure, I can check the ferry tickets for you. The return usually costs about the same as the outbound trip, and most tickets cover both crossings.")
        #expect(!output.usedModel)
        #expect(output.text == (await rulesText(raw)))
    }

    // MARK: What a rewrite may still do

    @Test("an ordinary rewrite is delivered", arguments: [
        ("um so i i think we should move the review to friday", "I think we should move the review to Friday."),
        ("meeting tomorrow at the harbour office", "The meeting is tomorrow at the harbour office."),
        ("the ferry leave at nine and we needs two ticket", "The ferry leaves at nine and we need two tickets."),
        ("i do not think the tickets cover both crossings", "I don't think the tickets cover both crossings."),
        ("can you check the return price", "Can you check the return price?"),
        ("you coming tomorrow", "Are you coming tomorrow?"),
        ("tomorrow", "Tomorrow."),
        ("thanks", "Thanks!"),
    ])
    func aRewriteIsDelivered(raw: String, answer: String) async {
        let output = await deliver(raw, modelSays: answer)
        #expect(output.usedModel, "\(String(describing: output.rejection))")
        #expect(output.text == answer)
        #expect(!output.deliveredAsHeard)
    }

    @Test("the measure itself: a reply weighs mostly new, a rewrite mostly kept")
    func theMeasure() {
        #expect(!RewriteAccount.measure("I am able to help you.", against: "are you able to help me").isRewrite)
        #expect(!RewriteAccount.measure("Okay.", against: "carry these for me").isRewrite)
        #expect(!RewriteAccount.measure("Anything", against: "").isRewrite)
        #expect(RewriteAccount.measure("Carry these for me.", against: "carry these for me").isRewrite)
        #expect(RewriteAccount.measure("We should ship it, I think.", against: "i think we should ship it").isRewrite)
        #expect(RewriteAccount.measure("", against: "nothing at all").isRewrite)
    }
}

/// Always answers with the same text, whatever it is asked.
private struct FixedAnswer: LanguageModel {
    let text: String
    var identifier: String { "fixed-answer" }
    var availability: LanguageModelAvailability { .available }
    func supportsLanguage(_ languageCode: String) -> Bool { true }
    func prewarm(instructions: String) {}
    func prefixCache(instructions: String) async {}
    func respond(
        instructions: String, prompt: String, schema: GenerationSchemaSpec, options: LanguageModelOptions
    ) async throws -> String {
        String(decoding: try JSONSerialization.data(withJSONObject: ["text": text]), as: UTF8.self)
    }
}
