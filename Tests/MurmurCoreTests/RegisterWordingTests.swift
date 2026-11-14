import Foundation
import Testing
@testable import MurmurCore

/// `RewriteAccount.isRewrite(under:)` for a register answer that keeps few letters: wording replaced, not content added
/// (`RegisterWording`). All text invented.
@Suite("Register wording: a reworded message passes, an invention or a reply does not")
struct RegisterWordingTests {
    private func account(_ answer: String, _ spoken: String) -> RewriteAccount {
        RewriteAccount.measure(answer, against: spoken)
    }

    private func passes(_ answer: String, _ spoken: String, register: IntentRegister = .professional) -> Bool {
        account(answer, spoken).isRewrite(under: register)
    }

    // MARK: Short messages reworded (TRY-97)

    private let urgent = "hey can you look at my yc application when you get a sec it's kind of urgent i'm submitting tonight"
    private let urgentReworded = "Would you please review my YC application when you get a chance? It is urgent as I am submitting tonight."
    private let friday = "hey tom so um friday's not gonna work for the launch we still have two things open can we push it to tuesday"
    private let fridayReworded = "Hi Tom, Friday won't work for the launch since we still have two items open. Could we move it to Tuesday?"

    @Test("a short message reworded keeps its register answer although it keeps under 60 letters")
    func shortRewordingsPass() {
        for (answer, spoken) in [(urgentReworded, urgent), (fridayReworded, friday)] {
            let measured = account(answer, spoken)
            #expect(!measured.isRewrite)
            #expect(measured.inOrderLetters < RewriteAccount.registerMinimumKeptLetters)
            #expect(measured.isRewrite(under: .professional))
            #expect(measured.isRewrite(under: .casual))
            #expect(measured.isRewrite(under: .prompt))
            #expect(!measured.isRewrite(under: nil))
        }
    }

