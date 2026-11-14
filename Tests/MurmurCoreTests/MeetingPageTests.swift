import Foundation
import Testing
@testable import MurmurCore

/// The meeting page and the live screen's honesty rules, on invented meetings.
@Suite("Meeting page")
struct MeetingPageTests {
    private let epoch = Date(timeIntervalSince1970: 1_700_000_000)

    private var lines: [MeetingLine] {
        [
            MeetingLine(index: 0, start: 0, end: 9, speaker: "You", text: "Thanks for joining, let's look at the launch plan."),
            MeetingLine(index: 1, start: 9, end: 30, speaker: "Priya", text: "I can send the revised deck to Marcus by Friday."),
            MeetingLine(index: 2, start: 30, end: 52, speaker: "Marcus", text: "Then we ship the smaller version first and keep pricing as is."),
            MeetingLine(index: 3, start: 52, end: 70, speaker: "You", text: "I'll book the follow-up review for Tuesday."),
        ]
    }

    private func note(summary: String, items: [ActionItemDetail]) -> Note {
        var note = Note(title: "Launch plan", createdAt: epoch, status: .ready)
        note.summary = summary
        note.setActionItems(items.map(\.line), details: items)
        return note
    }

    @Test("decisions, key points and questions come back out of the stored summary")
    func storedSummaryRows() {
        let rows = StoredSummaryDigest().rows(for: note(
            summary: "- Reviewed the launch plan\n- Who owns support at launch?\n- Decided: ship the smaller version first",
            items: [ActionItemDetail(owner: "Priya", task: "Send the revised deck", due: "by Friday")]))
        #expect(rows.decisions.map(\.text) == ["ship the smaller version first"])
        #expect(rows.keyPoints == ["Reviewed the launch plan"])
        #expect(rows.openQuestions == ["Who owns support at launch?"])
        #expect(rows.actionItems.first?.detail.owner == "Priya")
    }

    @Test("a row finds the turn where it was said, and a row nobody said finds nothing")
    func momentLocator() {
        let deck = MeetingMomentLocator.moment(for: "Priya sends the revised deck", in: lines)
        #expect(deck?.lineIndex == 1)
        #expect(deck?.speaker == "Priya")
        #expect(MeetingMomentLocator.moment(for: "Hire a second designer", in: lines) == nil)
        #expect(MeetingMoment.clock(3_725) == "1:02:05")
        #expect(MeetingMoment.clock(65) == "1:05")
    }

    @Test("the page splits what I owe from what others owe and keeps typed lines as mine")
    func pageBuild() {
        let items = [
            ActionItemDetail(owner: "Priya", task: "Send the revised deck to Marcus", due: "by Friday"),
            ActionItemDetail(owner: "Sam", task: "Book the follow-up review", due: "Tuesday"),
        ]
        let rows = StoredSummaryDigest().rows(for: note(summary: "- Decided: ship the smaller version first", items: items))
        let jots = [
            MeetingJot(id: 1, noteId: 1, atSeconds: 31, text: "pricing stays"),
            MeetingJot(id: 2, noteId: 1, atSeconds: 55, text: "who tells support?"),
        ]
        let page = MeetingPage.build(rows: rows, lines: lines, jots: jots, doneIndexes: [0], myNames: MeetingPage.myNames(userName: "Sam Lee"))
        #expect(page.mine.map(\.task) == ["Book the follow-up review"])
        #expect(page.theirs.first?.isDone == true)
        #expect(page.yourNotes.allSatisfy { $0.author == .you })
        #expect(page.yourNotes.first?.moment?.lineIndex == 2, "a typed line opens the turn it was typed in")
        #expect(page.openQuestions.map(\.text) == ["who tells support?"])
        #expect(page.decisions.first?.moment?.speaker == "Marcus")
        #expect(page.speakers == ["You", "Priya", "Marcus"])
        #expect(page.mine.first?.whoAndWhen == "You · Tuesday")
    }

    @Test("numbers, money, periods and quarters are compared as one form, whichever way they were written")
    func sameNumbers() {
        let typed = MeetingWords.content("price: 4k/mo for Q1")
        #expect(typed == ["price", "4000", "month", "q1"])
        #expect(MeetingWords.content("pilot price is $4,000 a month for the first quarter") == MeetingWords.content("pilot price is four thousand a month for the first quarter"))
        #expect(MeetingWords.restates(typed, MeetingWords.content("pilot price is $4k a month for the first quarter")))
    }

