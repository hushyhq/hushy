import Foundation
import GRDB

/// The one mapping from Hushy's stored meeting (the note, its facts, its calendar link, attendees and speaker
/// turns) to `MeetingRecord`. Decisions and action items come from the visible facts (`MeetingFact.isVisible`); the
/// summary gives only key points (`LegacySummary`).
extension MeetingRecord {
    public init(
        note: Note, noteId: Int64, facts: [MeetingFact], link: NoteCalendarLink?, attendees: [NoteAttendee],
        segments: [(speaker: String?, start: Double, text: String)], jots: [MeetingJot] = []
    ) {
        let sections = Dictionary(uniqueKeysWithValues: MeetingFactText.sections(facts).map { ($0.kind, $0.facts) })
        // A jot fact is the person's own "!" line, already among the typed decisions.
        let modelDecisions = (sections[.decision] ?? []).filter { $0.origin != .jot }.map(\.text)
        let decisions = Self.typedFirst(jots.filter(\.isDecision).map(\.shownText), then: modelDecisions)
        // A note saved without facts (an Ask answer kept as a note) keeps its own items.
        let items = facts.isEmpty
            ? note.actionItems.indices.compactMap { index in note.actionItemDetail(at: index).map { ActionItem(owner: $0.owner, task: $0.task, due: $0.due) } }
            : (sections[.action] ?? []).map { fact in
                ActionItem(owner: fact.ownerText ?? "", task: fact.text, due: fact.due ?? "", isDone: fact.status == .done)
            }
        let turns = segments.isEmpty
            ? Sentences.split(note.transcript.replacingOccurrences(of: "\n", with: " "))
                .map { Turn(text: $0.trimmingCharacters(in: .whitespaces)) }.filter { !$0.text.isEmpty }
            : segments.map { Turn(speaker: Self.namedSpeaker($0.speaker), startSeconds: $0.start, text: $0.text) }
        let start = link?.eventStart ?? note.createdAt
        self.init(
            noteId: noteId, title: note.title, start: start,
            end: link?.eventEnd ?? start.addingTimeInterval(max(note.durationSeconds, 0)),
            seriesKey: link?.seriesKey,
            attendees: attendees.map { Attendee(name: $0.name, companyDomain: $0.companyDomain, isSelf: $0.isSelf) },
            turns: turns, keyPoints: LegacySummary.keyPoints(note.summary), decisions: decisions, actionItems: items)
    }

    /// The person's own "!" lines, then the extracted decisions minus any that restate one of them.
    static func typedFirst(_ typed: [String], then summarised: [String]) -> [String] {
        let typedWords = typed.map(MeetingWords.content)
        return typed + summarised.filter { text in
            !typedWords.contains { MeetingWords.restates($0, MeetingWords.content(text)) }
        }
    }

    /// "Speaker 2" names nobody; a renamed or remembered speaker does.
    static func namedSpeaker(_ label: String?) -> String? {
        guard let label = label?.trimmingCharacters(in: .whitespaces), !label.isEmpty else { return nil }
        let unnamed = label.range(of: #"^Speaker \d+$"#, options: .regularExpression) != nil
        return unnamed ? nil : label
    }
}

extension Store {
    /// Every ready note as a meeting record, newest first. One read transaction.
    public func meetingRecords(limit: Int = 2_000) throws -> [MeetingRecord] {
        try writer.read { db in try Self.meetingRecords(db, limit: limit) }
    }

    /// The same, inside a read the caller holds (the MCP helper's read-only database).
    static func meetingRecords(_ db: Database, limit: Int = 2_000) throws -> [MeetingRecord] {
        let notes = try Note.filter(Column("status") == Note.Status.ready.rawValue).order(Column("createdAt").desc).limit(limit).fetchAll(db)
        return try notes.compactMap { note -> MeetingRecord? in
            guard let id = note.id else { return nil }
            let facts = try Self.visibleFacts(db, noteId: id)
            let link = try NoteCalendarLink.fetchOne(db, key: id)
            let attendees = try NoteAttendee.filter(Column("noteId") == id).order(Column("ordinal")).fetchAll(db)
            // Both sides, from the turns: one segment per line of the shown transcript when several voices
            // spoke; a one-voice note is split into sentences by the initialiser. A legacy note (one turn
            // from before v28) keeps its stored speaker segments, the one legacy reader left.
            let transcript = try Self.transcript(db, noteId: id)
            let segments = transcript.hasSeveralVoices
                ? transcript.lines.map { (speaker: $0.label, start: $0.start ?? 0, text: $0.text) }
                : transcript.turns.allSatisfy({ $0.origin == .legacy }) ? try Self.legacySegments(db, noteId: id) : []
            let jots = try MeetingJot.filter(Column("noteId") == id).fetchAll(db)
            return MeetingRecord(note: note, noteId: id, facts: facts, link: link, attendees: attendees, segments: segments, jots: jots)
        }
    }

    /// A legacy note's diarization rows, named as the timed view names them.
    static func legacySegments(_ db: Database, noteId: Int64) throws -> [(speaker: String?, start: Double, text: String)] {
        let rows = try Row.fetchAll(db, sql: """
            SELECT s.startTime, s.text, sp.displayName, sp.label, v.name AS voiceName
            FROM note_segment s
            LEFT JOIN note_speaker sp ON sp.id = s.speakerId
            LEFT JOIN voice v ON v.id = sp.voiceId
            WHERE s.noteId = ? ORDER BY s.ordinal
            """, arguments: [noteId])
        return rows.map { row -> (speaker: String?, start: Double, text: String) in
            let named = (row["displayName"] as String?).flatMap { $0.isEmpty ? nil : $0 }
            return (named ?? row["voiceName"] ?? row["label"], row["startTime"], row["text"])
        }
    }
}
