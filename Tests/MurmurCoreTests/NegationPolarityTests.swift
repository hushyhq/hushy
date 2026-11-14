import Foundation
import Testing
@testable import MurmurCore

/// A rewrite may put a limit the speaker stated ("too busy") as a negation ("I don't have the bandwidth"), and may say
/// "can't" as "unable to". It may not put a "not" where nothing the speaker said stands behind it. Each test pairs what
/// the answer may do with what it may not, so each fails when the allowance is removed or made too wide. Every line is
/// invented.
@Suite("Negation that is wording and negation that flips the meaning")
struct NegationPolarityTests {
    private func added(_ answer: String, _ draft: String) -> Bool {
        NegationPolarity.addsNegation(answer: answer, draft: draft)
    }

    /// The reason the whole-transcript check gives, which is the one the log line shows.
    private func intentReason(_ answer: String, _ raw: String, register: IntentRegister? = .professional) -> String? {
        if case .rejected(let reason) = IntentOutputGuard.check(answer, raw: raw, register: register) { return reason }
        return nil
    }

    // MARK: A stated limit worded as a negation

    @Test("a limit the speaker stated, worded as a decline, is not an added negation")
    func limitReworded() {
        #expect(!added("I don't have the bandwidth to take on this task right now.",
                       "i'm too busy to take on the task right now"))
        #expect(!added("I do not have the capacity to take that on this week.",
                       "i'm completely swamped this week so i'll pass on that one"))
        #expect(!added("I'm unable to join, as my schedule is full.", "my plate is full so i'm out for the sync"))
        #expect(!added("I can't take on another project this sprint.", "i'm slammed this sprint so another project is too much"))
        #expect(!added("I don't have the energy for it tonight.", "i'm too tired for it tonight"))
    }

    @Test("a mumbled line with restarts and a stated limit goes through the whole-transcript check")
    func mumbledLineThroughTheCheck() {
        let raw = "hey um so about that task you sent over i i'm just honestly way too busy right now like totally swamped with the launch stuff and uh yeah next month maybe"
        let answer = "About the task you sent over, I don't have the bandwidth to take it on right now, as I am fully occupied with the launch. Next month may work."
        #expect(intentReason(answer, raw) == nil)
        #expect(intentReason(answer, raw, register: nil) == nil)
    }

    @Test("a limit pays for one negation, not for two")
    func limitPaysOnce() {
        #expect(added("I don't have the bandwidth and I won't be able to join the review either.",
                      "i'm too busy right now so the review is something i'd like to join"))
    }

    @Test("a limit the answer still states in the same word pays for nothing")
    func keptLimitDoesNotPay() {
        #expect(added("I'm busy and I can't do it.", "i'm busy but i can do it"))
        #expect(added("I'm tired and I don't want the meeting.", "i'm tired but i want the meeting"))
    }

    // MARK: Words that say no without "not"

    @Test("can't and unable to are the same polarity in both directions")
    func cantAndUnable() {
        #expect(!added("I'm unable to make it tomorrow.", "i can't make it tomorrow"))
        #expect(!added("I can't make it tomorrow.", "i'm unable to make it tomorrow"))
        #expect(!added("I won't be able to attend, I'm afraid.", "i'm unable to attend i'm afraid"))
        #expect(!added("We can't finish by Friday.", "finishing by friday is impossible"))
        #expect(!added("I don't know anything about it.", "i know nothing about it"))
        #expect(!added("Nobody has replied yet.", "no one has replied yet"))
    }

    @Test("unable to and the other no-words count as negation, so they cannot be added either")
    func noWordsCount() {
        #expect(NegationPolarity.count(in: "I'm unable to make it.") == 1)
        #expect(NegationPolarity.count(in: "That is impossible.") == 1)
        #expect(NegationPolarity.count(in: "Nobody knows nothing.") == 2)
        #expect(added("I'm unable to do it.", "i can do it"))
        #expect(added("It is impossible to send it.", "we can send it"))
    }

    // MARK: A real flip stays refused

    @Test("a polarity flip with nothing the speaker said behind it is refused")
    func flipsRefused() {
        #expect(added("I can't do it.", "i can do it"))
        #expect(added("Don't send it.", "send it"))
        #expect(added("We should not hire him.", "we should hire him"))
        #expect(added("I'm not happy with the proposal.", "i'm happy with the proposal"))
        #expect(added("It doesn't work.", "it works"))
        #expect(added("I'm unable to attend.", "i'll attend"))
    }

    @Test("a flip is refused by the whole-transcript check under every register, with the reason the log shows")
    func flipsRefusedByTheCheck() {
        for register in [IntentRegister.professional, .casual, .prompt] {
            #expect(intentReason("I can't do it by Friday.", "i can do it by friday", register: register) == "added negation")
            #expect(intentReason("Don't send the file to Marcus.", "send the file to marcus", register: register) == "added negation")
        }
        #expect(intentReason("I can't do it by Friday.", "i can do it by friday", register: nil) == "added negation")
    }

    // MARK: A negation the answer keeps in other words

    private func dropped(_ answer: String, _ said: String) -> Bool {
        NegationPolarity.dropsNegation(answer: answer, said: said)
    }

    @Test("a stuttered negation is said once", arguments: [
        ("we don't we don't need the report", "We don't need the report."),
        ("it doesn't it doesn't work", "It doesn't work."),
        ("I can't I won't make it", "I won't make it."),
        ("we do not, we do not need it", "We do not need it."),
    ])
    func stutteredNegation(_ said: String, _ answer: String) {
        #expect(!dropped(answer, said))
        #expect(intentReason(answer, said, register: nil) == nil)
    }

    @Test("a stuttered negation still may not be dropped altogether", arguments: [
        ("we don't we don't need the report", "We need the report."),
        ("I can't I won't make it", "I will make it."),
        ("do not do that", "Do that."),
    ])
    func stutteredNegationDropped(_ said: String, _ answer: String) {
        #expect(dropped(answer, said))
    }

    @Test("an antonym, an idiom or a resolved double negative keeps the meaning", arguments: [
        ("I don't agree with the plan", "I disagree with the plan."),
        ("I can't wait to see the demo", "I look forward to seeing the demo."),
        ("don't hesitate to reach out", "Feel free to reach out."),
        ("I'm not sure about the date", "I'm unsure about the date."),
        ("let me know whether or not you can come", "Let me know whether you can come."),
        ("I'm no longer on that team", "I'm not on that team anymore."),
        ("it's nothing but noise", "It's only noise."),
        ("I don't want tea nor coffee", "I don't want tea or coffee."),
        ("I can't not go to the wedding", "I have to go to the wedding."),
    ])
    func rewordedNegation(_ said: String, _ answer: String) {
        for register in [IntentRegister.professional, .casual] {
            #expect(intentReason(answer, said, register: register) == nil, "\(register)")
        }
    }

    @Test("the same idioms flipped are still refused", arguments: [
        ("I don't agree with the plan", "I agree with the plan."),
        ("I'm not sure about the date", "I'm sure about the date."),
        ("we can't wait for the vendor", "We can wait for the vendor."),
        ("I can't not go to the wedding", "I can go to the wedding."),
        ("I can't not go to the wedding", "I can't go to the wedding."),
    ])
    func rewordedNegationFlipped(_ said: String, _ answer: String) {
        #expect(dropped(answer, said))
    }

    @Test("a no after any verb in the answer is a negation", arguments: [
        ("there was no response", "We received no response."),
        ("I have no idea", "I've no idea."),
    ])
    func writtenNo(_ said: String, _ answer: String) {
        #expect(!dropped(answer, said))
        #expect(dropped("There was a response.", "there was no response"))
    }

    @Test("mustn't, needn't, shan't and ain't say no")
    func moreNegators() {
        for word in ["mustn't", "needn't", "shan't", "ain't"] {
            #expect(NegationPolarity.count(in: "we \(word) go") == 1, "\(word)")
            #expect(dropped("We go.", "we \(word) go"), "\(word)")
        }
    }

    @Test("a cue takes back only the words between the negation and it, and not when the answer keeps the cue")
    func takeBackReach() {
        #expect(dropped("The demo is ready, sorry, I have to run.", "the demo is not ready to ship sorry I have to run"))
        #expect(dropped("The demo is ready to ship, sorry, I have to run.", "frankly the demo is not ready to ship sorry I have to run"))
        #expect(!dropped("I can make it.", "I can't make it, actually I can"))
        #expect(!dropped("I do want it.", "I don't want it, actually I do"))
        #expect(!dropped("We ship in November.", "We do not ship in June, hold on, November."))
    }

    // MARK: The older cleanup path judges it the same way

    @Test("the group path reads a stated limit and an unable-to the same way")
    func groupPath() {
        #expect(CriticalTokenGuard.violation(
            answer: "I don't have the time for this.", draft: "I'm too busy for this.") == nil)
        #expect(CriticalTokenGuard.violation(answer: "I'm unable to join.", draft: "I can't join.") == nil)
        #expect(CriticalTokenGuard.violation(answer: "I can't do it.", draft: "I can do it.") == "added negation")
    }
}
