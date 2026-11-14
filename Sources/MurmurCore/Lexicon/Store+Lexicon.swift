import Foundation
import GRDB

extension Store {
    /// Everything `PersonalLexicon.build` reads from the database, in one read transaction: kept English dictations
    /// (pasted and not changed afterwards, newest first), the people on recorded meetings (from the calendar, which
    /// the person already allowed), learned items and kept-as-heard reverts. Read-only; nothing is written.
    public func lexiconInputs(historyLimit: Int = PersonalLexicon.maxHistoryRows) throws -> PersonalLexicon.Inputs {
        try writer.read { db in
            var inputs = PersonalLexicon.Inputs()
            inputs.history = try Row.fetchAll(db, sql: """
                SELECT text, createdAt FROM dictation
                WHERE status = ? AND (editState IS NULL OR editState != ?) AND (language IS NULL OR language = 'en')
                ORDER BY createdAt DESC LIMIT ?
                """, arguments: [Dictation.Status.inserted.rawValue, Dictation.EditState.edited.rawValue, historyLimit])
                .map { PersonalLexicon.HistoryText(text: $0["text"], date: $0["createdAt"]) }
            inputs.attendees = try Row.fetchAll(db, sql: """
                SELECT a.name AS name, n.createdAt AS createdAt FROM note_attendee a JOIN note n ON n.id = a.noteId
                WHERE a.isSelf = 0 ORDER BY n.createdAt DESC LIMIT ?
                """, arguments: [historyLimit])
                .map { PersonalLexicon.DatedName(name: $0["name"], date: $0["createdAt"]) }
            inputs.learned = try LearnedItem.fetchAll(db)
            inputs.keepHeard = try KeepHeardEntry.fetchAll(db)
            return inputs
        }
    }
}
