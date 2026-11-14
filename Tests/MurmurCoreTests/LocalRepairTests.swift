import Foundation
import Synchronization
import Testing
@testable import MurmurCore

/// A check that objects to one word or one short span puts that span back and keeps every other change the model
/// made. The group is used, not thrown away to the plain text.
@Suite("Local repair of a tripped check", .timeLimit(.minutes(1)), .serialized)
struct LocalRepairTests {
    private func clean(_ spoken: String, edit: @escaping @Sendable (String) -> String) async -> SmartCleaner.Output {
        let cleaner = SmartCleaner(
            budget: .seconds(6), correctionBudget: .seconds(6), polishedBudget: .seconds(6), segmentBudget: .seconds(6),
            model: EditModel(edit), health: ModelHealth())
        return await cleaner.clean(spoken, options: CleanupOptions(level: .polished))
    }

    // MARK: A lone letter the check wants kept

    @Test("a stutter letter the model removes stays removed, with its other fix")
    func stutterLetterRemovalStands() async {
        let output = await clean("I will p push the release before Friday if the checks are green and Ines has signed off on the notes") {
            $0.replacingOccurrences(of: " p push", with: " push").replacingOccurrences(of: "Friday if", with: "Friday, if")
        }
        let group = output.groups.first
        #expect(group?.outcome == .used, "\(String(describing: group?.guardCode))")
        #expect(group?.repairedSpans == 0)
        #expect(group?.askedAgain == AskedAgain.none)
        #expect(!output.text.contains("p push"))
        #expect(output.text.contains("push the release"))
        #expect(output.text.contains("Friday, if"))
    }

    @Test("a stutter letter that is the only thing the model removed is used, not a fall-back")
    func stutterLetterAloneIsUsed() async {
        let output = await clean("I will p push the release before Friday if the checks are green and Ines has signed off on the notes") {
            $0.replacingOccurrences(of: " p push", with: " push")
        }
        #expect(output.groups.first?.outcome == .used, "\(String(describing: output.groups.first?.guardCode))")
        #expect(!output.text.contains("p push"))
    }

    @Test("a real label and a stutter in one sentence: the label goes back, the stutter stays removed")
    func labelAndStutter() async {
        let output = await clean("we should use plan b and we p push the release before Friday") {
            $0.replacingOccurrences(of: " plan b and we p push", with: " plan and we push")
        }
        #expect(output.groups.first?.outcome == .used, "\(String(describing: output.groups.first?.guardCode))")
        #expect(output.text.contains("plan b"), "\(output.text)")
        #expect(!output.text.contains("p push"))
    }

    @Test("a label the model removes alongside other fixes goes back and the other fixes stay")
    func labelBackAndFixesStay() async {
        let spoken = "the demo failed on plan b because the staging key had expired so we should write down what plan c looks like before Thursday"
        let output = await clean(spoken) {
            $0.replacingOccurrences(of: "plan b because", with: "plan because")
                .replacingOccurrences(of: "demo failed", with: "demo, failed")
        }
        let group = output.groups.first
        #expect(group?.outcome == .used, "\(String(describing: group?.guardCode))")
        #expect(output.text.contains("plan b because"))
        #expect(output.text.contains("demo, failed"))
        #expect(output.text.contains("plan c"))
    }

