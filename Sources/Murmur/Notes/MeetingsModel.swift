import AppKit
import CryptoKit
import Foundation
import MurmurCore
import Observation
import os

/// The Meetings section's state: what is open (the overview, a person, or a meeting through
/// `AppModel.selectedNoteID`), the between-meetings overview, the last question asked, and the
/// one-tap follow-ups. Reads go through two seams, `memory` (cross-meeting answers, one snapshot
/// of the rows) and `digest` (a meeting's written rows), so a new source plugs in without view changes.
@MainActor
@Observable
final class MeetingsModel {
    enum Focus: Equatable {
        case overview
        case person(String)
    }

    /// A request to open a meeting at a moment; the page scrolls there and highlights the line.
    struct Jump: Equatable {
        let noteId: Int64
        let seconds: Double
    }

    struct Overview: Equatable {
        var upcoming: CalendarEvent?
        var prep: MeetingPrep?
        var commitments = MeetingCommitments(iOwe: [], owedToMe: [], unowned: [])
        var people: [MeetingPerson] = []
        var companies: [MeetingCompany] = []
        var calendarReadable = false
        /// Meetings recorded from a call and their audio: the set "Erase meetings" removes (`MeetingErasePlan`).
        var meetingCount = 0
        var audioBytes: Int64 = 0
    }

    /// Whether the cross-meeting surfaces exist at all: asking, people and companies, the prep
    /// brief. `FeatureFlags.meetingAsk`, off unless a test build names it. Not a view concern: with
    /// it off nothing here is read or answered, so no screen can reach it.
    var crossMeetingMemory = FeatureFlags.meetingAsk
    var focus: Focus = .overview
    var jump: Jump?
    var question = ""
    private(set) var answer: MeetingAnswer?
    private(set) var overview = Overview()
    /// A one-line result of the last follow-up ("Added to Reminders"), shown where it was tapped.
    var flash: String?
    /// Bumped when a typed line or the consent note changes, so live views read them again.
    private(set) var revision = 0
    /// The consent notice is on the clipboard, waiting for "I pasted it".
    var noticeCopied = false
    let audio = MeetingAudioPlayer()

    /// The last snapshot and when it was built; asked questions reuse it while it is fresh.
    @ObservationIgnored private var memory: (source: any MeetingMemorySource, builtAt: Date)?
    @ObservationIgnored private var upcomingEvents: [CalendarEvent] = []
    @ObservationIgnored var digest: any MeetingDigestSource
    @ObservationIgnored var calendar: any CalendarReading
    @ObservationIgnored private let store: Store
    @ObservationIgnored private let settings: AppSettings
    @ObservationIgnored private let reminders: any CalendarActionBackend
    @ObservationIgnored private let log = Logger(subsystem: "app.hushy", category: "meetings")
    @ObservationIgnored private var live = LiveTurnReader()

    init(store: Store, settings: AppSettings, calendar: any CalendarReading, reminders: any CalendarActionBackend) {
        self.store = store
        self.settings = settings
        self.calendar = calendar
        self.reminders = reminders
        self.digest = StoredSummaryDigest()
    }

    var myNames: [String] { MeetingPage.myNames(userName: settings.userName) }

    // MARK: Between meetings

    /// Reloads the overview: the next calendar meeting (only when calendar access was already
    /// given; this never asks), its prep, what is owed both ways, people, and what is on disk.
    func refreshOverview(now: Date = Date()) async {
        var next = Overview()
        let canRead = await calendar.authorization().canRead
        next.calendarReadable = canRead
        if canRead, let events = try? await calendar.events(from: now.addingTimeInterval(-15 * 60), to: now.addingTimeInterval(36 * 3600)) {
            next.upcoming = events.first { !$0.isAllDay && $0.end > now && $0.attendees.contains { !$0.isCurrentUser } }
            upcomingEvents = events
        }
        // Off the main actor: building the memory reads every meeting's rows, so a long history
        // must not stall the window.
        let build = memoryBuilder(now: now), names = myNames, store = self.store, upcoming = next.upcoming
        let log = self.log, withMemory = crossMeetingMemory
        let (read, built) = await Task.detached(priority: .userInitiated) { () -> (Overview, (any MeetingMemorySource)?) in
            var found = Overview()
            var built: (any MeetingMemorySource)?
            do {
                let memory = try build()
                built = memory
                if withMemory, let upcoming { found.prep = try memory.prep(for: upcoming, myNames: names) }
                found.commitments = try memory.commitments(myNames: names)
                if withMemory {
                    found.people = try memory.people(limit: 12, myNames: names)
                    found.companies = try memory.companies(limit: 8)
                }
            } catch {
                log.error("meetings overview failed: \(error.localizedDescription)")
            }
            if let meetings = try? store.meetingErasePlan() {
                found.meetingCount = meetings.count
                found.audioBytes = meetings.audioBytes
            }
            return (found, built)
        }.value
        if let built { memory = (built, now) }
        next.prep = read.prep
        next.commitments = read.commitments
        next.people = read.people
        next.companies = read.companies
        next.meetingCount = read.meetingCount
        next.audioBytes = read.audioBytes
        overview = next
    }

