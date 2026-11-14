import Testing
@testable import MurmurCore

/// A speaker who says an opening twice to add a second item ("we should cancel the Tuesday sync, we should cancel the Friday
/// retro") has not corrected the first. A model answer that keeps only the second item lost content, and no restart explains
/// it: the first clause is complete. A real restart is unfinished, and a real correction carries a cue.
/// The texts are invented; the guard reads their shape, not their words.
/// Tests marked "(fails without the fix)" fail on the code before this change; tests marked "(fails without the shape rule)"
/// fail on a version that marks every repeated opening's first item as required, whatever stands next to it.
@Suite("Repeat to add keeps the first item")
struct RepeatToAddTests {
    private func words(_ text: String) -> [String] { EvalMetrics.normalizedWords(text) }

    // MARK: the loss

    @Test("an answer that keeps only the second item of a repeated opening is rejected (fails without the fix)", arguments: [
        ("We should cancel the Tuesday sync we should cancel the Friday retro and use that time for planning.",
         "We should cancel the Friday retro and use that time for planning."),
        ("They need to fix the login bug they need to fix the upload bug before the demo.",
         "They need to fix the upload bug before the demo."),
        ("We should mostly do the invoices on Monday mostly do the refunds after the audit.",
         "We should mostly do the refunds after the audit."),
        ("Please review the budget please review the roadmap before the board meets.",
         "Please review the roadmap before the board meets."),
        ("I will update the readme I will update the changelog once the checks pass.",
         "I will update the changelog once the checks pass."),
    ])
    func rejectsLostFirstItem(draft: String, answer: String) {
        for polished in [false, true] {
            let reason = DisfluencyOnlyGuard.violation(answer: answer, raw: draft, draft: draft, grammarRepair: polished)
            #expect(GuardCode(reason: reason ?? "") == .droppedContentWords)
        }
    }

    @Test("with three items each item is judged on its own, also where two lost words are tolerated (fails without the fix)")
    func threeItems() {
        let draft = "Fix the login bug fix the upload bug fix the signup bug before the demo."
        #expect(RepeatedFrame.finishedRepeats(in: words(draft), minimumLength: 2).count == 2)
        let lostFirst = "Fix the upload bug and the signup bug before the demo."
        let lostMiddle = "Fix the login bug and the signup bug before the demo."
        let kept = "Fix the login bug, the upload bug and the signup bug before the demo."
        // Polished tolerates one or two lost words anywhere else; here one word is a whole item.
        for answer in [lostFirst, lostMiddle] {
            let reason = DisfluencyOnlyGuard.violation(answer: answer, raw: draft, draft: draft, grammarRepair: true)
            #expect(GuardCode(reason: reason ?? "") == .droppedContentWords)
        }
        for polished in [false, true] {
            #expect(DisfluencyOnlyGuard.violation(answer: kept, raw: draft, draft: draft, grammarRepair: polished) == nil)
        }
    }

    @Test("an item a neighbour shares words with is judged by the words it has to itself (fails without the fix)")
    func sharedWords() {
        let draft = "Fix the login bug fix the upload bug before the demo."
        #expect(RepeatedFrame.firstItemWords(words(draft)) == ["login"])
    }

    // MARK: what a merge may and may not do

    @Test("an answer that keeps both items passes at both levels", arguments: [
        ("We should cancel the Tuesday sync we should cancel the Friday retro and use that time for planning.",
         "We should cancel the Tuesday sync and the Friday retro and use that time for planning."),
        ("We should cancel the Tuesday sync we should cancel the Friday retro and use that time for planning.",
         "We should cancel the Tuesday sync and cancel the Friday retro and use that time for planning."),
        ("They need to fix the login bug they need to fix the upload bug before the demo.",
         "They need to fix the login bug. They need to fix the upload bug before the demo."),
        ("Ask the vendor to resend the invoice ask the vendor to correct the tax number by Wednesday.",
         "Ask the vendor to resend the invoice and ask the vendor to correct the tax number by Wednesday."),
    ])
    func allowsBothItems(draft: String, answer: String) {
        for polished in [false, true] {
            #expect(DisfluencyOnlyGuard.violation(answer: answer, raw: draft, draft: draft, grammarRepair: polished) == nil)
        }
    }

    @Test("the copy check rejects a clause copied in again and accepts a legitimate expansion (fails without the fix and without the shape rule)")
    func copyCheckIsNarrow() {
        // A clause copied in again: rejected, at the guard's front door.
        let copiedDraft = "I mostly use the terminal for git. I mostly use the editor for debugging when the build breaks on my machine."
        let copied = "I mostly use the terminal for git and the editor for debugging when the build breaks on my machine and the build breaks on my machine."
        #expect(DisfluencyOnlyGuard.violation(answer: copied, raw: copiedDraft, draft: copiedDraft)?.hasPrefix("added content words") == true)
        // The verb said again per item, a list, and an inflected word are expansions, not copies.
        let expansions = [
            ("We should send the invoice we should send the receipt to Dana.", "We should send the invoice and send the receipt to Dana."),
            ("Fix the login bug fix the upload bug fix the signup bug before the demo.", "Fix the login bug, fix the upload bug and fix the signup bug before the demo."),
            ("What was Guo Shoujing one of the first of the Chinese name of Gou's calendar?", "What was Guo Shoujing one of the first Chinese names of Gou's calendar?"),
        ]
        for (draft, answer) in expansions {
            #expect(RepeatedFrame.violation(draftWords: words(draft), answerWords: words(answer)) == nil)
        }
    }

