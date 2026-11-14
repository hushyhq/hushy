import Testing
@testable import MurmurCore

/// A speaker who restarts with the same words and changes one slot ("it was 12, it was 14"), or says the same stretch
/// twice ("isn't isn't fixed"), has taken the first copy back. With no cue word in the draft the guards counted the
/// first copy's number, negation or modal as lost and refused the right answer. They now read the draft without the
/// earlier copy when the answer keeps the later one, and hold the answer to what the speaker said.
/// The texts are invented; the guard reads their shape, not their words.
@Suite("A restarted frame is taken back")
struct RestartedFrameTests {
    private func verdict(_ answer: String, _ draft: String, polished: Bool) -> SmartCleaner.Refinement {
        OutputGuard.check(answer, raw: draft, draft: draft, profile: polished ? .grammarRepair : .disfluencyOnly)
    }

    private func accepts(_ answer: String, _ draft: String) -> Bool {
        [false, true].allSatisfy { verdict(answer, draft, polished: $0) == .accepted(answer) }
    }

    private func why(_ answer: String, _ draft: String) -> String {
        [false, true].map { "\(verdict(answer, draft, polished: $0))" }.joined(separator: " / ")
    }

    private func refuses(_ answer: String, _ draft: String) -> Bool {
        [false, true].allSatisfy { polished in
            if case .rejected = verdict(answer, draft, polished: polished) { return true }
            return false
        }
    }

    @Test("a frame said twice with one number replaced is answered with the later number", arguments: [
        ("Last I saw it was 14 and which are from the supplier.", "So last I saw it was 12 it was 14 and which are from the supplier"),
        ("I counted 38 tickets since the release.", "And I counted 40 I counted 38 tickets since the release"),
        ("Starting at 10:30 on Saturday if that works.", "Starting at 10 starting at 10:30 on Saturday if that works"),
        ("The test starts at two thirty so before then.", "The test starts at three the test starts at two thirty so before then"),
        ("The contract deadline is March fourteenth.", "The contract deadline is March twelfth the contract deadline is March fourteenth"),
        ("It is now on the 14th and the ground is confirmed.", "It is now on the 12th it is now on the 14th and the ground is confirmed"),
    ])
    func numberSlot(answer: String, draft: String) {
        #expect(accepts(answer, draft), "\(why(answer, draft))")
    }

    @Test("hesitation between two copies still permits a restart", arguments: [
        ("The estimate was 68.", "The estimate was 61 um the estimate was 68"),
        ("The estimate was 68.", "The estimate was 61 you know the estimate was 68"),
        // "i mean" signals an explicit correction to the cleaner, so it belongs to the cued-correction path.
        // The direct guard also treats its lower-case "i" as a dropped identifier in both profiles.
    ])
    func hesitation(answer: String, draft: String) {
        #expect(accepts(answer, draft), "\(why(answer, draft))")
    }

    @Test("a connective joins separate facts", arguments: [
        ("The balance was 53.", "The balance was 41 and the balance was 53"),
        ("The gauge read 8.", "The gauge read 6 then the gauge read 8"),
        ("The count reached 19.", "The count reached 17 also the count reached 19"),
        ("The limit is 90.", "The limit is 80 or the limit is 90"),
        ("Send 12 crates.", "Send 12 crates and send 12 crates"),
    ])
    func additiveFrames(answer: String, draft: String) {
        #expect(RestartedFrame.withoutEarlierCopies(draft) == nil)
        #expect(refuses(answer, draft), "\(why(answer, draft))")
    }

    @Test("adjacent entity labels and multiple changed slots are separate facts", arguments: [
        ("Suite 5 is reserved.", "Suite 3 is reserved suite 5 is reserved"),
        ("The cart held 5 boxes at 10.", "The cart held 4 boxes at 9 the cart held 5 boxes at 10"),
    ])
    func ambiguousFrames(answer: String, draft: String) {
        #expect(RestartedFrame.withoutEarlierCopies(draft) == nil)
        #expect(refuses(answer, draft), "\(why(answer, draft))")
    }

    @Test("three parallel sentences form an enumeration")
    func threeFrames() {
        let draft = "The tally was 1. The tally was 2. The tally was 3."
        #expect(RestartedFrame.withoutEarlierCopies(draft) == nil)
        #expect(refuses("The tally was 3.", draft), "\(why("The tally was 3.", draft))")
    }

    @Test("a stretch said twice, or a modal replaced by a modal, is said once")
    func repeatedStretchAndModal() {
        #expect(accepts("The streak counter bug isn't fixed, it's only hidden.", "The streak counter bug isn't isn't fixed it's only hidden"))
        #expect(accepts("So I should warn him it may slip.", "So I should warn him it might slip it may slip"))
        #expect(accepts("The first candidates should be with you within two weeks.", "The first candidates should be with you within two weeks within two weeks"))
        #expect(accepts("We are not getting involved.", "We are not we are not getting involved"))
    }

    @Test("the answer may not keep the earlier value, invent a number, or add a negation")
    func boundHolds() {
        let draft = "And I counted 40 I counted 38 tickets since the release"
        #expect(refuses("I counted 40 tickets since the release.", draft))
        #expect(refuses("I counted 39 tickets since the release.", draft))
        #expect(refuses("I did not count 38 tickets since the release.", draft))
        let modal = "So I should warn him it might slip it may slip"
        #expect(refuses("So I should warn him it will slip.", modal))
    }

    @Test("a repeat that is not a restart is untouched: other slots, one-word frames, emphasis, additions", arguments: [
        ("Eli wrote about 7 invoices.", "Dana called about 5 invoices Eli wrote about 7 invoices"),
        ("The broken ones are dock 14 at Riverside.", "The broken ones are dock 12 dock 14 at Riverside"),
        ("We need 4 tables.", "We need 3 chairs we need 4 tables"),
        ("We should cancel the Friday retro.", "We should cancel the Tuesday sync we should cancel the Friday retro"),
        ("That was hot.", "That was very very hot"),
    ])
    func notARestart(answer: String, draft: String) {
        #expect(refuses(answer, draft), "\(answer)")
    }

    @Test("an answer that keeps both copies is still accepted")
    func keepingBothIsFine() {
        let draft = "So last I saw it was 12 it was 14 and which are from the supplier"
        #expect(accepts("So last I saw it was 12, it was 14, and which are from the supplier.", draft))
    }

    @Test("the earlier copy is the one removed, and only a restart has one")
    func earlierCopy() {
        #expect(RestartedFrame.withoutEarlierCopies("Last I saw it was 12, it was 14, and then") == "Last I saw it was 14, and then")
        #expect(RestartedFrame.withoutEarlierCopies("The bug isn't isn't fixed") == "The bug isn't fixed")
        #expect(RestartedFrame.withoutEarlierCopies("The broken ones are dock 12 dock 14 at Riverside") == nil)
        #expect(RestartedFrame.withoutEarlierCopies("That was very very hot") == nil)
        #expect(RestartedFrame.withoutEarlierCopies("We should cancel the Tuesday sync we should cancel the Friday retro") == nil)
    }
}
