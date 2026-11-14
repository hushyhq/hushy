import Foundation
import Testing
@testable import MurmurCore

/// Covers the calendar plumbing from `docs/product/CONNECTORS.md` §2.1: what counts as a
/// meeting, when the "starts in 1 min — Record?" reminder shows and lapses, one reminder per
/// occurrence, auto-titling a recording from the overlapping event, attendee-name suggestions,
/// and that a poll never triggers the permission prompt. Everything runs against
/// `StaticCalendarReader` and an injected `now` — no EventKit, no TCC.
@Suite("Calendar context")
struct CalendarContextTests {
    private let epoch = Date(timeIntervalSince1970: 1_700_000_000)

    private func meeting(
        _ id: String = "sync", title: String = "Weekly sync", startIn: TimeInterval, duration: TimeInterval = 30 * 60,
        others: [String] = ["Dana Kim"], location: String = "", allDay: Bool = false,
        selfStatus: CalendarAttendee.ParticipantStatus = .accepted
    ) -> CalendarEvent {
        var attendees = [CalendarAttendee(name: "Me", email: "me@example.com", isCurrentUser: true, status: selfStatus)]
        attendees += others.map { CalendarAttendee(name: $0, status: .accepted) }
        let start = epoch.addingTimeInterval(startIn)
        return CalendarEvent(
            eventIdentifier: id, title: title, start: start, end: start.addingTimeInterval(duration),
            isAllDay: allDay, attendees: attendees, locationAndURL: location)
    }

    // MARK: - What is a meeting

    @Test("an event with another attendee is a meeting")
    func attendeeMakesMeeting() {
        #expect(meeting(startIn: 0).looksLikeMeeting)
    }

    @Test("a solo event with a video link is a meeting; without one it is not")
    func videoLinkMakesMeeting() {
        let zoom = meeting(startIn: 0, others: [], location: "https://us02web.zoom.us/j/123")
        #expect(zoom.looksLikeMeeting)
        let focus = meeting(title: "Focus time", startIn: 0, others: [])
        #expect(!focus.looksLikeMeeting)
    }

    @Test("all-day and declined events are never meetings")
    func allDayAndDeclinedExcluded() {
        #expect(!meeting(startIn: 0, allDay: true).looksLikeMeeting)
        #expect(!meeting(startIn: 0, selfStatus: .declined).looksLikeMeeting)
    }

    @Test("blank and placeholder titles are unusable")
    func usableTitle() {
        #expect(meeting(title: "  ", startIn: 0).usableTitle == nil)
        #expect(meeting(title: "New Event", startIn: 0).usableTitle == nil)
        #expect(meeting(title: "  Design review ", startIn: 0).usableTitle == "Design review")
    }

    // MARK: - Reminder lifecycle

    @Test("reminder shows one minute before the start, not earlier")
    func reminderLeadTime() {
        var planner = MeetingReminderPlanner()
        let events = [meeting(startIn: 120)]
        #expect(planner.observe(events: events, isEnabled: true, isRecording: false, now: epoch) == .none)
        let effect = planner.observe(events: events, isEnabled: true, isRecording: false, now: epoch.addingTimeInterval(60))
        guard case .showReminder(let reminder) = effect else {
            Issue.record("expected a reminder, got \(effect)")
            return
        }
        #expect(reminder.event.eventIdentifier == "sync")
        #expect(reminder.headline(now: epoch.addingTimeInterval(60)) == "Weekly sync starts in 1 min")
    }

    @Test("headline follows the clock: starts now, then started N min ago")
    func headlineWording() {
        let reminder = MeetingReminderPlanner.Reminder(event: meeting(startIn: 0), expiresAt: epoch.addingTimeInterval(300))
        #expect(reminder.headline(now: epoch.addingTimeInterval(-10)) == "Weekly sync starts now")
        #expect(reminder.headline(now: epoch.addingTimeInterval(125)) == "Weekly sync started 2 min ago")
        let untitled = MeetingReminderPlanner.Reminder(event: meeting(title: "", startIn: 0), expiresAt: epoch)
        #expect(untitled.headline(now: epoch.addingTimeInterval(-90)) == "Meeting starts in 2 min")
    }