    @Test("a different decision is never taken for a restatement", arguments: [
        "pilot price is $5k a month for the second quarter",
        "the pilot starts on December 1",
        "ship the smaller version first",
    ])
    func differentDecisionsStay(model: String) {
        #expect(!MeetingWords.restates(MeetingWords.content("price: 4k/mo for Q1"), MeetingWords.content(model)))
        #expect(!MeetingWords.restates(MeetingWords.content("ship it"), MeetingWords.content("ship the beta on Monday")),
                "a one-word line never swallows a longer one")
    }

    @Test("the page keeps the person's decision and drops the model's restatement of it, and only that")
    func typedDecisionWins() {
        var note = Note(title: "Pricing", createdAt: epoch, status: .ready)
        note.summary = "- Decided: pilot price is $4k a month for the first quarter\n- Decided: the pilot starts on December 1"
        let page = MeetingPage.build(
            rows: StoredSummaryDigest().rows(for: note), lines: lines,
            jots: [MeetingJot(id: 1, noteId: 1, atSeconds: 40, text: "! price: 4k/mo for Q1")], doneIndexes: [], myNames: ["You"])
        #expect(page.decisions.map(\.text) == ["price: 4k/mo for Q1", "the pilot starts on December 1"])
        #expect(page.decisions.first?.author == .you)
    }

    @Test("capture: a silent call side is flagged only while the microphone hears speech")
    func captureHealth() {
        var capture = MeetingCapture(startedAt: epoch, isCapturingCall: true)
        capture.heard(.microphone, rms: 0.2, at: epoch.addingTimeInterval(130))
        capture.heard(.call, rms: 0.001, at: epoch.addingTimeInterval(130))
        let now = epoch.addingTimeInterval(132)
        #expect(capture.signal(.microphone, now: now) == .hearing)
        #expect(capture.signal(.call, now: now) == .silent)
        #expect(capture.warning(now: now)?.side == .call)

        capture.heard(.call, rms: 0.05, at: epoch.addingTimeInterval(131))
        #expect(capture.warning(now: now) == nil)
        #expect(capture.signal(.microphone, now: epoch.addingTimeInterval(160)) == .quiet, "a pause in talk is not a fault")

        let micOnly = MeetingCapture(startedAt: epoch, isCapturingCall: false)
        #expect(micOnly.signal(.call, now: now) == .off)
        #expect(micOnly.warning(now: epoch.addingTimeInterval(121))?.side == .microphone)

        let refused = MeetingCapture(startedAt: epoch, isCapturingCall: false, callRequested: true)
        #expect(refused.warning(now: epoch.addingTimeInterval(1))?.title == "Only your side is being recorded",
                "asking for the call's audio and not getting it is said at once")
    }

    @Test("progress says what is written down, never more than was recorded")
    func progress() {
        #expect(MeetingTranscriptProgress(recordedSeconds: 12, transcribedSeconds: 0, chunkSeconds: 30).line == "First lines in about 18 s")
        let partway = MeetingTranscriptProgress(recordedSeconds: 750, transcribedSeconds: 900, chunkSeconds: 30)
        #expect(partway.transcribedSeconds == 750)
        #expect(MeetingTranscriptProgress(recordedSeconds: 800, transcribedSeconds: 750, chunkSeconds: 30).line == "Written down to 12:30")
        #expect(MeetingAfterStage.stage(status: .processing, isTranscribing: true, hasSpeakerTurns: false, expectsSpeakerTurns: true) == .finishingTranscript)
        #expect(MeetingAfterStage.stage(status: .processing, isTranscribing: false, hasSpeakerTurns: false, expectsSpeakerTurns: true) == .writingPage)
        #expect(MeetingAfterStage.stage(status: .ready, isTranscribing: false, hasSpeakerTurns: false, expectsSpeakerTurns: true) == .namingSpeakers)
        #expect(MeetingAfterStage.stage(status: .ready, isTranscribing: false, hasSpeakerTurns: false, expectsSpeakerTurns: false) == .ready)
    }

    @Test("the consent notice says only what is true")
    func consentNotice() {
        let notice = MeetingConsent.notice(userName: "Sam Lee")
        #expect(notice.hasPrefix("Sam Lee here"))
        #expect(notice.contains("stays on my Mac"))
        #expect(notice.contains("used to train"))
    }
}

@Suite("Meeting store")
struct MeetingStoreTests {
    @Test("typed lines and the consent note are kept per meeting and go with it")
    func jotsAndConsent() throws {
        let store = try Store()
        let note = try store.save(Note(title: "Sync", createdAt: Date(), status: .recording))
        let id = try #require(note.id)
        #expect(try store.addJot(noteId: id, text: "   ", atSeconds: 3) == nil)
        try store.addJot(noteId: id, text: "later thought", atSeconds: nil)
        let first = try #require(try store.addJot(noteId: id, text: " pricing stays ", atSeconds: 40))
        try store.addJot(noteId: id, text: "intro", atSeconds: 2)
        #expect(try store.jots(noteId: id).map(\.text) == ["intro", "pricing stays", "later thought"])
        try store.updateJot(id: try #require(first.id), text: "")
        #expect(try store.jots(noteId: id).count == 2, "a blank edit removes the line")

        try store.recordConsent(MeetingConsent(noteId: id, method: .chatMessage))
        try store.recordConsent(MeetingConsent(noteId: id, method: .saidAloud))
        #expect(try store.consent(forNote: id)?.method == .saidAloud)

        try store.deleteNote(id: id)
        #expect(try store.jots(noteId: id).isEmpty)
        #expect(try store.consent(forNote: id) == nil)
    }
}
