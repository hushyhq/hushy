import Foundation
import Testing
@testable import MurmurCore

@Suite("Intent names from person block")
struct PersonBlockNameGuardTests {
    @Test("a sound alike in place takes the spelling on any content line")
    func spokenRepair() {
        let raw = "Ask feylora to review the draft."
        let answer = "Ask Veylora to review the draft."
        let blocks = [
            PersonBlock(terms: ["Veylora"]),
            PersonBlock(earlier: ["Veylora reviewed it yesterday"]),
            PersonBlock(edits: [("Feylora reviewed it", "Veylora reviewed it")]),
            PersonBlock(screen: "Draft for Veylora"),
        ]
        #expect(IntentOutputGuard.check(answer, raw: raw) == .rejected("changed name"))
        for block in blocks {
            #expect(IntentOutputGuard.check(answer, raw: raw, block: block) == .accepted(answer))
        }
        let split = "Send the note to ner uh lo ra today."
        let joined = "Send the note to Nerulora today."
        #expect(IntentOutputGuard.check(joined, raw: split) == .rejected("changed name"))
        #expect(IntentOutputGuard.check(joined, raw: split, block: PersonBlock(terms: ["Nerulora"])) == .accepted(joined))
        let shortSound = "Ask eeva to bring the notes."
        let shortAnswer = "Ask Aovia to bring the notes."
        #expect(IntentOutputGuard.check(shortAnswer, raw: shortSound) == .rejected("changed name"))
        #expect(IntentOutputGuard.check(shortAnswer, raw: shortSound, block: PersonBlock(terms: ["Aovia"])) == .accepted(shortAnswer))
    }

    @Test("a block cannot introduce a name, move it, or bypass other checks")
    func held() {
        let block = PersonBlock(terms: ["Veylora"])
        #expect(IntentOutputGuard.check("Ask Veylora to review it.", raw: "Ask the team to review it.", block: block) == .rejected("changed name"))
        #expect(IntentOutputGuard.check("Veylora should review the draft.", raw: "The draft should go to feylora.", block: block) == .rejected("changed name"))
        #expect(IntentOutputGuard.check("Ask Veylora not to review it.", raw: "Ask feylora to review it.", block: block) == .rejected("added negation"))
        #expect(IntentOutputGuard.check("Ask Veylora to review 12 drafts.", raw: "Ask feylora to review two drafts.", block: block) == .rejected("changed digits"))
    }

    @Test("prompt and guard see the same block; no block keeps the old prompt")
    func prompt() {
        let block = PersonBlock(terms: ["Veylora"])
        #expect(IntentCleanupPrompt.user(transcript: "ask feylora", block: block) ==
            "About this person\nWords they use: Veylora\nTranscript: ask feylora\nOutput:")
        #expect(IntentCleanupPrompt.user(transcript: "ask feylora") == "Transcript: ask feylora\nOutput:")
    }
}