    @Test("reminder does not re-fire while pending and lapses five minutes after the start")
    func reminderLapses() {
        var planner = MeetingReminderPlanner()
        let events = [meeting(startIn: 60)]
        _ = planner.observe(events: events, isEnabled: true, isRecording: false, now: epoch)
        #expect(planner.observe(events: events, isEnabled: true, isRecording: false, now: epoch.addingTimeInterval(30)) == .none)
        #expect(planner.tick(now: epoch.addingTimeInterval(60 + 299)) == .none)
        #expect(planner.tick(now: epoch.addingTimeInterval(60 + 300)) == .dismissReminder)
        #expect(planner.pending == nil)
        // The lapsed occurrence is never offered again.
        #expect(planner.observe(events: events, isEnabled: true, isRecording: false, now: epoch.addingTimeInterval(400)) == .none)
    }

    @Test("accepting returns the meeting; dismissing is final for that occurrence")
    func acceptAndDismiss() {
        var planner = MeetingReminderPlanner()
        let events = [meeting(startIn: 30)]
        _ = planner.observe(events: events, isEnabled: true, isRecording: false, now: epoch)
        #expect(planner.accept()?.usableTitle == "Weekly sync")
        #expect(planner.pending == nil)
        #expect(planner.accept() == nil)

        var other = MeetingReminderPlanner()
        _ = other.observe(events: events, isEnabled: true, isRecording: false, now: epoch)
        other.dismiss()
        #expect(other.observe(events: events, isEnabled: true, isRecording: false, now: epoch.addingTimeInterval(10)) == .none)
    }

    @Test("a recurring meeting is reminded once per occurrence")
    func recurringOccurrences() {
        var planner = MeetingReminderPlanner()
        let today = meeting(startIn: 30)
        _ = planner.observe(events: [today], isEnabled: true, isRecording: false, now: epoch)
        planner.dismiss()
        let nextWeek = meeting(startIn: 7 * 86_400 + 30)
        let effect = planner.observe(events: [nextWeek], isEnabled: true, isRecording: false, now: epoch.addingTimeInterval(7 * 86_400))
        #expect(effect == .showReminder(.init(event: nextWeek, expiresAt: nextWeek.start.addingTimeInterval(300))))
    }

    @Test("no reminder while recording, and an existing one is dismissed when recording starts")
    func recordingSuppresses() {
        var planner = MeetingReminderPlanner()
        let events = [meeting(startIn: 30)]
        #expect(planner.observe(events: events, isEnabled: true, isRecording: true, now: epoch) == .none)
        _ = planner.observe(events: events, isEnabled: true, isRecording: false, now: epoch)
        #expect(planner.observe(events: events, isEnabled: true, isRecording: true, now: epoch.addingTimeInterval(1)) == .dismissReminder)
    }

    @Test("the setting off means no reminder and takes a pending one down")
    func settingOff() {
        var planner = MeetingReminderPlanner()
        let events = [meeting(startIn: 30)]
        #expect(planner.observe(events: events, isEnabled: false, isRecording: false, now: epoch) == .none)
        _ = planner.observe(events: events, isEnabled: true, isRecording: false, now: epoch)
        #expect(planner.observe(events: events, isEnabled: false, isRecording: false, now: epoch) == .dismissReminder)
    }

    @Test("non-meetings never produce a reminder")
    func nonMeetingsIgnored() {
        var planner = MeetingReminderPlanner()
        let events = [
            meeting("focus", title: "Focus", startIn: 30, others: []),
            meeting("ooo", title: "Holiday", startIn: 30, allDay: true),
            meeting("declined", title: "Declined", startIn: 30, selfStatus: .declined),
        ]
        #expect(planner.observe(events: events, isEnabled: true, isRecording: false, now: epoch) == .none)
    }

    @Test("two meetings at once: earliest start wins, then the one with more people")
    func overlapPriority() {
        let small = meeting("small", title: "1:1", startIn: 30, others: ["Dana"])
        let big = meeting("big", title: "All hands", startIn: 30, others: ["Dana", "Priya", "Sam"])
        let later = meeting("later", title: "Later", startIn: 50, others: ["Dana", "Priya", "Sam", "Lee"])
        let pick = MeetingReminderPlanner.nextMeeting(in: [later, small, big], now: epoch, excluding: [])
        #expect(pick?.eventIdentifier == "big")
    }