    @Test("an answer that drops a word of the opening, or adds an order word, did more than join (fails without the fix)", arguments: [
        ("Can you check the staging logs? Can you check the payment webhook before standup?",
         "Check the staging logs and the payment webhook before standup."),
        ("Please book a room for the Berlin team please book a room for the Lisbon team on the fourteenth.",
         "Please book a room for the Berlin team and then the Lisbon team on the fourteenth."),
        ("We need to hire a backend engineer in March we need to hire a designer in April.",
         "We need to hire a backend engineer in March and a designer in April, but first the budget."),
    ])
    func rejectsMoreThanAJoin(draft: String, answer: String) {
        #expect(DisfluencyOnlyGuard.violation(answer: answer, raw: draft, draft: draft) != nil)
    }

    // MARK: restarts, corrections and contrast stay as they were

    @Test("an unfinished first attempt is still a restart and may be dropped (fails without the shape rule)", arguments: [
        ("I was going to I wanted to ask about timestamps.", "I wanted to ask about timestamps."),
        ("Because that would be that would feel hostile.", "Because that would feel hostile."),
        ("So the report is so the issue is that the queue is stale.", "So the issue is that the queue is stale."),
        ("How did the or what did the team ship last week?", "How did the team ship last week?"),
        ("Send the inv send the invoice to Dana on Friday.", "Send the invoice to Dana on Friday."),
    ])
    func allowsUnfinishedRestart(draft: String, answer: String) {
        #expect(DisfluencyOnlyGuard.violation(answer: answer, raw: draft, draft: draft) == nil)
        #expect(RepeatedFrame.firstItemWords(words(draft)).isEmpty)
    }

    @Test("an attempt that stopped on a content word reads as an addition, on purpose (fails without the fix)")
    func contentWordEndingIsFinished() {
        let draft = "I want the red I want the blue one."
        #expect(GuardCode(reason: DisfluencyOnlyGuard.violation(answer: "I want the blue one.", raw: draft, draft: draft) ?? "") == .droppedContentWords)
    }

    @Test("a cue before or after the second opening makes it a correction (fails without the shape rule)", arguments: [
        ("Please send it Tuesday, no, send it Wednesday.", "Please send it Wednesday."),
        ("Book the hotel, I mean, book the hostel for the team.", "Book the hostel for the team."),
        ("Tell Marcus, no, tell Dana that the shipment is late.", "Tell Dana that the shipment is late."),
        ("Please send it Tuesday, send it Wednesday instead.", "Please send it Wednesday instead."),
        ("Book the hotel, book the hostel I mean, for the team tonight.", "Book the hostel for the team tonight."),
    ])
    func allowsCuedCorrection(draft: String, answer: String) {
        for polished in [false, true] {
            #expect(DisfluencyOnlyGuard.violation(answer: answer, raw: draft, draft: draft, grammarRepair: polished) == nil)
        }
        #expect(RepeatedFrame.firstItemWords(words(draft)).isEmpty)
    }

    @Test("a retraction verb said right after another clause is still a cue, a plain verb is not (fails without the shape rule)")
    func verbCueBoundary() {
        let retraction = words("Invite Sam and Jordan to dinner, cancel Jordan.")
        #expect(!DisfluencyOnlyGuard.isPlainVerb(retraction, at: retraction.firstIndex(of: "cancel")!))
        #expect(DisfluencyOnlyGuard.violation(answer: "Invite Sam to dinner.", raw: "", draft: "Invite Sam and Jordan to dinner, cancel Jordan.") == nil)
        let plain = words("We should cancel the Tuesday sync")
        #expect(DisfluencyOnlyGuard.isPlainVerb(plain, at: 2))
        let repeated = words("Cancel the Tuesday sync. Cancel the Friday retro.")
        #expect(DisfluencyOnlyGuard.isPlainVerb(repeated, at: 4))
    }

    // MARK: the closed lists

    @Test("an abandoned clause ends on a closed-class word, never on an open-class verb")
    func closedClassEnders() {
        for verb in ["want", "need", "going", "send", "cancel"] { #expect(!DisfluencyOnlyGuard.unfinishedEnders.contains(verb)) }
        for function in ["to", "the", "is", "and", "gonna", "what"] { #expect(DisfluencyOnlyGuard.unfinishedEnders.contains(function)) }
    }

    // MARK: the note and the second model's answer

    @Test("the second model is told about an opening said twice after a finished clause", arguments: [
        "We should cancel the Tuesday sync. We should cancel the Friday retro and use that time for planning.",
        "Can you check the staging logs? Can you check the payment webhook before standup?",
        "Ask the vendor to resend the invoice. Ask the vendor to correct the tax number by Wednesday.",
    ])
    func promptsRepeatedOpening(text: String) {
        let prompt = RepeatedFrame.prompt(for: text)
        #expect(prompt != nil)
        #expect(prompt?.note.contains("a question stays a question") == true)
        #expect(prompt?.note.contains("add no word that orders") == true)
    }

    @Test("no prompt for a restart, a cued correction, a sequence, a contrast, a short shared opening or no repeat", arguments: [
        "I was going to I wanted to ask about timestamps.",
        "Please send it Tuesday, no, send it Wednesday so they can close the month.",
        "Please send it Tuesday, send it Wednesday instead so they can close the month.",
        "I think the report is late. I think we should wait for the numbers.",
        "We should cancel the Tuesday sync and use that time for planning on Friday.",
        "First we ship to ten percent, then we ship to half, then we ship to everyone.",
        "Some users want the summary shorter. But some users want the summary longer.",
    ])
    func noPrompt(text: String) {
        #expect(RepeatedFrame.prompt(for: text) == nil)
    }
}
