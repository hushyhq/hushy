import Foundation
import Testing
@testable import MurmurCore

/// Covers `MeetingRecap`: what a shared recap contains and, as important, what it never does
/// (a pending voice suggestion, a calendar attendee, the transcript unless asked). Every note,
/// name and line here is invented.
@Suite("MeetingRecap")
struct MeetingRecapTests {
    private let utc = TimeZone(identifier: "UTC")!
    private let english = Locale(identifier: "en_US")

    private func note(
        title: String = "Q3 planning", summary: String = "- Ship the beta on 14 October\n- Decided: keep the free plan",
        actions: [String] = ["Dana to send the revised budget", "Write the launch note"],
        transcript: String = "We talked about the beta. Dana will send the budget.",
        status: Note.Status = .ready, duration: Double = 1_920
    ) -> Note {
        Note(
            id: 7, title: title, createdAt: Date(timeIntervalSince1970: 1_790_000_000),
            durationSeconds: duration, transcript: transcript, summary: summary,
            actionItems: actions, status: status)
    }

    private func speaker(
        _ label: String, name: String? = nil, suggested: Int64? = nil, voice: Int64? = nil
    ) -> NoteSpeaker {
        NoteSpeaker(
            id: Int64(abs(label.hashValue % 1000)), noteId: 7, label: label, displayName: name,
            voiceId: voice, suggestedVoiceId: suggested, suggestedSimilarity: suggested == nil ? nil : 0.9)
    }

    private func recap(
        _ note: Note, speakers: [NoteSpeaker] = [], owner: String? = nil, transcript: Bool = false
    ) -> MeetingRecap? {
        MeetingRecap.make(
            from: note, speakers: speakers, ownerName: owner, includeTranscript: transcript,
            locale: english, timeZone: utc)
    }

    // MARK: Contents

    @Test("a ready note produces title, date, length, summary and action items")
    func fullRecap() throws {
        let text = try #require(recap(note())).plainText
        #expect(text.hasPrefix("Q3 planning\n"))
        #expect(text.contains("2026"))
        #expect(text.contains("32 min"))
        #expect(text.contains("Summary\n- Ship the beta on 14 October\n- Decided: keep the free plan"))
        #expect(text.contains("Action items\n- Dana to send the revised budget\n- Write the launch note"))
    }

    @Test("the transcript is left out by default and included only when asked")
    func transcriptSwitch() throws {
        let without = try #require(recap(note()))
        #expect(!without.plainText.contains("We talked about the beta"))
        #expect(!without.markdown.contains("We talked about the beta"))
        #expect(!without.html.contains("We talked about the beta"))
        #expect(without.transcript == nil)

        let with = try #require(recap(note(), transcript: true))
        #expect(with.plainText.contains("Transcript\nWe talked about the beta."))
        #expect(with.markdown.contains("## Transcript\n\nWe talked about the beta."))
        #expect(with.html.contains("We talked about the beta."))
    }

