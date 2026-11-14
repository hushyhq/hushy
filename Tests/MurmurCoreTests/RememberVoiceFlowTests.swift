import Testing
@testable import MurmurCore

@Suite("Remember a speaker's voice: who is offered, and the consent steps")
struct RememberVoiceFlowTests {
    private func speaker(
        _ label: String = "Speaker 1", name: String? = "Dana", voiceId: Int64? = nil
    ) -> NoteSpeaker {
        NoteSpeaker(id: 1, noteId: 1, label: label, displayName: name, voiceId: voiceId)
    }

    private func evaluate(
        _ speaker: NoteSpeaker, others: [NoteSpeaker] = [], stream: SpeakerAudioStream? = .mic, entitled: Bool = true
    ) -> RememberVoiceAvailability {
        RememberVoiceAvailability.evaluate(
            speaker: speaker, in: [speaker] + others, audioStream: stream, entitled: entitled)
    }

    @Test("a named speaker with retained audio is offered")
    func offeredWhenNamed() {
        #expect(evaluate(speaker()) == .available)
    }

    @Test("an unnamed or still-generic speaker is never offered")
    func hiddenWithoutARealName() {
        #expect(evaluate(speaker(name: nil)) == .hidden)
        #expect(evaluate(speaker(name: "   ")) == .hidden)
        #expect(evaluate(speaker(name: "Speaker 2")) == .hidden)
        #expect(evaluate(speaker(name: "speaker 12")) == .hidden)
    }

    @Test("a speaker already linked to a remembered voice is not offered again")
    func hiddenWhenLinked() {
        #expect(evaluate(speaker(voiceId: 4)) == .hidden)
    }

    @Test("the note owner's own track (a non-generic label) is never offered")
    func hiddenForTheMicOwner() {
        #expect(evaluate(speaker("You", name: "Dana")) == .hidden)
    }

    @Test("without the voice-signature entitlement nothing is offered")
    func hiddenWithoutEntitlement() {
        #expect(evaluate(speaker(), entitled: false) == .hidden)
    }

    @Test("gone audio is reported so the menu can explain, not silently hidden")
    func audioGone() {
        #expect(evaluate(speaker(), stream: nil) == .audioGone)
    }

    @Test("in a two-channel note only the system stream carries the other speakers")
    func twoChannelNeedsTheSystemStream() {
        let owner = speaker("You", name: nil)
        #expect(evaluate(speaker(), others: [owner], stream: .mic) == .audioGone)
        #expect(evaluate(speaker(), others: [owner], stream: .system) == .available)
    }

    @Test("consent steps: nothing happens until the user says yes")
    func consentSteps() {
        var flow = RememberVoiceFlow.idle
        #expect(flow.confirmed() == .idle)  // a stray confirm with no question asked does nothing
        flow = flow.requested()
        #expect(flow == .asking)
        #expect(flow.cancelled() == .idle)
        #expect(flow.confirmed() == .working)
        #expect(flow.confirmed().finished(.remembered(voiceId: 3, updatedExisting: false)) == .remembered)
        #expect(flow.confirmed().finished(.declined("Not enough speech")) == .declined("Not enough speech"))
    }

    @Test("a result that arrives when no work was started is ignored")
    func finishedOnlyFromWorking() {
        #expect(RememberVoiceFlow.asking.finished(.remembered(voiceId: 1, updatedExisting: false)) == .asking)
        #expect(RememberVoiceFlow.idle.finished(.declined("x")) == .idle)
    }

    @Test("after a decline the user can ask again")
    func canAskAgainAfterDecline() {
        #expect(RememberVoiceFlow.declined("x").requested() == .asking)
        #expect(RememberVoiceFlow.working.requested() == .working)
    }
}