    func ask(now: Date = Date()) async {
        let trimmed = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard crossMeetingMemory, !trimmed.isEmpty else { answer = nil; return }
        let source = await currentMemory(now: now)
        answer = (try? source?.ask(trimmed, myNames: myNames))
            ?? MeetingAnswer(question: trimmed, lines: [], emptyReason: "Couldn't read your meetings just now.")
    }

    /// A snapshot at most a minute old, so a meeting that just finished is in the answer.
    private func currentMemory(now: Date) async -> (any MeetingMemorySource)? {
        if let memory, now.timeIntervalSince(memory.builtAt) < 60 { return memory.source }
        let build = memoryBuilder(now: now), log = self.log
        let built = await Task.detached(priority: .userInitiated) { () -> (any MeetingMemorySource)? in
            do { return try build() } catch {
                log.error("meeting memory build failed: \(error.localizedDescription)")
                return nil
            }
        }.value
        if let built { memory = (built, now) }
        return built
    }

    private func memoryBuilder(now: Date) -> @Sendable () throws -> any MeetingMemorySource {
        let store = self.store, names = myNames, digest = self.digest, upcoming = upcomingEvents
        return {
            try EngineMeetingMemory.build(
                store: store, myNames: names, digest: digest, upcoming: upcoming,
                context: DateContext(now: now, timeZone: .current, locale: .current))
        }
    }

    func clearAnswer() {
        answer = nil
        question = ""
    }

    /// From the overview's snapshot; a person page is only reached from the overview.
    func timeline(for name: String) -> [MeetingTimelineEntry] {
        (try? memory?.source.timeline(for: .person(name), myNames: myNames)) ?? []
    }

    // MARK: One meeting

    struct PageContent: Equatable {
        let page: MeetingPage
        let consent: MeetingConsent?
        let calendarTitle: String?
        let attendees: [String]
        let hasSpeakerTurns: Bool
        /// Whether the body may be restyled: a memo's, never a meeting's (`NoteRestyle.availability`).
        var restyle: NoteRestyle.Availability = .notReady
    }

    func content(for note: Note) -> PageContent {
        guard let id = note.id else {
            return PageContent(page: .build(rows: .init(), lines: [], jots: [], doneIndexes: [], myNames: myNames),
                               consent: nil, calendarTitle: nil, attendees: [], hasSpeakerTurns: false)
        }
        let segments = (try? store.noteSegments(noteId: id)) ?? []
        let lines = MeetingLine.lines(from: segments)
        // Rows from the note's facts, each at the moment its quote was said; a note with none falls back to its columns.
        let facts = (try? store.facts(noteId: id)) ?? []
        let rows = facts.isEmpty ? digest.rows(for: note) : FactDigest(facts: facts).rows(for: note)
        let page = MeetingPage.build(
            rows: rows, lines: lines, jots: (try? store.jots(noteId: id)) ?? [],
            doneIndexes: (try? store.doneActionItemIndexes(noteId: id)) ?? [], myNames: myNames)
        let consent = try? store.consent(forNote: id)
        let link = try? store.calendarLink(forNote: id)
        // A transcript that cannot be read counts as several voices: unsure means meeting, and meetings stay as said.
        let severalVoices = (try? store.transcript(noteId: id))?.hasSeveralVoices ?? true
        return PageContent(
            page: page, consent: consent, calendarTitle: link?.eventTitle,
            attendees: (try? store.nameSuggestions(forNote: id)) ?? [], hasSpeakerTurns: !segments.isEmpty,
            restyle: NoteRestyle.availability(
                of: note, hasSeveralVoices: severalVoices, hasConsent: consent != nil, hasCalendarLink: link != nil))
    }

