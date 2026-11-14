import Foundation
import Testing
@testable import MurmurCore

/// Covers migration "v10-note-app": the nullable `note.meetingApp` column that records which
/// video/call app a note was recorded from (see `MeetingApp`, `CallDetectionState`). "v9-…" is
/// intentionally skipped (left as a gap for a concurrently-developed migration, per the task's
/// instructions), so this only exercises v10's own delta. Uses an in-memory store (`Store.init()`),
/// never the user's real database.
@Suite("Store note app (v10-note-app)")
struct StoreNoteAppTests {
    @Test("A note defaults to no meeting app when not specified")
    func defaultMeetingAppIsNil() throws {
        let store = try Store()
        let saved = try store.save(Note(title: "Manual note"))
        #expect(saved.meetingApp == nil)
    }

    @Test("A note created with a meeting app persists and round-trips it")
    func meetingAppPersists() throws {
        let store = try Store()
        let note = Note(title: "Standup", meetingApp: .zoom)
        let saved = try store.save(note)
        let fetched = try #require(try store.note(id: saved.id!))
        #expect(fetched.meetingApp == .zoom)
    }

    @Test("Every MeetingApp case round-trips through the store")
    func everyMeetingAppRoundTrips() throws {
        let store = try Store()
        for app in MeetingApp.allCases {
            let saved = try store.save(Note(title: "Note for \(app.rawValue)", meetingApp: app))
            let fetched = try #require(try store.note(id: saved.id!))
            #expect(fetched.meetingApp == app)
        }
    }

    @Test("Updating a note that already has a meeting app preserves it across saves")
    func meetingAppPreservedAcrossSaves() throws {
        let store = try Store()
        var note = try store.save(Note(title: "Sync", meetingApp: .teams))
        note.transcript = "hello"
        let resaved = try store.save(note)
        #expect(resaved.meetingApp == .teams)
    }
}
