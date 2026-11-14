import Testing
@testable import MurmurCore

/// A register answer never leaves out a name the speaker said (founder, 2026-11-11; accuracy eval ppl-033 in the Claude app).
struct DroppedNameTests {
    @Test("a leading subject that names someone is not left out")
    func leadingNameStays() {
        let raw = "J Hai and Quan is out until next Monday so ping me instead"
        #expect(DroppedContent.dropsName(answer: "Ping me instead, as Quan is out until next Monday.", raw: raw))
        #expect(!DroppedContent.dropsName(answer: "J Hai and Quan are out until next Monday, so ping me instead.", raw: raw))
        if case .accepted = IntentOutputGuard.check("Ping me instead, as Quan is out until next Monday.", raw: raw, spellingWords: [],
                                                    register: .prompt) {
            Issue.record("a prompt answer that drops a name was accepted")
        }
    }

    @Test("a respelled name, an ordinary capital and a retraction are not losses")
    func notLosses() {
        #expect(!DroppedContent.dropsName(answer: "Alperen Şengün had 30 last night.", raw: "Alperen Shengun had 30 last night"))
        #expect(!DroppedContent.dropsName(answer: "Draft a reply to the landlord.", raw: "Can you draft a reply to the landlord"))
        #expect(!DroppedContent.dropsName(answer: "Send it to Ana.", raw: "send it to Marcus no sorry to Ana"))
        #expect(DroppedContent.names(in: "Can you loop in Neva Conquo Riley and the API team") == ["neva", "conquo", "riley"])
        // A name written together with the word beside it is still there.
        #expect(!DroppedContent.dropsName(answer: "I think DeAaron Fox is the best player.", raw: "I think De Aaron Fox is the best player"))
        #expect(!DroppedContent.dropsName(answer: "Jhai and Quan are out.", raw: "J Hai and Quan is out"))
    }

    @Test("without a register the name check is not run: the plain answer keeps its own checks")
    func onlyUnderARegister() {
        let raw = "J Hai and Quan is out until next Monday so ping me instead"
        if case .rejected(let reason) = IntentOutputGuard.check("Ping me instead, as Quan is out until next Monday.", raw: raw,
                                                               spellingWords: [], register: nil) {
            #expect(reason != DroppedContent.droppedNameReason)
        }
    }
}
