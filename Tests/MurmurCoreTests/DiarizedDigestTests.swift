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

    @Test("untouched note: every field is replaced")
    func replacesUntouched() throws {
        let update = try #require(DiarizedDigest.merge(first: Self.first, current: Self.first, done: [], labelled: Self.labelled))
        #expect(update.replaced == [.title, .summary, .actionItems])
        #expect(update.note.actionItems == Self.labelled.actionItems)
        #expect(update.doneIndexes.isEmpty)
    }

    @Test("a renamed title and a re-generated summary stay the user's")
    func keepsEdits() throws {
        var current = Self.first
        current.title = "My title"
        current.summary = "- Something the user re-summarized"
        let update = try #require(DiarizedDigest.merge(first: Self.first, current: current, done: [], labelled: Self.labelled))
        #expect(update.replaced == [.actionItems])
        #expect(update.note.title == "My title")
        #expect(update.note.summary == "- Something the user re-summarized")
    }

    @Test("a title taken from the calendar meeting is not replaced by the speaker re-summary")
    func keepsCalendarTitle() throws {
        let update = try #require(DiarizedDigest.merge(
            first: Self.first, current: Self.first, done: [], labelled: Self.labelled, keepTitle: true))
        #expect(update.replaced == [.summary, .actionItems])
        #expect(update.note.title == Self.first.title)
    }

    @Test("changed action items stay; nothing else left to replace gives nil")
    func keepsChangedItems() {
        var current = Self.first
        current.title = "Mine"
        current.summary = "Mine"
        current.actionItems = ["Mine"]
        #expect(DiarizedDigest.merge(first: Self.first, current: current, done: [], labelled: Self.labelled) == nil)
    }

    @Test("checked-off items stay checked: moved to the labelled item for the same task, else kept")
    func keepsCheckOffs() throws {
        let labelled = ExtractiveSummarizer.Output(
            title: "T", summary: "S", actionItems: ["Marcus: Fix the login crash — Wednesday", "Priya: Book the retro"])
        // Item 0 (login crash) has a labelled match; item 2 (mockups) does not.
        let update = try #require(DiarizedDigest.merge(first: Self.first, current: Self.first, done: [0, 2], labelled: labelled))
        #expect(update.note.actionItems == ["Marcus: Fix the login crash — Wednesday", "Priya: Book the retro", "Send the mockups"])
        #expect(update.doneIndexes == [0, 2])
    }

    @Test("an empty labelled field never replaces a filled one")
    func emptyNeverReplaces() throws {
        let empty = ExtractiveSummarizer.Output(title: "", summary: "", actionItems: [])
        #expect(DiarizedDigest.merge(first: Self.first, current: Self.first, done: [], labelled: empty) == nil)
    }

    @Test("task matching ignores the owner prefix and the due suffix")
    func sameTask() {
        #expect(DiarizedDigest.sameTask("Speaker 2: Draft the pairing exercise — Monday", "Draft the pairing exercise"))
        #expect(!DiarizedDigest.sameTask("Ben: Draft the pairing exercise", "Book the retro room"))
    }
}

@Suite("Speaker name inference: capitalisation")
struct SpeakerNameInferenceCaseTests {
    @Test("lower-case words before a comma are not names")
    func lowercaseIsNotAName() {
        let transcript = """
            Speaker 1: Okay so for the kickoff, let's look at numbers.
            Speaker 2: Sure.
            Speaker 1: And beyond the kickoff, what else?
            Speaker 2: Budget.
            Speaker 1: This is Anita, by the way.
            """
        #expect(SpeakerNameInference.names(in: transcript).isEmpty)
    }
}