    @Test("handled occurrences are pruned after a day")
    func handledPruned() {
        var planner = MeetingReminderPlanner()
        _ = planner.observe(events: [meeting(startIn: 30)], isEnabled: true, isRecording: false, now: epoch)
        planner.dismiss()
        #expect(planner.handledOccurrences.count == 1)
        _ = planner.tick(now: epoch.addingTimeInterval(2 * 86_400))
        #expect(planner.handledOccurrences.isEmpty)
    }

    // MARK: - Auto-title and speaker suggestions

    @Test("a recording started during a meeting takes its title")
    func recordingTitleFromOverlap() {
        let events = [meeting(startIn: -600), meeting("later", title: "Later", startIn: 3600)]
        let title = CalendarEventMatcher.recordingTitle(startedAt: epoch, events: events, fallback: "Note · now")
        #expect(title == "Weekly sync")
    }

    @Test("a recording started up to five minutes early still matches; earlier keeps the fallback")
    func earlyStartTolerance() {
        let events = [meeting(startIn: 300)]
        #expect(CalendarEventMatcher.recordingTitle(startedAt: epoch, events: events, fallback: "Note") == "Weekly sync")
        #expect(CalendarEventMatcher.recordingTitle(startedAt: epoch.addingTimeInterval(-1), events: events, fallback: "Note") == "Note")
    }

    @Test("a focus block never renames a memo dictated during it")
    func nonMeetingDoesNotTitle() {
        let events = [meeting("focus", title: "Focus time", startIn: -600, others: [])]
        #expect(CalendarEventMatcher.recordingTitle(startedAt: epoch, events: events, fallback: "Note") == "Note")
    }

    @Test("the closest start wins among overlapping meetings, and a blank title falls back")
    func closestStartWins() {
        let long = meeting("long", title: "Offsite", startIn: -3000, duration: 4 * 3600)
        let near = meeting("near", title: "Standup", startIn: -60)
        #expect(CalendarEventMatcher.event(overlapping: epoch, in: [long, near])?.eventIdentifier == "near")
        let untitled = meeting("blank", title: "", startIn: -60)
        #expect(CalendarEventMatcher.recordingTitle(startedAt: epoch, events: [untitled], fallback: "Note") == "Note")
    }

    @Test("speaker suggestions list other attendees once, skipping the user and decliners")
    func speakerSuggestions() {
        let event = CalendarEvent(
            eventIdentifier: "e", title: "Sync", start: epoch, end: epoch.addingTimeInterval(60),
            attendees: [
                CalendarAttendee(name: "Me", isCurrentUser: true, status: .accepted),
                CalendarAttendee(name: "Dana Kim", status: .accepted),
                CalendarAttendee(name: "dana kim", status: .tentative),
                CalendarAttendee(name: "", email: "priya@example.com", status: .pending),
                CalendarAttendee(name: "Sam Lee", status: .declined),
            ])
        #expect(CalendarEventMatcher.speakerNameSuggestions(for: event) == ["Dana Kim", "priya@example.com"])
    }

    // MARK: - Reader

    @Test("static reader filters by overlap and never prompts on a read")
    func readerOverlapAndNoPrompt() async throws {
        let reader = StaticCalendarReader(events: [meeting(startIn: 0), meeting("far", startIn: 3600)])
        let events = try await reader.events(from: epoch, to: epoch.addingTimeInterval(MeetingReminderPlanner.lookahead))
        #expect(events.map(\.eventIdentifier) == ["sync"])
        #expect(await reader.requestCount == 0)
    }

    @Test("reads fail until access is granted; a denied request stays denied")
    func readerAuthorization() async {
        let reader = StaticCalendarReader(authorization: .notDetermined, grantsOnRequest: false)
        await #expect(throws: CalendarReadError.notAuthorized(.notDetermined)) {
            _ = try await reader.events(from: epoch, to: epoch.addingTimeInterval(60))
        }
        #expect(await reader.requestAccess() == .denied)
        #expect(await reader.authorization() == .denied)
        #expect(!CalendarAuthorization.denied.canPrompt)
        #expect(CalendarAuthorization.fullAccess.canRead)
    }
}