    @Test("courtesy words and a polite verb in place of a plain one are wording")
    func politenessIsWording() {
        #expect(passes("Would you please read the lunch order?", "can you read the lunch order"))
        #expect(passes("Please review the meeting notes.", "check the meeting notes"))
        #expect(passes("Hi Priya, it was a pleasure meeting you yesterday. Would you be open to an introduction to your head of product?",
                       "hi priya really great meeting you yesterday i'd love an intro to your head of product if you're up for it"))
    }

    // MARK: Invention and replies stay refused

    @Test("a promise or an answer that was not said is refused in every register")
    func repliesAreRefused() {
        for register in IntentRegister.allCases {
            #expect(!passes("Yes, I will send you the report.", "can you send me the report", register: register))
            #expect(!passes("Sure, I can help with that.", "can you help me with the trip", register: register))
            #expect(!passes("I will update the draft in the left folder.", "to update the draft in the left folder", register: register))
        }
    }

    @Test("an invented first clause for a dictation that lost its start is refused")
    func inventedStartsAreRefused() {
        #expect(!passes("I would like to place an order for lunch.", "lunch order"))
        #expect(!passes("I am available tomorrow.", "free tomorrow"))
        #expect(!passes("We are opening a new office because the old one is out of date.", "new office because the old one is out of date"))
        #expect(!passes("Please send me the invoice.", "the invoice"))
        #expect(!passes("I have a ticket next month.", "my ticket next month"))
        #expect(!passes("Here are the meeting notes.", "meeting notes"))
    }

    @Test("a promise that fits under the plain bound is still refused when the speaker made none")
    func plainBoundDoesNotCarryAPromise() {
        let invented = account("I will update the draft in the left folder.", "to update the draft in the left folder")
        #expect(invented.isRewrite)
        #expect(invented.inventsSpeaker)
        #expect(invented.isRewrite(under: nil))
        for register in IntentRegister.allCases { #expect(!invented.isRewrite(under: register)) }
    }

    @Test("a polite first-person frame is not a new speaker; a statement about the speaker that was not made is")
    func politeFramesOnly() {
        #expect(passes("I would really appreciate your help with the invoice.", "help me with the invoice"))
        #expect(passes("Thank you for sending this over. I appreciate it.", "thanks for sending this over"))
        #expect(!account("I am available tomorrow.", "free tomorrow").isRewrite(under: .professional))
        #expect(!account("I'm in with the trip.", "me with the trip").isRewrite(under: .casual))
    }

    @Test("wishing or wanting is not promising: a promise written for a wish said is an invention")
    func aWishIsNotAPromise() {
        let wish = "hi priya really great meeting you yesterday i'd love an intro to your head of product if you're up for it"
        #expect(!passes("Hi Priya, it was a pleasure meeting you yesterday. I will send you an introduction to our head of product.", wish))
        #expect(passes("Hi Priya, it was a pleasure meeting you yesterday. I would love an introduction to your head of product.", wish))
    }

    @Test("a guess about the past is not a promise, and one verb in two tenses is not a new word")
    func guessesAndTenses() {
        #expect(passes("Could you add me to the planning thread? I must have missed the invite somehow.",
                       "can you add me to the planning thread i missed the invite somehow"))
        #expect(passes("Did you get a chance to review the proposal?", "did you got a chance to look at the proposal"))
        #expect(RegisterWording.sameVerb("got", "get"))
        #expect(!RegisterWording.sameVerb("got", "give"))
    }

    @Test("a first-person promise the speaker did make is not an invention")
    func saidPromisesStay() {
        #expect(passes(
            "Sorry for the delay on this; I will have the report to you by Wednesday.",
            "sorry for the delay on this i'll have the report to you by wednesday"))
    }

    @Test("a content word in place of a short word that was said is wording: 'unable' for 'can't', 'poor shape' for 'a mess'")
    func contentForFunctionWords() {
        // Professional answers the 4B gave and the bound refused, so the plain answer was pasted (2026-11-04).
        #expect(passes("This report is in poor shape. Please redo it by tomorrow.", "this report is a mess redo it by tomorrow"))
        #expect(passes("I do not have time for this at the moment.", "i don't have time for this right now"))
        #expect(passes("We are unable to hire anyone until March.", "we can't hire anyone until march"))
        #expect(passes("Tell Nguyen that the Postgres migration is complete.", "tell nguyen the postgres migration is done"))
        // A filler, pronoun, preposition or conjunction that is gone pays for nothing: a verb invented for a fragment stays refused.
        #expect(!passes("I would like to request a ticket to the printer room.", "um ticket to the printer room"))
        #expect(!passes("Could you send me the updated budget?", "me the updated budget"))
        #expect(!passes("Please send boxes to me.", "boxes for me"))
        #expect(!passes("Please contact me regarding the forecast.", "me about the forecast"))
        #expect(!passes("Please see the meeting notes from Friday.", "meeting notes on friday"))
        #expect(!passes("I would like to find this chart.", "me find this chart"))
        #expect(!passes("Would you have a free minute this week to discuss the new office?", "new office when you have a free minute this week"))
        #expect(!passes("I am out of the office, so I am using the team channel.", "team channel because i am out of the office"))
    }

    @Test("a content word added without one gone, or a word said twice that was said once, is refused")
    func additionsAndEchoes() {
        #expect(!passes("Please review the new contract before the meeting.", "the meeting"))
        #expect(!passes("The last page is the last page.", "the last page"))
    }

    @Test("a long list of added courtesy cannot carry a fragment")
    func courtesyIsBounded() {
        #expect(!passes("Would you please kindly be so good as to read this, thank you very much.", "read"))
    }

    // MARK: The account

    @Test("the account lists what is new, what is gone, and what is said twice")
    func accountWords() {
        let measured = account(urgentReworded, urgent)
        #expect(measured.newWords.contains("review"))
        #expect(measured.droppedWords.contains("look"))
        #expect(measured.repeatedWords.isEmpty)
        #expect(!measured.inventsSpeaker)
        #expect(account("The last page is the last page.", "the last page").repeatedWords == ["last", "page"])
        #expect(account("I am available tomorrow.", "free tomorrow").inventsSpeaker)
    }

    @Test("an account built from counts keeps its numbers and has no word lists")
    func countsOnly() {
        let built = RewriteAccount(words: 18, letters: 56, inOrder: 13, inOrderLetters: 38, elsewhere: 4, elsewhereLetters: 10)
        #expect(built.newWords.isEmpty && built.droppedWords.isEmpty && !built.inventsSpeaker)
        #expect(built.isRewrite)
    }

    @Test("the weights are pinned")
    func constants() {
        #expect(RewriteAccount.glueWeight == 2)
        #expect(RewriteAccount.registerWordingLooseness == 4)
        #expect(RewriteAccount.registerMinimumKeptLetters == 60)
    }

    // MARK: A commitment the speaker made (TRY-100)

    private let handOver = "go with your recommendations this is a product that we both are building so whatever you think is the best success for our app and i go with that"

    @Test("a first-person commitment the speaker made, written as a promise, is not a new speaker")
    func saidCommitmentWrittenAsPromise() {
        let answers = [
            "Go with your recommendations. This is a product we are both building, so whatever you think is best for the success of our app, I will go with that.",
            "Go with your recommendations. This is a product we are both building, so whatever you think is best for our app, I'll go with it.",
            "Go with your recommendations. This product is something we are both building, so I am going to go with whatever you think is best for our app.",
        ]
        for answer in answers {
            let measured = account(answer, handOver)
            #expect(!measured.inventsSpeaker, "\(answer)")
            for register in IntentRegister.allCases { #expect(measured.isRewrite(under: register), "\(register) \(answer)") }
        }
    }

    @Test("what the speaker cannot or will not do is a limit, not a promise")
    func negatedModalIsALimit() {
        let spoken = "hi dana um about the audit task uh i'm too busy to take it on right now i'm swamped with the quarterly close so maybe next month"
        let answer = "Hi Dana, I can't take on the audit task right now because I'm swamped with the quarterly close. Maybe next month?"
        #expect(!account(answer, spoken).inventsSpeaker)
        #expect(!account("I will not be able to attend the review.", "i'm not going to be able to attend the review").inventsSpeaker)
        #expect(!account("I cannot commit to the end of the month.", "i can't commit to the end of the month").inventsSpeaker)
        // A refusal where the speaker said nothing of themselves is still a new speaker.
        #expect(account("I can't help with that request.", "can you help me with the trip").inventsSpeaker)
        #expect(account("I will not be able to do that.", "free tomorrow").inventsSpeaker)
    }

    @Test("a promise of something the speaker did not say they do is still a new speaker")
    func unsaidPromiseStaysRefused() {
        #expect(account("I will review the draft.", "can you review the draft").inventsSpeaker)
        #expect(account("I will review the draft.", "i need you to review the draft").inventsSpeaker)
        #expect(account("I can send the files tonight.", "i go with that").inventsSpeaker)
        #expect(account("I will go with the second option.", "can you go with the second option").inventsSpeaker)
        // A speaker who says "I" about something else does not license a promise about this.
        #expect(account("I will book the room for Thursday.", "i think the room is too small for thursday").inventsSpeaker)
    }
}
