import MurmurCore
import Testing
@testable import Murmur

@Suite("Erase meetings wording")
struct MeetingEraseWordingTests {
    @Test("the button and the message count the notes the erase removes, and say what stays")
    func wordingMatchesPlan() {
        let plan = MeetingErasePlan(noteIDs: [4, 9, 12], audioBytes: 0)
        #expect(MeetingDataCard.meetings(plan.count) == "3 meetings")
        #expect(MeetingDataCard.meetings(1) == "1 meeting")
        let message = MeetingDataCard.eraseMessage(plan)
        #expect(message.hasPrefix("The 3 meetings Hushy recorded from a detected call"))
        #expect(message.contains("Memos, imported files and recordings you started yourself stay"))
    }
}
