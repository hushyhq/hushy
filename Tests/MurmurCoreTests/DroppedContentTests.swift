import Foundation
import Testing
@testable import MurmurCore

/// An answer from the whole-transcript model may not leave out what the speaker said (a noun, verb, name or adjective)
/// and put nothing in its place. It may leave out fillers, stutters, restarts, what a correction takes back, adverbs,
/// and a word it words another way. Each test pairs what the answer may do with what it may not. Every line is invented.
@Suite("Content the speaker said that an answer leaves out")
struct DroppedContentTests {
    private let handOver = "go with your recommendations this is a product that we both are building so whatever you think is the best success for our app and i go with that"
    private let handOverLosingTheApp = "Go with your recommendations. This is a product we both are building, so whatever you think is the best success for, and I go with that."

    // MARK: What is lost

    @Test("a noun the answer dropped with nothing in its place is lost")
    func nounDropped() {
        #expect(DroppedContent.lost(answer: handOverLosingTheApp, raw: handOver) == ["app"])
        #expect(DroppedContent.violation(answer: handOverLosingTheApp, raw: handOver)?.hasPrefix("dropped content words") == true)
        #expect(GuardCode(reason: DroppedContent.violation(answer: handOverLosingTheApp, raw: handOver) ?? "") == .droppedContentWords)
    }

    @Test("an adjective or a name gone from the middle of a clause is lost, a tail taken out whole is the model's choice")
    func holeOrTail() {
        #expect(DroppedContent.lost(answer: "Send the folder to Marcus.", raw: "send the blue folder to marcus") == ["blue"])
        #expect(DroppedContent.lost(answer: "Send the blue folder to the manager.", raw: "send the blue folder to marcus the manager") == ["marcus"])
        // Taken out whole with the sentence closed behind it: a purpose phrase, a trailing "to Marcus", a clause at the start.
        #expect(DroppedContent.lost(answer: "Send the blue folder.", raw: "send the blue folder to marcus").isEmpty)
        #expect(DroppedContent.lost(answer: "Send the outline.", raw: "send the outline to prepare for the review").isEmpty)
        #expect(DroppedContent.lost(answer: "I think we should wait.", raw: "the warehouse lost the revised schedule i think we should wait").isEmpty)
    }

    @Test("under a register only a noun or a name counts, which keeps a rewrite free to put a verb another way")
    func registerKeepsNounsAndNames() {
        let raw = "i need you to send the blue folder to marcus today"
        #expect(DroppedContent.lost(answer: "Could you send the folder to Marcus today?", raw: raw, register: .professional).isEmpty)
        #expect(DroppedContent.lost(answer: "Could you send the blue folder today?", raw: raw, register: .professional) == ["marcus"])
        #expect(DroppedContent.lost(answer: "Send the blue folder to today.", raw: "send the blue folder to marcus today", register: .professional) == ["marcus"])
    }

