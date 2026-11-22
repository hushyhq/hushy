import Foundation
import GRDB

extension Store {
    /// `note` with every renamed speaker's label ("Speaker 2") replaced by its name.
    static func applyingSpeakerNames(_ db: Database, noteId: Int64, to note: Note) throws -> Note {
        let renamed = try NoteSpeaker.filter(Column("noteId") == noteId && Column("displayName") != nil).fetchAll(db)
        return renamed.reduce(note) { current, speaker in
            DigestSpeakerRename.rewrite(current, from: [speaker.label], to: speaker.displayLabel) ?? current
        }
    }

    /// Reads note `id` and its checked-off action-item indexes, lets `transform` decide the new
    /// note and checked-off set, and writes both — in one write transaction, so a rename or
    /// check-off made while a model was running is read, not overwritten (`DiarizedDigest`); a
    /// speaker renamed meanwhile has its name applied to the new digest.
    /// Returns the saved note, or nil when the note is gone or `transform` returns nil.
    @discardableResult
    public func updateNoteDigest(
        id: Int64, _ transform: (Note, Set<Int>) -> (note: Note, done: Set<Int>)?
    ) throws -> Note? {
        try writer.write { db in
            guard let stored = try Note.fetchOne(db, key: id) else { return nil }
            let done = try NoteActionItemStatus
                .filter(Column("noteId") == id && Column("isDone") == true)
                .fetchAll(db).map(\.itemIndex)
            guard let (note, newDone) = transform(stored, Set(done)) else { return nil }
            // A speaker renamed while the model ran: the digest was written with the old label.
            var copy = try Self.applyingSpeakerNames(db, noteId: id, to: note)
            copy.id = id
            copy.folderId = stored.folderId
            copy.updatedAt = Date()
            try copy.updateBesideTranscript(db)
            if newDone != Set(done) {
                try NoteActionItemStatus.filter(Column("noteId") == id).deleteAll(db)
                for index in newDone.sorted() {
                    try NoteActionItemStatus(noteId: id, itemIndex: index, isDone: true).insert(db)
                }
            }
            return copy
        }
    }
}

extension Store {
    /// `renameSpeaker`, plus the rename carried into the note's summary and action items
    /// (`DigestSpeakerRename`) in the same transaction. An empty name clears the rename and
    /// writes the stable label ("Speaker 2") back.
    public func renameSpeakerUpdatingDigest(id: Int64, to displayName: String) throws {
        let trimmed = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        try writer.write { db in
            guard let speaker = try NoteSpeaker.fetchOne(db, key: id) else { return }
            let shownBefore = try Self.transcript(db, noteId: speaker.noteId).names[id]
            try db.execute(
                sql: "UPDATE note_speaker SET displayName = ? WHERE id = ?",
                arguments: [trimmed.isEmpty ? nil : trimmed, id])
            let shownAfter = try Self.materializeTranscript(db, noteId: speaker.noteId).names[id] ?? speaker.label
            let old = Array(Set([speaker.label] + [speaker.displayName, shownBefore].compactMap { $0 })).sorted()
            try rewriteDigest(db, noteId: speaker.noteId, from: old, to: shownAfter)
            try Self.renameFactOwners(db, noteId: speaker.noteId, speakerId: id, to: shownAfter)
        }
    }

    /// `mergeSpeakers`, plus the source speaker's names rewritten to the target's display label.
    public func mergeSpeakersUpdatingDigest(sourceId: Int64, intoTargetId targetId: Int64) throws {
        guard sourceId != targetId else { return }
        try writer.write { db in
            guard let source = try NoteSpeaker.fetchOne(db, key: sourceId),
                  let target = try NoteSpeaker.fetchOne(db, key: targetId) else { return }
            try db.execute(
                sql: "UPDATE note_segment SET speakerId = ? WHERE speakerId = ?", arguments: [targetId, sourceId])
            try db.execute(sql: "UPDATE turn SET speakerId = ? WHERE speakerId = ?", arguments: [targetId, sourceId])
            try db.execute(sql: "UPDATE meeting_fact SET ownerSpeakerId = ? WHERE ownerSpeakerId = ?", arguments: [targetId, sourceId])
            try NoteSpeaker.deleteOne(db, key: sourceId)
            try Self.materializeTranscript(db, noteId: source.noteId)
            let old = [source.label] + (source.displayName.map { [$0] } ?? [])
            try rewriteDigest(db, noteId: source.noteId, from: old, to: target.displayLabel)
            let shown = try Self.transcript(db, noteId: source.noteId).names[targetId] ?? target.displayLabel
            try Self.renameFactOwners(db, noteId: source.noteId, speakerId: targetId, to: shown)
        }
    }

    func rewriteDigest(_ db: Database, noteId: Int64, from old: [String], to new: String) throws {
        guard let note = try Note.fetchOne(db, key: noteId),
              var rewritten = DigestSpeakerRename.rewrite(note, from: old, to: new) else { return }
        rewritten.updatedAt = Date()
        try rewritten.updateBesideTranscript(db)
    }

    /// Facts owned by a speaker show the name that speaker is now shown with; the legacy columns follow.
    static func renameFactOwners(_ db: Database, noteId: Int64, speakerId: Int64, to shown: String) throws {
        try db.execute(sql: "UPDATE meeting_fact SET ownerText = ? WHERE ownerSpeakerId = ?", arguments: [shown, speakerId])
        try cacheLegacyActionItems(db, noteId: noteId)
    }
}