    @Test("a stutter letter the model removes does not read as a lost request")
    func stutterIsNotTheVerb() {
        #expect(DroppedClauseGuard.violation(
            answer: "Can we make the font a little bigger on the history screen?",
            draft: "can we m make the font a little bigger on the history screen") == nil)
        #expect(DroppedClauseGuard.violation(
            answer: "Please send the notes to Dana tonight.",
            draft: "please s send the notes to Dana tonight") == nil)
        // A real lost request is still caught.
        #expect(DroppedClauseGuard.violation(
            answer: "The notes are for Dana tonight.",
            draft: "please send the notes to Dana tonight") == DroppedClauseGuard.droppedRequest)
    }

    @Test("a request with a stutter letter is used with the letter gone, never rejected for a lost request")
    func requestWithStutter() async {
        for (spoken, kept) in [
            ("can we m make the font a little bigger on the history screen and keep the spacing the same as before", "make the font"),
            ("please s send the notes to Dana tonight and copy Kenji so he can plan the rollout with the support team", "send the notes"),
        ] {
            let output = await clean(spoken) {
                $0.replacingOccurrences(of: " m make", with: " make").replacingOccurrences(of: " s send", with: " send")
            }
            #expect(output.groups.first?.outcome == .used, "\(String(describing: output.groups.first?.guardCode))")
            #expect(output.text.contains(kept), "\(output.text)")
            #expect(!output.text.contains(" m ") && !output.text.contains(" s "), "\(output.text)")
        }
    }

    @Test("a stutter letter after you or should, with a real label after a noun in the same sentence: letter gone, label kept")
    func stutterAfterYouWithALabel() async {
        for (spoken, from, to, label) in [
            ("could you p print the label for box P", " p print", " print", "box P"),
            ("you should c check the tag on row C before the audit starts", " c check", " check", "row C"),
        ] {
            let output = await clean(spoken) { $0.replacingOccurrences(of: from, with: to) }
            #expect(output.groups.first?.outcome == .used, "\(String(describing: output.groups.first?.guardCode))")
            #expect(output.text.contains(label), "\(output.text)")
            #expect(!output.text.contains(from), "\(output.text)")
        }
    }

    @Test("a question whose purpose phrase comes before should really cancel is used, not read as a retraction")
    func purposeBeforeShouldReallyCancel() async {
        let output = await clean("do you reckon to save money we should really cancel the second lease") {
            $0.replacingOccurrences(of: "to save money we should really cancel the second lease", with: "we should really cancel the second lease to save money")
        }
        #expect(output.groups.first?.outcome == .used, "\(String(describing: output.groups.first?.guardCode))")
        #expect(output.text.contains("to save money"), "\(output.text)")
    }

    @Test("a correction actually between two recipients is a cue, not emphasis, and the corrected recipient is used")
    func correctionActuallyBetweenRecipients() async {
        #expect(!DisfluencyOnlyGuard.isEmphasisActually(["send", "it", "to", "maya", "actually", "to", "priya"], at: 4))
        #expect(DisfluencyOnlyGuard.isEmphasisActually(["we", "asked", "the", "contractor", "to", "actually", "fix"], at: 5))
        let output = await clean("send it to Maya actually to Priya") { _ in "Send it to Priya." }
        #expect(output.groups.first?.outcome == .used, "\(String(describing: output.groups.first?.guardCode))")
        #expect(output.text == "Send it to Priya.", "\(output.text)")
    }

    // MARK: One word the answer lost

    @Test("a contrastive actually the model removes goes back and the other change stays")
    func contrastiveActuallyIsPutBack() async {
        let output = await clean("I called the vendor to confirm the delivery date and they said they actually shipped it on Monday") {
            $0.replacingOccurrences(of: "they actually shipped", with: "they shipped")
                .replacingOccurrences(of: "delivery date and", with: "delivery date, and")
        }
        #expect(output.groups.first?.outcome == .used, "\(String(describing: output.groups.first?.guardCode))")
        #expect(output.text.contains("actually"))
        #expect(output.text.contains("delivery date, and"))
    }

    @Test("a contrastive actually that is the only thing the model removed is a fall-back with the code named")
    func contrastiveActuallyAloneIsAFallBack() async {
        let output = await clean("I called the vendor to confirm the delivery date and they said they actually shipped it on Monday") {
            $0.replacingOccurrences(of: "they actually shipped", with: "they shipped")
        }
        #expect(output.groups.first?.outcome == .rejectedByGuard)
        #expect(output.groups.first?.guardCode == .droppedContrastiveActually)
        #expect(output.text.contains("actually"))
    }

    @Test("a doubled word the model collapses goes back while the comma it added stays")
    func doubledWordIsPutBack() async {
        let output = await clean("that that does not really work because they are too close to it but Kenji can cover the schedule") {
            $0.replacingOccurrences(of: "that that", with: "that").replacingOccurrences(of: "That that", with: "That")
                .replacingOccurrences(of: "to it but", with: "to it, but")
        }
        #expect(output.groups.first?.outcome == .used, "\(String(describing: output.groups.first?.guardCode))")
        #expect(output.text.lowercased().contains("that that"))
        #expect(output.text.contains("to it, but"))
    }

    @Test("every guard that points at one word or a short span is repairable")
    func repairableCodes() {
        for code: GuardCode in [
            .droppedIdentifier, .droppedPurposePhrase, .droppedContrastiveActually, .droppedLeadingRequest,
            .collapsedDoubledWord, .droppedTrailOff, .droppedClauseBeforeHedge, .droppedAdmission,
            .droppedClarificationLeadIn, .droppedMarkedWord, .changedModalOrQuantifier, .changedQuestionOrEmphasis,
            .droppedTrailingClause,
        ] {
            #expect(SpanRepair.localCodes.contains(code), "\(code.rawValue)")
        }
    }

    // MARK: A purpose phrase inside a question

    @Test("an emphasis actually does not hide a dropped purpose phrase")
    func purposeInQuestionIsNoticed() {
        let draft = "do you think to grow we should actually hire two more people"
        let reason = DisfluencyOnlyGuard.violation(
            answer: "Do you think we should actually hire two more people?", raw: draft, draft: draft, grammarRepair: true)
        #expect(reason.map { GuardCode(reason: $0) } == .droppedPurposePhrase, "\(String(describing: reason))")
    }

    @Test("an actually that corrects what came before still gives the words before it their reach")
    func correctingActuallyKeepsItsReach() {
        let dropped = DisfluencyOnlyGuard.droppedContent(
            draftWords: ["send", "the", "invoice", "to", "marta", "actually", "to", "priya"],
            answerWords: ["send", "the", "invoice", "to", "priya"])
        #expect(!dropped.contains("marta"))
        #expect(DisfluencyOnlyGuard.isEmphasisActually(["we", "should", "actually", "hire"], at: 2))
        #expect(!DisfluencyOnlyGuard.isEmphasisActually(["send", "it", "to", "marta", "actually", "to", "priya"], at: 4))
        #expect(DisfluencyOnlyGuard.isEmphasisActually(["we", "actually", "hire"], at: 1))
        #expect(!DisfluencyOnlyGuard.isEmphasisActually(["we", "actually", "no", "hire"], at: 1))
    }

    @Test("a purpose or condition phrase the model drops from a question goes back, the rest of the answer stays")
    func purposeInQuestionIsPutBack() async {
        for (spoken, phrase) in [
            ("do you think to grow we should actually hire two more people and then review the budget in June", "to grow"),
            ("do you think to ship faster we should actually cut the review step and then plan the rollout for July", "to ship faster"),
        ] {
            let output = await clean(spoken) {
                $0.replacingOccurrences(of: phrase + " ", with: "").replacingOccurrences(of: "actually ", with: "")
                    .replacingOccurrences(of: " and then", with: ", and then")
            }
            #expect(output.text.contains(phrase), "\(output.text)")
            #expect(output.text.contains(", and then"), "\(output.text)")
            #expect(output.groups.first?.outcome == .used, "\(String(describing: output.groups.first?.guardCode))")
        }
    }

    // MARK: Trail-offs

    @Test("the check counts ellipses and objects only when the answer has fewer than the draft")
    func trailOffCheck() {
        #expect(TrailOffGuard.violation(answer: "We could wait and then. Okay.", draft: "We could wait and then... Okay.") != nil)
        #expect(TrailOffGuard.violation(answer: "We could wait and then… Okay.", draft: "We could wait and then... Okay.") == nil)
        #expect(TrailOffGuard.violation(answer: "We could wait. Okay.", draft: "We could wait. Okay.") == nil)
        #expect(TrailOffGuard.violation(answer: "We could wait and then... Okay.", draft: "We could wait. Okay.") == nil)
        #expect(GuardCode(reason: TrailOffGuard.reason) == .droppedTrailOff)
    }

    @Test("an ellipsis the model turns into a full stop goes back and the model's other fixes stay")
    func ellipsisIsPutBack() async {
        let spoken = "we could move the launch to the following week and then... Okay the next item is the training plan for the support team"
        let output = await clean(spoken) {
            $0.replacingOccurrences(of: "...", with: ".").replacingOccurrences(of: "\u{2026}", with: ".")
                .replacingOccurrences(of: "the launch to", with: "the launch, to")
        }
        #expect(output.text.contains("and then..."), "\(output.text)")
        #expect(!output.text.contains("\u{2026}"), "\(output.text)")
        #expect(output.text.contains("the launch, to"), "\(output.text)")
        #expect(output.groups.allSatisfy { $0.outcome == .used }, "\(output.groups.map(\.label))")
    }

    // MARK: A change that is everything the model did

    @Test("when every change the model made is the one a check objects to, there is no repair: nothing of its work would be kept")
    func allHunksReverted() {
        let draft = "so we need to send the invoice for 4150 dollars to marta by friday"
        #expect(SpanRepair.repair(draft: draft, answer: "so we need to send the invoice for 4510 dollars to marta by friday", objects: { $0.contains("4510") }) == nil)
    }
}

/// Answers the draft with `edit` applied.
private final class EditModel: LanguageModel {
    private let edit: @Sendable (String) -> String
    init(_ edit: @escaping @Sendable (String) -> String) { self.edit = edit }
    var identifier: String { "edit-model" }
    var availability: LanguageModelAvailability { .available }
    func supportsLanguage(_ languageCode: String) -> Bool { true }
    func prewarm(instructions: String) {}
    func prefixCache(instructions: String) async {}
    func respond(
        instructions: String, prompt: String, schema: GenerationSchemaSpec, options: LanguageModelOptions
    ) async throws -> String {
        guard schema.name == SmartCleaner.Cleaned.generationSchema.name else { throw LanguageModelError.unsupportedSchema(schema.name) }
        let draft = prompt.replacingOccurrences(of: "Transcript: ", with: "").replacingOccurrences(of: "\nOutput:", with: "")
        return String(decoding: try JSONEncoder().encode(["text": edit(draft)]), as: UTF8.self)
    }
}
