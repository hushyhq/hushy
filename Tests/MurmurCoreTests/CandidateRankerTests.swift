import Testing
@testable import MurmurCore

@Suite("CandidateRanker")
struct CandidateRankerTests {
    @Test("model wins when it resolves the correction")
    func modelResolves() {
        let raw = "Let's get pizza tonight, hmm, actually sushi sounds better"
        #expect(CandidateRanker.prefersModel(raw: raw, rules: "Let's get pizza tonight actually sushi sounds better",
                                             model: "Let's get sushi tonight."))
    }

    @Test("rules win when the model leaves more correction residue")
    func rulesWinOnResidue() {
        let raw = "I need two carrots, two beans, no, just one carrot"
        #expect(!CandidateRanker.prefersModel(raw: raw, rules: "I need just one carrot",
                                              model: "I need two carrots, two beans, no, just one carrot."))
    }

    @Test("rules win when the model undoes their fixes")
    func rulesWinWhenModelReverts() {
        let raw = "set the timer for twenty five minutes"
        #expect(!CandidateRanker.prefersModel(raw: raw, rules: "Set the timer for 25 minutes.",
                                              model: "Set the timer for twenty five minutes."))
    }

    @Test("an opening No is an answer, not residue")
    func openingNo() {
        #expect(CandidateRanker.residue("No, I don't think so.") == 0)
        #expect(CandidateRanker.residue("Blue, no, green.") == 1)
    }
}
