import Foundation
import Synchronization
import Testing
@testable import MurmurCore

@Suite("Diarized re-summary: transcript and merge rules")
struct DiarizedDigestMergeTests {
    static let first = Note(
        id: 1, title: "Sprint planning", transcript: "the transcript", summary: "- Crash rate",
        actionItems: ["Fix the login crash — Wednesday", "Write the test plan", "Send the mockups"], status: .ready)
    static let labelled = ExtractiveSummarizer.Output(
        title: "Sprint planning: login crash and release date", summary: "- Crash rate\n- Decided: Release on the 19th",
        actionItems: ["Marcus: Fix the login crash — Wednesday", "Leo: Write the regression test plan", "Dana: Send the mockups to Marcus — Friday"])

    static func segment(_ label: String?, _ text: String, _ ordinal: Int) -> NoteSegmentWithSpeaker {
        NoteSegmentWithSpeaker(
            segment: NoteSegment(noteId: 1, speakerId: nil, startTime: Double(ordinal), endTime: Double(ordinal) + 1, text: text, ordinal: ordinal),
            speaker: label.map { NoteSpeaker(noteId: 1, label: $0) })
    }

    @Test("segments render as speaker turns, consecutive turns joined, renamed speakers by name")
    func transcript() {
        var renamed = Self.segment("Speaker 2", "Yes.", 2)
        renamed = NoteSegmentWithSpeaker(segment: renamed.segment, speaker: NoteSpeaker(noteId: 1, label: "Speaker 2", displayName: "Marcus"))
        let text = DiarizedDigest.transcript(from: [
            Self.segment("Speaker 1", "Can you take it?", 0), Self.segment("Speaker 1", "By Wednesday.", 1), renamed,
        ])
        #expect(text == "Speaker 1: Can you take it? By Wednesday.\nMarcus: Yes.")
    }

    @Test("fewer than two speakers: no labelled transcript (keep the first summary)")
    func oneSpeaker() {
        #expect(DiarizedDigest.transcript(from: []) == nil)
        #expect(DiarizedDigest.transcript(from: [Self.segment("Speaker 1", "a", 0), Self.segment("Speaker 1", "b", 1)]) == nil)
        #expect(DiarizedDigest.transcript(from: [Self.segment("You", "a", 0), Self.segment(nil, "b", 1)]) == nil)
    }
}