    @discardableResult
    func addJot(noteId: Int64, text: String, atSeconds: Double?) -> MeetingJot? {
        do {
            defer { revision += 1 }
            return try store.addJot(noteId: noteId, text: text, atSeconds: atSeconds)
        } catch {
            log.error("saving a typed line failed: \(error.localizedDescription)")
            flash = "Couldn't save that line."
            return nil
        }
    }

    func jots(noteId: Int64) -> [MeetingJot] { (try? store.jots(noteId: noteId)) ?? [] }

    /// The recording's turns as the live screen shows them, read from the store: only new rows each second.
    func liveTurns(noteId: Int64) -> [NoteTurn] {
        do { try live.refresh(noteId: noteId, store: store) } catch {
            log.error("reading the live turns failed: \(error.localizedDescription)")
        }
        return live.turns
    }

    func recordConsent(noteId: Int64, method: MeetingConsent.Method) {
        do {
            try store.recordConsent(MeetingConsent(noteId: noteId, method: method))
            noticeCopied = false
            revision += 1
        }
        catch { log.error("saving consent failed: \(error.localizedDescription)") }
    }

    /// Copies the notice for the meeting chat. Nothing is recorded as "told" until the person says
    /// they pasted it: a copy alone tells nobody.
    func copyConsentNotice() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(MeetingConsent.notice(userName: settings.userName), forType: .string)
        noticeCopied = true
    }

    func open(noteId: Int64, at seconds: Double?, app: AppModel) {
        focus = .overview
        app.selectedNoteID = noteId
        jump = seconds.map { Jump(noteId: noteId, seconds: $0) }
    }

    // MARK: Follow-ups (one tap; nothing reaches another person without their own send)

    func addToReminders(_ commitment: MeetingPage.Commitment, from note: Note) async {
        let granted = await reminders.hasAccess(for: .createReminder) ? true : await reminders.requestAccess(for: .createReminder)
        guard granted else {
            flash = "Hushy needs Reminders access: System Settings → Privacy & Security → Reminders."
            return
        }
        let notes = ["From “\(note.title)”, \(note.createdAt.formatted(date: .abbreviated, time: .shortened))", commitment.due]
            .filter { !$0.isEmpty }.joined(separator: " · ")
        let action = ProposedAction(kind: .createReminder, title: commitment.task, notes: notes, sourceText: commitment.task)
        do {
            let result = try await reminders.createReminder(action)
            flash = "Added to \(result.placedIn ?? "Reminders")"
        } catch {
            flash = "Couldn't add it to Reminders."
            log.error("meeting reminder failed: \(error.localizedDescription)")
        }
    }

    func draftFollowUp(_ note: Note) {
        guard let id = note.id else { return }
        let speakers = MeetingRecap.speakers(in: (try? store.noteSegments(noteId: id)) ?? [])
        guard let recap = MeetingRecap.make(
            from: note, turns: try? store.transcript(noteId: id), speakers: speakers, ownerName: settings.userName,
            facts: try? store.facts(noteId: id))
        else {
            flash = "Nothing to send yet."
            return
        }
        flash = RecapMailDraft.open(recap).text
    }

    // MARK: Erase

    /// What "Erase meetings" would remove now, read off the main thread. `keeping` is the note being recorded.
    func erasePlan(keeping: Set<Int64>) async -> MeetingErasePlan? {
        let store = self.store, log = self.log
        return await Task.detached(priority: .userInitiated) { () -> MeetingErasePlan? in
            do { return try store.meetingErasePlan(keeping: keeping) } catch {
                log.error("reading meetings to erase failed: \(error.localizedDescription)")
                return nil
            }
        }.value
    }

    /// Erases exactly the plan's notes, off the main thread, then reloads the overview.
    func erase(_ plan: MeetingErasePlan) async {
        let store = self.store, log = self.log
        let erased = await Task.detached(priority: .userInitiated) { () -> Int? in
            do { return try store.eraseMeetings(plan) } catch {
                log.error("erasing meetings failed: \(error.localizedDescription)")
                return nil
            }
        }.value
        flash = erased.map { "Erased \($0) meeting\($0 == 1 ? "" : "s")." } ?? "Couldn't erase the meetings."
        await refreshOverview()
    }

    // MARK: Snapshots

    func pinOverviewForSnapshot(_ overview: Overview) { self.overview = overview }
    func pinAnswerForSnapshot(_ question: String, now: Date) async {
        self.question = question
        await ask(now: now)
    }
}
