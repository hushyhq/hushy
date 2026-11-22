import Foundation
import MurmurCore

/// Invented meetings for the Meetings snapshots and tests: a pricing call with a customer, the
/// intro before it, a design review and a 1:1, one still being written up, and a call that is
/// live. No real person, company or recording.
@MainActor
enum MeetingFixtures {
    struct Seeded {
        var pricing: Int64?
        var processing: Int64?
    }

    static let pricingTitle = "Acme pilot pricing"

    static func upcoming(now: Date) -> CalendarEvent {
        CalendarEvent(
            eventIdentifier: "fixture-acme-followup", title: "Acme follow-up", start: now.addingTimeInterval(25 * 60),
            end: now.addingTimeInterval(55 * 60),
            attendees: [CalendarAttendee(name: "Sam Lee", isCurrentUser: true, status: .accepted),
                        CalendarAttendee(name: "Dana Kim", status: .accepted), CalendarAttendee(name: "Lee Park", status: .tentative)],
            locationAndURL: "https://zoom.us/j/000")
    }

    @discardableResult
    static func seed(into store: Store, now: Date) -> Seeded {
        var seeded = Seeded()
        let intro = save(store, title: "Acme intro", at: now.addingTimeInterval(-8 * 86_400 - 3_600), minutes: 28, app: .zoom,
                         summary: "- Acme wants fewer handoffs between sales and support\n- Decided: start with a two-week pilot",
                         items: [ActionItemDetail(owner: "You", task: "Send Dana the pilot plan", due: "by Monday")],
                         people: ["Dana Kim"], done: [0],
                         lines: [("Dana Kim", "We keep losing context between sales and support, that's the real pain."),
                                 ("You", "Then a two-week pilot with your support team makes sense."),
                                 ("Dana Kim", "Agreed, let's start with a two-week pilot.")])
        _ = intro
        seeded.pricing = save(
            store, title: pricingTitle, at: now.addingTimeInterval(-2 * 3_600), minutes: 34, app: .zoom,
            summary: """
            - Pilot covers the support team only, about 40 seats
            - Security review is the main blocker on Acme's side
            - Who signs off on security at Acme?
            - Decided: pilot price is $4k a month for the first quarter
            - Decided: the pilot starts on December 1
            """,
            items: [ActionItemDetail(owner: "You", task: "Send the security questionnaire answers", due: "by Friday"),
                    ActionItemDetail(owner: "Dana Kim", task: "Get legal sign-off on the pilot terms", due: "next week"),
                    ActionItemDetail(owner: "Lee Park", task: "Send the list of pilot users", due: "by Monday"),
                    ActionItemDetail(owner: "You", task: "Book the kickoff with their support leads", due: "")],
            people: ["Dana Kim", "Lee Park"], done: [3],
            lines: [("You", "Thanks both. I'd like to leave today with a price and a start date for the pilot."),
                    ("Dana Kim", "Same. The pilot would cover our support team only, roughly forty seats."),
                    ("Lee Park", "Our worry is the security review, that's what usually takes longest here."),
                    ("You", "I can send the security questionnaire answers by Friday."),
                    ("Dana Kim", "Good. On price, four thousand a month for the first quarter works for us."),
                    ("You", "Then the pilot price is four thousand a month for the first quarter."),
                    ("Lee Park", "I'll send the list of pilot users by Monday."),
                    ("Dana Kim", "And I'll get legal sign-off on the pilot terms next week."),
                    ("You", "Can we start on December first?"),
                    ("Dana Kim", "December first works, the pilot starts then."),
                    ("Lee Park", "Who signs off on security on our side is still open, I'll ask around.")],
            jots: [(25, "only support team, ~40 seats"), (128, "! price: 4k/mo for Q1"), (300, "who signs security at Acme?")],
            consent: .chatMessage)
        save(store, title: "Design review", at: now.addingTimeInterval(-26 * 3_600), minutes: 41, app: nil,
             summary: "- New pill states reviewed\n- Decided: keep the dark pill in both themes",
             items: [ActionItemDetail(owner: "Ana Ruiz", task: "Share the motion study", due: "Thursday")],
             people: ["Ana Ruiz"], done: [],
             lines: [("Ana Ruiz", "I'd keep the dark pill in both themes, it reads as the instrument."),
                     ("You", "Agreed, keep the dark pill.")])
        save(store, title: "1:1 with Priya", at: now.addingTimeInterval(-3 * 86_400), minutes: 30, app: .faceTime,
             summary: "- Priya wants to own the onboarding rewrite\n- Decided: Priya leads onboarding from next sprint",
             items: [ActionItemDetail(owner: "You", task: "Write up the onboarding goals for Priya", due: "this week")],
             people: ["Priya Shah"], done: [],
             lines: [("Priya Shah", "I'd like to own the onboarding rewrite."), ("You", "Then you lead onboarding from next sprint.")])
        let writing = Note(
            title: "Hiring sync", createdAt: now.addingTimeInterval(-4 * 60), durationSeconds: 22 * 60,
            transcript: "We went through the three finalists for the design role and the take-home timing.", status: .processing)
        seeded.processing = (try? store.save(writing))?.id
        return seeded
    }

