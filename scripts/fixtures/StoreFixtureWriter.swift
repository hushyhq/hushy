// Throwaway `fixture-writer` main, compiled only inside a temporary worktree of an old ref by
// scripts/fixtures/make-store-fixture.sh. It writes a fixed synthetic corpus through that ref's own
// Store and record types, so the file is what that build writes. No real user text, ever.
//
//   fixture-writer write <out.sqlite>   writes the corpus
//   fixture-writer list <store.sqlite>  opens a store with this ref's Store and prints one line per note
//
// HAS_MEETINGS is defined for refs with attendees, jots and consent (main after integ/nov7).
import CryptoKit
import Foundation
import GRDB
@testable import MurmurCore

let base = Date(timeIntervalSince1970: 1_790_000_000)
func at(_ hours: Double) -> Date { base.addingTimeInterval(hours * 3600) }

func longTranscript() -> String {
    let sentence = "Synthetic fixture sentence number %d talks about the quarterly roadmap and the pilot. "
    var text = ""
    var index = 0
    while text.utf8.count < 50_000 {
        text += String(format: sentence, index)
        index += 1
    }
    return text.trimmingCharacters(in: .whitespaces)
}

/// A plain insert, not `Store.save`, which stamps `updatedAt` with the clock: the corpus stays the same on every run.
func insert(_ note: Note, _ store: Store) throws -> Int64 {
    try store.writer.write { db in
        var copy = note
        try copy.insert(db)
        return copy.id!
    }
}

