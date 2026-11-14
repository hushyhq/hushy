import Foundation
import GRDB

/// Turns are the only transcript (meetings schema freeze, section 4). `note.transcript` is a cache of
/// `NoteTranscript.rendered`, written only by `materializeTranscript`, inside the transaction that
/// changed the turns or the names they are shown with.
extension Store {
    /// The note's turns with the names the speaker rule gives them.
    public func transcript(noteId: Int64) throws -> NoteTranscript {
        try writer.read { db in try Self.transcript(db, noteId: noteId) }
    }

    static func transcript(_ db: Database, noteId: Int64) throws -> NoteTranscript {
        let turns = try NoteTurn.filter(Column("noteId") == noteId).order(Column("ordinal")).fetchAll(db)
        let speakers = try NoteSpeaker.filter(Column("noteId") == noteId).fetchAll(db)
        let assignments = try SpeakerAssignment.filter(Column("noteId") == noteId).fetchAll(db)
        var names: [Int64: String] = [:]
        for speaker in speakers {
            guard let id = speaker.id else { continue }
            names[id] = SpeakerNameRule.name(for: speaker, assignments: assignments)
        }
        return NoteTranscript(turns: turns, names: names)
    }

    /// The note's speakers in the order they were saved.
    public func noteSpeakers(noteId: Int64) throws -> [NoteSpeaker] {
        try writer.read { db in try NoteSpeaker.filter(Column("noteId") == noteId).order(Column("id")).fetchAll(db) }
    }

    /// Whether the note has a timed turn with words: one indexed lookup, cheap enough for a menu.
    public func hasTimedTurns(noteId: Int64) throws -> Bool {
        try writer.read { db in
            try Bool.fetchOne(db, sql: """
                SELECT EXISTS(SELECT 1 FROM turn WHERE noteId = ? AND t0 IS NOT NULL AND t1 IS NOT NULL AND trim(text) <> '')
                """, arguments: [noteId]) ?? false
        }
    }

    /// Rewrites the note's transcript cache from its turns. The only writer of `note.transcript`
    /// outside the insert of a new note.
    @discardableResult
    static func materializeTranscript(_ db: Database, noteId: Int64) throws -> NoteTranscript {
        let transcript = try transcript(db, noteId: noteId)
        try db.execute(
            sql: "UPDATE note SET transcript = ? WHERE id = ? AND transcript IS NOT ?",
            arguments: [transcript.rendered, noteId, transcript.rendered])
        return transcript
    }

    /// Adds turns after the note's last one and rewrites the cache, in one transaction. For a
    /// recording or an import still in progress. Nil, with nothing written, when the note is gone.
    @discardableResult
    public func appendTurns(noteId: Int64, turns: [NoteTurn]) throws -> NoteTranscript? {
        try writer.write { db in
            guard try Note.exists(db, key: noteId) else { return nil }
            var next = try Int.fetchOne(db, sql: "SELECT MAX(ordinal) + 1 FROM turn WHERE noteId = ?", arguments: [noteId]) ?? 0
            for turn in turns {
                var row = turn
                row.id = nil
                row.noteId = noteId
                row.ordinal = next
                next += 1
                try row.insert(db)
            }
            return try Self.materializeTranscript(db, noteId: noteId)
        }
    }

    /// Replaces the note's speakers, speaker segments (the timed view's rows), turns and machine
    /// name guesses with an assembly, and rewrites the cache, in one transaction. False when the
    /// note is gone.
    @discardableResult
    public func replaceAssembly(noteId: Int64, assembly: TurnAssembler.Assembly, origin: NoteTurn.Origin = .capture) throws -> Bool {
        try writer.write { db in
            guard try Note.exists(db, key: noteId) else { return false }
            try NoteSegment.filter(Column("noteId") == noteId).deleteAll(db)
            try NoteSpeaker.filter(Column("noteId") == noteId).deleteAll(db)
            try NoteTurn.filter(Column("noteId") == noteId).deleteAll(db)
            var speakerIds: [Int64?] = []
            for speaker in assembly.speakers {
                var row = NoteSpeaker(noteId: noteId, label: speaker.label)
                try row.insert(db)
                speakerIds.append(row.id)
                if speaker.isOwner, let id = row.id, let name = assembly.ownerName.flatMap(assignmentName) {
                    try SpeakerAssignment(speakerId: id, noteId: noteId, name: name, source: .micChannel, confidence: 1).insert(db)
                }
            }
            var segmentOrdinal = 0
            for (ordinal, turn) in assembly.turns.enumerated() {
                let speakerId = speakerIds.indices.contains(turn.speakerIndex) ? speakerIds[turn.speakerIndex] : nil
                var row = NoteTurn(
                    noteId: noteId, ordinal: ordinal, stream: turn.stream, speakerId: speakerId, t0: turn.t0, t1: turn.t1,
                    text: turn.text, words: turn.words, origin: origin)
                try row.insert(db)
                guard !turn.text.isEmpty else { continue }
                var segment = NoteSegment(
                    noteId: noteId, speakerId: speakerId, startTime: turn.t0, endTime: turn.t1, text: turn.text,
                    ordinal: segmentOrdinal)
                try segment.insert(db)
                segmentOrdinal += 1
            }
            try Self.assignOneToOne(db, noteId: noteId, assembly: assembly, speakerIds: speakerIds)
            try Self.materializeTranscript(db, noteId: noteId)
            return true
        }
    }

    /// The calendar's guess for a 1:1: with exactly one other attendee and exactly one other voice
    /// on the call, that voice is probably them (confidence 0.9, so the name rule shows it).
    static let oneToOneConfidence = 0.9

    static func assignOneToOne(
        _ db: Database, noteId: Int64, assembly: TurnAssembler.Assembly, speakerIds: [Int64?]
    ) throws {
        guard assembly.speakers.contains(where: \.isOwner) else { return }
        let others = assembly.speakers.indices.filter { !assembly.speakers[$0].isOwner }
        let attendees = try NoteAttendee.filter(Column("noteId") == noteId && Column("isSelf") == false).fetchAll(db)
        guard others.count == 1, attendees.count == 1, let attendee = attendees.first,
              let speakerId = speakerIds[others[0]], let name = assignmentName(attendee.name) else { return }
        try SpeakerAssignment(
            speakerId: speakerId, noteId: noteId, name: name, source: .calendar, confidence: oneToOneConfidence,
            attendeeOrdinal: attendee.ordinal).insert(db)
    }
}

/// A name fit for `speaker_assignment.name` (1 to 80 code points), or nil when blank.
func assignmentName(_ text: String) -> String? {
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return nil }
    var view = String.UnicodeScalarView()
    view.append(contentsOf: trimmed.unicodeScalars.prefix(80))
    return String(view)
}
