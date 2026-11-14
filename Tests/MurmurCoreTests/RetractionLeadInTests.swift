import Testing
@testable import MurmurCore

@Suite("RetractionMerge lead-in")
struct RetractionLeadInTests {
    @Test("the verb before a two-item list isn't mistaken for part of the first item")
    func verbLeadIn() {
        #expect(RetractionMerge.apply("Invite Tom and Priya to the meeting, actually not Tom, he's on vacation this week.")
                == "Invite Priya to the meeting. Not Tom, he's on vacation this week.")
    }

    @Test("an unrelated sentence is still left alone")
    func noFalseMerge() {
        #expect(RetractionMerge.apply("Invite Tom and Priya to the meeting, actually it's at noon, not ten.") == nil)
    }
}