    @Test("an empty summary leaves no Summary heading")
    func emptySummary() throws {
        let value = try #require(recap(note(summary: "  \n ")))
        for output in [value.plainText, value.markdown, value.html] { #expect(!output.contains("Summary")) }
        #expect(value.plainText.contains("Action items"))
    }

    @Test("no action items leaves no Action items heading")
    func noActionItems() throws {
        let value = try #require(recap(note(actions: ["", "  "])))
        for output in [value.plainText, value.markdown, value.html] { #expect(!output.contains("Action items")) }
        #expect(value.plainText.contains("Summary"))
    }

    @Test("a note with nothing to share has no recap until the transcript is asked for")
    func nothingToShare() throws {
        let bare = note(summary: "", actions: [])
        #expect(recap(bare) == nil)
        #expect(try #require(recap(bare, transcript: true)).plainText.contains("Transcript"))
    }

    @Test("a single summary line is a paragraph, several are bullets")
    func summaryShape() throws {
        let one = try #require(recap(note(summary: "- The team agreed to pause the launch.")))
        #expect(one.plainText.contains("Summary\nThe team agreed to pause the launch."))
        #expect(one.markdown.contains("## Summary\n\nThe team agreed to pause the launch."))
        let many = try #require(recap(note(summary: "• One\n* Two\n- Three")))
        #expect(many.summaryPoints == ["One", "Two", "Three"])
        #expect(many.markdown.contains("- One\n- Two\n- Three"))
    }

    @Test("action items render as a checklist in Markdown and a list in HTML")
    func actionItemShapes() throws {
        let value = try #require(recap(note(actions: ["Call Priya"])))
        #expect(value.markdown.contains("- [ ] Call Priya"))
        #expect(value.html.contains("<li>Call Priya</li>"))
    }

    @Test("a note with no title still has a usable subject")
    func untitled() throws {
        let value = try #require(recap(note(title: "  ")))
        #expect(value.subject == "Meeting recap")
        #expect(value.plainText.hasPrefix("Meeting recap\n"))
    }

    @Test("a zero-length note shows no length")
    func noLength() throws {
        let value = try #require(recap(note(duration: 0)))
        #expect(value.lengthText.isEmpty)
        #expect(!value.plainText.contains(" · "))
    }

    // MARK: Readiness

    @Test("a note that is still recording, processing or failed has no recap", arguments: [
        Note.Status.recording, .processing, .failed,
    ])
    func notReady(status: Note.Status) {
        #expect(recap(note(status: status), transcript: true) == nil)
    }

    // MARK: Who was there

    @Test("only speakers the user named are listed")
    func confirmedOnly() throws {
        let people = [
            speaker("Speaker 1", name: "Dana"),
            speaker("Speaker 2"),
            speaker("Speaker 3", name: "Speaker 3"),
            speaker("Speaker 4", name: "  "),
        ]
        #expect(try #require(recap(note(), speakers: people)).attendees == ["Dana"])
    }

    @Test("a pending voice suggestion is never a name")
    func suggestionNeverShown() throws {
        let people = [speaker("Speaker 1", suggested: 4), speaker("Speaker 2", name: "Priya", suggested: 9)]
        let value = try #require(recap(note(), speakers: people))
        #expect(value.attendees == ["Priya"])
        #expect(!value.plainText.contains("Speaker 1"))
    }

    @Test("a remembered voice without a typed name is not a name either")
    func voiceWithoutNameNotShown() throws {
        let value = try #require(recap(note(), speakers: [speaker("Speaker 1", voice: 3)]))
        #expect(value.attendees.isEmpty)
        #expect(!value.plainText.contains("Who was there"))
    }

    @Test("the note owner's track is listed by name, never as You")
    func ownerTrack() throws {
        let named = try #require(recap(note(), speakers: [speaker("You"), speaker("Speaker 1", name: "Dana")], owner: "Ada"))
        #expect(named.attendees == ["Ada", "Dana"])
        let anonymous = try #require(recap(note(), speakers: [speaker("You"), speaker("Speaker 1", name: "Dana")], owner: " "))
        #expect(anonymous.attendees == ["Dana"])
        let labelled = try #require(recap(note(), speakers: [speaker("Ada"), speaker("Speaker 1", name: "Dana")]))
        #expect(labelled.attendees == ["Ada", "Dana"])
    }

    @Test("the same person named twice appears once")
    func deduplicated() throws {
        let people = [speaker("Speaker 1", name: "Dana"), speaker("Speaker 2", name: " dana ")]
        #expect(try #require(recap(note(), speakers: people)).attendees == ["Dana"])
    }

    @Test("the line appears in every output")
    func attendeeLine() throws {
        let value = try #require(recap(note(), speakers: [speaker("Speaker 1", name: "Dana"), speaker("Speaker 2", name: "Priya")]))
        #expect(value.plainText.contains("Who was there: Dana, Priya"))
        #expect(value.markdown.contains("**Who was there:** Dana, Priya"))
        #expect(value.html.contains("Who was there:"))
    }

    @Test("speakers come from the stored segments once each, in order, skipping unattributed ones")
    func speakersFromSegments() {
        let dana = NoteSpeaker(id: 1, noteId: 7, label: "Speaker 1", displayName: "Dana")
        let priya = NoteSpeaker(id: 2, noteId: 7, label: "Speaker 2", displayName: "Priya")
        func row(_ speaker: NoteSpeaker?) -> NoteSegmentWithSpeaker {
            NoteSegmentWithSpeaker(
                segment: NoteSegment(noteId: 7, speakerId: speaker?.id, startTime: 0, endTime: 1, text: "x", ordinal: 0),
                speaker: speaker)
        }
        let found = MeetingRecap.speakers(in: [row(priya), row(nil), row(dana), row(priya)])
        #expect(found.map(\.id) == [2, 1])
    }

    // MARK: Text handling

    @Test("a non-English note keeps its words, accents and scripts")
    func nonEnglish() throws {
        let value = try #require(recap(
            note(
                title: "Reunión de planificación", summary: "- 決定: 来月に延期する\n- Приоритет: безопасность",
                actions: ["María enviará el presupuesto", "مراجعة الخطة"], transcript: "Buenos días a todos."),
            speakers: [speaker("Speaker 1", name: "José")], transcript: true))
        for output in [value.plainText, value.markdown, value.html] {
            for fragment in ["Reunión de planificación", "決定: 来月に延期する", "Приоритет", "María enviará", "مراجعة الخطة", "José"] {
                #expect(output.contains(fragment))
            }
        }
    }

    @Test("HTML escapes markup in the user's words")
    func htmlEscapes() throws {
        let value = try #require(recap(note(title: "A & B <draft>", actions: ["Fix <script>alert(1)</script>"])))
        #expect(value.html.contains("A &amp; B &lt;draft&gt;"))
        #expect(!value.html.contains("<script>"))
    }

    @Test("long notes are carried whole, never truncated")
    func longText() throws {
        let items = (1...300).map { "Action item number \($0)" }
        let transcript = Array(repeating: "word", count: 60_000).joined(separator: " ")
        let value = try #require(recap(note(actions: items, transcript: transcript), transcript: true))
        #expect(value.actionItems.count == 300)
        #expect(value.plainText.contains("Action item number 300"))
        #expect(value.markdown.contains("- [ ] Action item number 300"))
        #expect(value.plainText.count > 300_000)
    }
}

@Suite("RecapMailto")
struct RecapMailtoTests {
    @Test("a short recap becomes a mailto link with subject and body and no recipient")
    func shortRecap() throws {
        let url = try #require(RecapMailto.url(subject: "Q3 & beta", body: "Line one\nLine two é"))
        #expect(url.scheme == "mailto")
        let parts = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false))
        #expect(parts.path.isEmpty)
        #expect(parts.queryItems?.first { $0.name == "subject" }?.value == "Q3 & beta")
        #expect(parts.queryItems?.first { $0.name == "body" }?.value == "Line one\r\nLine two é")
    }

    @Test("a recap too long for a mail link returns nil so the caller can fall back")
    func tooLong() {
        #expect(RecapMailto.url(subject: "Long", body: String(repeating: "word ", count: 20_000)) == nil)
    }
}
