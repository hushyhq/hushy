import Foundation
import Testing
@testable import MurmurCore

/// A single capital letter right after a word names something ("plan B", "gate C", "folder X"). The word-count
/// guards ignore words of one or two letters, so a model answer that drops the letter used to pass.
@Suite("Identifier letter is kept", .timeLimit(.minutes(1)))
struct IdentifierLetterGuardTests {
    @Test("an answer that drops the letter after a noun is rejected", arguments: [
        ("The demo failed on plan B because the key expired.", "The demo failed on the plan because the key expired."),
        ("Please keep gate C open for the delivery.", "Please keep the gate open for the delivery."),
        ("Move the contract to folder X and the copy to folder Y.", "Move the contract to the folder and the copy to folder Y."),
        ("the demo failed on plan b because the key expired", "the demo failed on the plan because the key expired"),
        ("park at lot c and wait there", "park at the lot and wait there"),
    ])
    func dropIsRejected(draft: String, answer: String) {
        for repair in [false, true] {
            let reason = DisfluencyOnlyGuard.violation(answer: answer, raw: draft, draft: draft, grammarRepair: repair)
            #expect(reason != nil)
            #expect(GuardCode(reason: reason ?? "") == .droppedIdentifier)
        }
    }

    @Test("a list of identifiers written differently is not a drop", arguments: [
        ("pick option B or C for the pilot", "Pick option B/C for the pilot."),
        ("pick option B or C for the pilot", "Pick option B, C for the pilot."),
        ("pick option B and C for the pilot", "Pick options B and C for the pilot."),
        ("pick option b or c for the pilot", "Pick option B or C for the pilot."),
    ])
    func listForms(draft: String, answer: String) {
        #expect(DisfluencyOnlyGuard.droppedIdentifierLetter(draft: draft, answer: answer) == nil)
    }

    @Test("dropping one of a list of identifiers is still a drop")
    func oneOfAListDropped() {
        #expect(DisfluencyOnlyGuard.droppedIdentifierLetter(
            draft: "pick option B or C for the pilot", answer: "Pick option B for the pilot.") == "c")
    }

    @Test("an answer that keeps the letter passes")
    func keepIsAllowed() {
        let draft = "So basically we like use plan B because the key expired."
        let answer = "We use plan B because the key expired."
        #expect(DisfluencyOnlyGuard.violation(answer: answer, raw: draft, draft: draft) == nil)
    }

    @Test("a lone letter after a subject pronoun, modal, auxiliary or please that starts the next word is a stutter, so the model's removal stands", arguments: [
        ("can we m make the font a little bigger", "Can we make the font a little bigger?"),
        ("we should c check the numbers again", "We should check the numbers again."),
        ("please s send the notes to Dana tonight", "Please send the notes to Dana tonight."),
        ("the team will d deploy it tonight", "The team will deploy it tonight."),
    ])
    func stutterIsNotALabel(draft: String, answer: String) {
        #expect(DisfluencyOnlyGuard.droppedIdentifierLetter(draft: draft, answer: answer) == nil)
        for repair in [false, true] {
            let reason = DisfluencyOnlyGuard.violation(answer: answer, raw: draft, draft: draft, grammarRepair: repair)
            #expect(reason.map { GuardCode(reason: $0) } != .droppedIdentifier)
        }
    }

    @Test("after \"to\", a preposition or an object pronoun a lone letter might be a label, so its removal is a drop", arguments: [
        ("assign it to b before rollout", "Assign it to before rollout."),
        ("put the report into b before Monday", "Put the report into before Monday."),
        ("I want to p push the release before Friday", "I want to push the release before Friday."),
        ("let me t talk to Ines first", "Let me talk to Ines first."),
    ])
    func narrowedToWhereAStutterIsTheOnlyReading(draft: String, answer: String) {
        #expect(DisfluencyOnlyGuard.droppedIdentifierLetter(draft: draft, answer: answer) != nil)
    }

    @Test("a label after \"to\" is kept when the answer keeps it")
    func labelAfterToKept() {
        #expect(DisfluencyOnlyGuard.droppedIdentifierLetter(
            draft: "assign it to b before rollout", answer: "Assign it to b before rollout.") == nil)
    }

    @Test("a label that starts the next word is still a label after a word that can carry one", arguments: [
        ("we went with option c could be cheaper but slower", "We went with option could be cheaper but slower."),
        ("put the old contract in folder s sorted by date", "Put the old contract in folder sorted by date."),
        ("send lot b before noon", "Send the lot before noon."),
    ])
    func labelIsStillALabel(draft: String, answer: String) {
        #expect(DisfluencyOnlyGuard.droppedIdentifierLetter(draft: draft, answer: answer) != nil)
    }

    @Test("a sentence with a stutter and a real label keeps the label and lets the stutter go")
    func stutterAndLabel() {
        let draft = "we should use plan b and we p push the release before Friday"
        #expect(DisfluencyOnlyGuard.droppedIdentifierLetter(draft: draft, answer: "We should use plan b and we push the release before Friday.") == nil)
        #expect(DisfluencyOnlyGuard.droppedIdentifierLetter(draft: draft, answer: "We should use plan and we push the release before Friday.") == "b")
    }

    @Test("the pronoun I, the article A and a lower-case a are not identifiers", arguments: [
        ("Then I think it works and I will ship it.", "Then I think it works and I will ship it"),
        ("Yesterday we met. A plan is needed.", "Yesterday we met. We need a plan."),
        ("We need a plan for the week.", "We need plan for the week."),
    ])
    func notAnIdentifier(draft: String, answer: String) {
        let reason = DisfluencyOnlyGuard.violation(answer: answer, raw: draft, draft: draft)
        #expect(reason.map { GuardCode(reason: $0) } != .droppedIdentifier)
    }
}

/// The verb of a purpose phrase between a framing verb and its clause carries the reason. Polished tolerates one
/// dropped word while it restructures a sentence; this one is not tolerated.
@Suite("Purpose phrase is kept", .timeLimit(.minutes(1)))
struct PurposePhraseGuardTests {
    @Test("Polished rejects an answer that drops the verb after to", arguments: [
        ("I called the vendor to confirm the delivery date and they said it shipped.", "I called the vendor about the delivery date and they said it shipped."),
        ("She opened the spreadsheet to check the totals and found the March row blank.", "She opened the spreadsheet and found the March row blank."),
        ("We met on Tuesday to decide on the budget and left without a number.", "We met on Tuesday and left without a number."),
    ])
    func dropIsRejected(draft: String, answer: String) {
        let reason = DisfluencyOnlyGuard.violation(answer: answer, raw: draft, draft: draft, grammarRepair: true)
        #expect(reason.map { GuardCode(reason: $0) } == .droppedPurposePhrase)
    }

    @Test("Polished allows the verb to change its form", arguments: [
        ("She opened the spreadsheet to check the totals and found the March row blank.", "She opened the spreadsheet for checking the totals and found the March row blank."),
        ("I want to um fix the login before Friday.", "I want to fix the login before Friday."),
    ])
    func reformIsAllowed(draft: String, answer: String) {
        let reason = DisfluencyOnlyGuard.violation(answer: answer, raw: draft, draft: draft, grammarRepair: true)
        #expect(reason.map { GuardCode(reason: $0) } != .droppedPurposePhrase)
    }
}