    @Test("fillers, stutters, restarts and a taken-back word are not lost")
    func disfluencyIsNotLoss() {
        #expect(DroppedContent.lost(answer: "I think we should send the invoice on Monday.",
                                    raw: "um so i i think we should uh send the the invoice on monday").isEmpty)
        #expect(DroppedContent.lost(answer: "Send it to Sarah on Friday.", raw: "send it to tom no sorry to sarah on friday").isEmpty)
        #expect(DroppedContent.lost(answer: "We should move the review to Thursday.",
                                    raw: "we should move the the review to to thursday you know").isEmpty)
        #expect(DroppedContent.lost(answer: "I need the report by Friday.", raw: "i need the rep the report by friday").isEmpty)
    }

    @Test("an adverb, a number worded as digits and a word in another form are not lost")
    func wordedAnotherWay() {
        #expect(DroppedContent.lost(answer: "I forgot about it.", raw: "i really completely forgot about it").isEmpty)
        #expect(DroppedContent.lost(answer: "I have 25 apples.", raw: "i have twenty five apples").isEmpty)
        #expect(DroppedContent.lost(answer: "Send the report.", raw: "send the reports").isEmpty)
        #expect(DroppedContent.lost(answer: "We cannot make it.", raw: "we can not make it").isEmpty)
    }

    @Test("a content word worded another way pays for the one it replaces")
    func swapPays() {
        #expect(DroppedContent.lost(answer: "I am swamped at the moment.", raw: "i am too busy right now").isEmpty)
        #expect(DroppedContent.lost(answer: "I am swamped right now.", raw: "i am swamped right now").isEmpty)
        #expect(DroppedContent.lost(answer: "That is not the responsibility of my team. Speak with the platform team.",
                                    raw: "that's not my team's responsibility talk to the platform folks").isEmpty)
    }

    @Test("a word that pays is one worded in the same place, not any new word elsewhere in the answer")
    func paymentIsLocal() {
        let raw = "i am gonna move the paper kite and we need the bell"
        #expect(DroppedContent.lost(answer: "I am going to move the paper and we need the bell.", raw: raw) == ["kite"])
        #expect(DroppedContent.restoring(answer: "I am going to move the paper and we need the bell.", raw: raw)
            == "I am going to move the paper kite and we need the bell.")
        #expect(DroppedContent.lost(answer: "I am gonna move the paper and we need a bell.", raw: raw) == ["kite"])
    }

    @Test("a dictation with a retraction in it is not read for losses, so a retracted word is never put back")
    func retractionIsLeftAlone() {
        let raw = "the contract renews in january ask ravi to review it the deck is ready sorry the contract renews in august"
        #expect(DroppedContent.lost(answer: "The contract renews in August. Ask Ravi to review it. The deck is ready.", raw: raw).isEmpty)
        #expect(DroppedContent.restoring(answer: "The contract renews in August. Ask Ravi to review it. The deck is ready.", raw: raw) == nil)
    }

    // MARK: Putting it back

    @Test("the dropped noun goes back between the two words that stood beside it")
    func restoredBetweenNeighbours() {
        let restored = DroppedContent.restoring(answer: handOverLosingTheApp, raw: handOver)
        #expect(restored == "Go with your recommendations. This is a product we both are building, so whatever you think is the best success for our app, and I go with that.")
        #expect(DroppedContent.lost(answer: restored ?? "", raw: handOver).isEmpty)
    }

    @Test("a run at the end of the dictation is a tail taken out whole, and is left alone")
    func tailLeftAlone() {
        #expect(DroppedContent.restoring(answer: "Send the invoice to Sam.", raw: "send the invoice to sam on friday afternoon") == nil)
    }

    @Test("a finished opening followed by a comma is left alone, an unfinished one is filled")
    func commaAfterFinishedOpening() {
        // "quick heads up" taken out of "Leo, quick heads up, I'm too busy": the opening is complete without it.
        #expect(DroppedContent.lost(answer: "Leo, I'm too busy to review the contract.", raw: "hey leo quick heads up i'm too busy to review the contract").isEmpty)
        #expect(DroppedContent.lost(answer: "Leo, I'm too busy to review the contract.", raw: "hey leo quick heads up i'm too busy to review the contract", register: .professional).isEmpty)
        // "for," cannot end a clause: the noun was there.
        #expect(DroppedContent.lost(answer: handOverLosingTheApp, raw: handOver) == ["app"])
    }

    @Test("it is put back only where both neighbours stand side by side in the answer, once")
    func placedOnlyWhenCertain() {
        // The dropped words open the text, or the neighbours moved apart: nothing places them.
        #expect(DroppedContent.restoring(answer: "The folder is on the desk.", raw: "marcus left the folder on the desk") == nil)
        #expect(DroppedContent.restoring(answer: "Pay by Friday.", raw: "the invoice for acme is overdue and i need it paid by friday") == nil)
        // The word before the run appears twice in the answer; the word after it says which.
        #expect(DroppedContent.restoring(answer: "Send it to Ana, then send it to Raj.", raw: "send it to ana then send it to the new manager raj")
            == "Send it to Ana, then send it to the new manager Raj.")
    }

    // MARK: Through the whole-transcript check

    @Test("the check puts the noun back and accepts, and leaves a clause the model took out whole alone")
    func throughTheCheck() {
        for register in [nil, IntentRegister.professional, .prompt] {
            guard case .accepted(let text, _) = IntentOutputGuard.check(handOverLosingTheApp, raw: handOver, register: register) else {
                Issue.record("a restorable loss was refused under \(String(describing: register))")
                continue
            }
            #expect(text.contains("for our app, and I go with that"))
        }
        // A clause the model takes out whole, with the sentence closed behind it, stays its choice.
        guard case .accepted(let omitted, _) = IntentOutputGuard.check(
            "Pay by Friday.", raw: "the invoice for acme is overdue and i need it paid by friday") else {
            Issue.record("an answer that closes the sentence behind what it left out was refused"); return
        }
        #expect(omitted == "Pay by Friday.")
    }

    @Test("an answer that keeps everything is untouched")
    func untouched() {
        let kept = "Go with your recommendations. This is a product we both are building, so whatever you think is the best success for our app, and I go with that."
        guard case .accepted(let text, _) = IntentOutputGuard.check(kept, raw: handOver) else { Issue.record("refused"); return }
        #expect(text == kept)
    }
}