    @discardableResult
    private static func save(
        _ store: Store, title: String, at date: Date, minutes: Double, app: MeetingApp?, summary: String,
        items: [ActionItemDetail], people: [String], done: Set<Int>, lines: [(String, String)],
        jots: [(Double, String)] = [], consent: MeetingConsent.Method? = nil
    ) -> Int64? {
        var note = Note(title: title, createdAt: date, status: .ready, meetingApp: app)
        note.durationSeconds = minutes * 60
        note.summary = summary
        note.setActionItems(items.map(\.line), details: items)
        guard let id = (try? store.save(note))?.id else { return nil }
        let labels = Array(Set(lines.map(\.0))).sorted()
        let speakers = labels.map { NoteSpeaker(noteId: id, label: $0 == "You" ? "You" : "Speaker \($0.count)", displayName: $0) }
        let span = note.durationSeconds / Double(max(1, lines.count))
        let segments = lines.enumerated().map { offset, line in
            (speakerIndex: labels.firstIndex(of: line.0) as Int?,
             segment: AlignedSegment(speakerLabel: line.0, start: Double(offset) * span, end: Double(offset + 1) * span - 1, text: line.1))
        }
        let inserted = (try? store.replaceSpeakerSegments(noteId: id, speakers: speakers, segments: segments)) ?? []
        let turns = segments.map { entry in
            NoteTurn(
                noteId: id, ordinal: 0, stream: entry.segment.speakerLabel == "You" ? .mic : .system,
                speakerId: entry.speakerIndex.flatMap { inserted.indices.contains($0) ? inserted[$0].id : nil },
                t0: entry.segment.start, t1: entry.segment.end, text: entry.segment.text, origin: .capture)
        }
        try? store.replaceTurns(noteId: id, turns: turns)
        let attendees = [CalendarAttendee(name: "Sam Lee", isCurrentUser: true, status: .accepted)]
            + people.map { CalendarAttendee(name: $0, status: .accepted) }
        let event = CalendarEvent(
            eventIdentifier: "fixture-\(id)", title: title, start: date, end: date.addingTimeInterval(note.durationSeconds),
            attendees: attendees, locationAndURL: "")
        if let match = NoteCalendarMatch(event: event) {
            _ = try? store.applyCalendarMatch(match, toNote: id, replacingTitle: "")
        }
        for index in done { try? store.setActionItemDone(noteId: id, itemIndex: index, isDone: true) }
        for (at, text) in jots { _ = try? store.addJot(noteId: id, text: text, atSeconds: at, now: date.addingTimeInterval(at)) }
        if let consent { try? store.recordConsent(MeetingConsent(noteId: id, method: consent, at: date.addingTimeInterval(40))) }
        return id
    }

    static func live(now: Date, callHeard: Bool) -> LiveMeetingState {
        let started = now.addingTimeInterval(-754)
        var note = Note(id: 9_999, title: "Acme follow-up", createdAt: started, status: .recording, meetingApp: .zoom)
        note.durationSeconds = 754
        var capture = MeetingCapture(startedAt: started, isCapturingCall: true)
        capture.heard(.microphone, rms: 0.2, at: now.addingTimeInterval(-1))
        if callHeard { capture.heard(.call, rms: 0.2, at: now.addingTimeInterval(-2)) }
        let lines: [(seq: Int, stream: NoteTurn.Stream, text: String)] = [
            (21, .system, "so legal came back and they're fine with the pilot terms as written"),
            (22, .mic, "great that unblocks the december first start then"),
            (23, .system, "lee still owes you the user list he said monday"),
            (24, .mic, "and i sent the security answers yesterday did they land"),
        ]
        let turns = lines.map { line in
            NoteTurn(noteId: 9_999, ordinal: NoteTurn.captureOrdinal(seq: line.seq, stream: line.stream == .system ? .system : .mic),
                     stream: line.stream, t0: Double(line.seq) * 30, t1: Double(line.seq + 1) * 30, text: line.text, origin: .capture)
        }
        let jots = [
            MeetingJot(id: 1, noteId: 9_999, atSeconds: 95, text: "legal OK on terms"),
            MeetingJot(id: 2, noteId: 9_999, atSeconds: 410, text: "? does the pilot include their EU team"),
        ]
        return LiveMeetingState(
            note: note, startedAt: started, capture: capture,
            progress: MeetingTranscriptProgress(recordedSeconds: 754, transcribedSeconds: 750, chunkSeconds: 30),
            turns: turns, jots: jots, consent: callHeard ? nil : MeetingConsent(noteId: 9_999, method: .chatMessage, at: started.addingTimeInterval(30)))
    }
}