func write(to url: URL) throws {
    try? FileManager.default.removeItem(at: url)
    let store = try Store(url: url)

    let folder = try store.writer.write { db -> NoteFolder in
        var folder = NoteFolder(name: "Fixture folder", createdAt: at(0))
        try folder.insert(db)
        return folder
    }

    // 1. Mic-only ready note.
    _ = try insert(Note(
        title: "Mic only standup", createdAt: at(1), updatedAt: at(1.1), durationSeconds: 312,
        transcript: "Mic only fixture transcript about the standup and the release checklist.",
        summary: "- Standup covered the release checklist", status: .ready, audioPath: "/fixture/audio/1",
        language: nil, source: .recording, meetingApp: .zoom), store)

    // 2. Two-channel ready note with speakers, segments and a voice link (fake ciphertext).
    let twoChannel = try insert(Note(
        title: "Two channel sync", createdAt: at(2), updatedAt: at(2.2), durationSeconds: 1_800,
        transcript: "Speaker one opens the agenda. Speaker two answers about the budget.",
        summary: "- Agenda and budget", status: .ready, audioPath: "/fixture/audio/2", meetingApp: .teams), store)
    let voice = try store.saveVoice(Voice(
        name: "Fixture Voice", encryptedEmbedding: Data(repeating: 0xAB, count: 64), createdAt: at(2), updatedAt: at(2)))
    let speakers = try store.writer.write { db -> [NoteSpeaker] in
        var one = NoteSpeaker(noteId: twoChannel, label: "Speaker 1", displayName: "Avery", voiceId: voice.id, createdAt: at(2))
        var two = NoteSpeaker(noteId: twoChannel, label: "Speaker 2", createdAt: at(2))
        try one.insert(db)
        try two.insert(db)
        var s0 = NoteSegment(noteId: twoChannel, speakerId: one.id, startTime: 0, endTime: 4.5, text: "Speaker one opens the agenda.", ordinal: 0)
        var s1 = NoteSegment(noteId: twoChannel, speakerId: two.id, startTime: 4.5, endTime: 9, text: "Speaker two answers about the budget.", ordinal: 1)
        try s0.insert(db)
        try s1.insert(db)
        return [one, two]
    }
    precondition(speakers.count == 2)

    // 3. Silent-tail failed note.
    _ = try insert(Note(
        title: "Silent tail", createdAt: at(3), updatedAt: at(3.1), durationSeconds: 95,
        transcript: "Only the first minute had speech before the silent tail.", status: .failed,
        audioPath: "/fixture/audio/3"), store)

    // 4 and 5. Interrupted notes.
    _ = try insert(Note(
        title: "Interrupted recording", createdAt: at(4), updatedAt: at(4), durationSeconds: 40,
        transcript: "Recording was interrupted mid sentence", status: .recording, audioPath: "/fixture/audio/4"), store)
    _ = try insert(Note(
        title: "Interrupted processing", createdAt: at(5), updatedAt: at(5), durationSeconds: 60,
        transcript: "Processing was interrupted after transcription", status: .processing, audioPath: "/fixture/audio/5"), store)

    // 6. Imported file.
    _ = try insert(Note(
        title: "Imported podcast", createdAt: at(6), updatedAt: at(6.3), durationSeconds: 2_400,
        transcript: "Imported file transcript about gardening and compost.", summary: "- Compost basics",
        status: .ready, audioPath: "/fixture/audio/6", source: .file, sourcePath: "/fixture/import/podcast.m4a"), store)

    // 7. Note in a folder.
    _ = try insert(Note(
        title: "Filed note", createdAt: at(7), updatedAt: at(7.1), durationSeconds: 120,
        transcript: "Filed note transcript about the hiring plan.", status: .ready, folderId: folder.id), store)

    // 8. Calendar link and name suggestions (plus attendees where the ref has them).
    let calendar = try insert(Note(
        title: "Weekly sync with Acme", createdAt: at(8), updatedAt: at(8.4), durationSeconds: 1_500,
        transcript: "Calendar note transcript where Jordan and Riley review the pilot.", status: .ready,
        audioPath: "/fixture/audio/8", meetingApp: .zoom), store)
    try store.writer.write { db in
        #if HAS_MEETINGS
        try NoteCalendarLink(
            noteId: calendar, eventIdentifier: "fixture-event-8", eventTitle: "Weekly sync with Acme",
            eventStart: at(8), eventEnd: at(8.5), seriesKey: "fixture-series-acme").insert(db)
        try NoteAttendee(noteId: calendar, ordinal: 0, name: "Jordan Fixture", companyDomain: "acme.example", isSelf: false).insert(db)
        try NoteAttendee(noteId: calendar, ordinal: 1, name: "", companyDomain: "acme.example", isSelf: false).insert(db)
        try NoteAttendee(noteId: calendar, ordinal: 2, name: "Riley Self", companyDomain: nil, isSelf: true).insert(db)
        #else
        try NoteCalendarLink(
            noteId: calendar, eventIdentifier: "fixture-event-8", eventTitle: "Weekly sync with Acme",
            eventStart: at(8), eventEnd: at(8.5)).insert(db)
        #endif
        try NoteNameSuggestion(noteId: calendar, ordinal: 0, name: "Jordan Fixture").insert(db)
        try NoteNameSuggestion(noteId: calendar, ordinal: 1, name: "Riley Self").insert(db)
    }

    // 9. Five action items with details, two of them done.
    var actions = Note(
        title: "Action heavy review", createdAt: at(9), updatedAt: at(9.5), durationSeconds: 900,
        transcript: "Action note transcript where owners take five tasks.", summary: "- Five tasks assigned",
        status: .ready, audioPath: "/fixture/audio/9", meetingApp: .zoom)
    let details = [
        ActionItemDetail(owner: "Priya", task: "Send the deck", due: "by Friday"),
        ActionItemDetail(owner: "", task: "Book the venue", due: ""),
        ActionItemDetail(owner: "Sam", task: "Draft the FAQ", due: "next week"),
        ActionItemDetail(owner: "You", task: "Email legal", due: ""),
        ActionItemDetail(owner: "Lee", task: "Update the tracker", due: "tomorrow"),
    ]
    actions.setActionItems(details.map(\.line), details: details)
    let actionNote = try insert(actions, store)
    try store.writer.write { db in
        try NoteActionItemStatus(noteId: actionNote, itemIndex: 1, isDone: true, updatedAt: at(9.2)).insert(db)
        try NoteActionItemStatus(noteId: actionNote, itemIndex: 3, isDone: true, updatedAt: at(9.3)).insert(db)
    }

    // 10. Decided lines.
    _ = try insert(Note(
        title: "Decision meeting", createdAt: at(10), updatedAt: at(10.2), durationSeconds: 1_100,
        transcript: "Decision note transcript where the team picks a launch day.",
        summary: "- Reviewed the launch\n- Decided: launch on Tuesday\n- Decided: keep the free tier",
        actionItems: ["Write the launch post"], status: .ready, meetingApp: .zoom), store)

    // 11. Empty transcript.
    _ = try insert(Note(title: "Empty note", createdAt: at(11), updatedAt: at(11), transcript: "", status: .ready), store)

    // 12. Unicode, emoji and right-to-left text.
    _ = try insert(Note(
        title: "Café 東京 🎉", createdAt: at(12), updatedAt: at(12.1), durationSeconds: 200,
        transcript: "Café naïve résumé, 東京で会議, emoji 🎉👩🏽‍💻, مرحبا بالعالم and שלום עולם.",
        summary: "- Ünïcödé summary مرحبا", actionItems: ["Répondre à José 🎯"], status: .ready, language: "fr"), store)

    // 13. A 50 kB transcript.
    _ = try insert(Note(
        title: "Long all hands", createdAt: at(13), updatedAt: at(13.9), durationSeconds: 3_600,
        transcript: longTranscript(), summary: "- Long meeting", status: .ready, audioPath: "/fixture/audio/13"), store)

    #if HAS_MEETINGS
    try store.writer.write { db in
        try MeetingConsent(noteId: actionNote, method: .chatMessage, at: at(9)).insert(db)
        try MeetingConsent(noteId: calendar, method: .saidAloud, at: at(8)).insert(db)
    }
    _ = try store.addJot(noteId: actionNote, text: "! ship the beta on Monday", atSeconds: 120, now: at(9))
    _ = try store.addJot(noteId: actionNote, text: "? does it include the EU team", atSeconds: 240, now: at(9))
    _ = try store.addJot(noteId: actionNote, text: "plain jot typed after the call", atSeconds: nil, now: at(9.6))
    #endif

    // Dictations, dictionary, snippets, learned items and action records.
    let dictation = try store.save(Dictation(
        createdAt: at(20), rawText: "um send the fixture report", text: "Send the fixture report.",
        appBundleID: "com.example.mail", appName: "Mail", durationSeconds: 2.5, latencyMs: 310))
    _ = try store.save(Dictation(
        createdAt: at(21), rawText: "second fixture dictation", text: "Second fixture dictation.",
        durationSeconds: 1.2, latencyMs: 200))
    _ = try store.save(DictionaryEntry(term: "Hushy", soundsLike: ["hushie"], createdAt: at(22)))
    _ = try store.save(Snippet(trigger: "fxsig", expansion: "Fixture signature", createdAt: at(22)))
    try store.writer.write { db in
        var item = LearnedItem(
            kind: .term, key: "kubernetes", value: "Kubernetes", heardAs: ["cooper netties"], status: .active,
            observations: 3, confirmed: true, confidence: 0.9, createdAt: at(23), lastSeenAt: at(23))
        try item.insert(db)
    }
    _ = try store.save(ActionRecord(
        createdAt: at(24), kind: .createReminder, title: "Fixture reminder", sourceText: "remind me to water plants",
        dictationID: dictation.id))

    try store.writer.writeWithoutTransaction { db in try db.checkpoint(.truncate) }
}

func sha(_ text: String) -> String {
    SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
}

func list(_ url: URL) throws {
    let store = try Store(url: url)
    for note in try store.notes(limit: 10_000).sorted(by: { ($0.id ?? 0) < ($1.id ?? 0) }) {
        print([String(note.id ?? -1), note.status.rawValue, sha(note.title), sha(note.transcript), sha(note.summary),
               String(note.actionItems.count)].joined(separator: "\t"))
    }
}

let arguments = CommandLine.arguments
guard arguments.count == 3 else {
    FileHandle.standardError.write(Data("usage: fixture-writer write|list <path>\n".utf8))
    exit(2)
}
let path = URL(fileURLWithPath: arguments[2])
switch arguments[1] {
case "write": try write(to: path)
case "list": try list(path)
default:
    FileHandle.standardError.write(Data("unknown mode \(arguments[1])\n".utf8))
    exit(2)
}
