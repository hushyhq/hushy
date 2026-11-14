import Foundation
import GRDB

extension Store {
    public func editObservationGeneration(forDictation id: Int64) throws -> String? {
        try writer.read { db in
            try String.fetchOne(db, sql: "SELECT generation FROM dictation_edit_observation WHERE dictationID = ?", arguments: [id])
        }
    }

    public func isCurrentEditObservation(dictationID: Int64, expectedInsertedText: String, expectedGeneration: String? = nil) throws -> Bool {
        try writer.read { db in
            guard let row = try Dictation.fetchOne(db, key: dictationID) else { return false }
            if let expectedGeneration,
               try String.fetchOne(db, sql: "SELECT generation FROM dictation_edit_observation WHERE dictationID = ?", arguments: [dictationID]) != expectedGeneration { return false }
            return row.status == .inserted && !row.text.isEmpty && row.text == expectedInsertedText
        }
    }

    /// When the person next pasted a dictation after this one, if they have.
    public func nextInsertedDictationDate(after id: Int64) throws -> Date? {
        try writer.read { db in
            try Dictation.filter(Column("id") > id).filter(Column("status") == Dictation.Status.inserted.rawValue)
                .order(Column("id")).fetchOne(db)?.createdAt
        }
    }

    /// Latest on-device observation. The row contains only a closed verdict and coverage reason.
    public func editObservation(forDictation id: Int64) throws -> DictationEditObservation? {
        try writer.read { db in try DictationEditObservation.fetchOne(db, key: id) }
    }

    /// Replaces the latest observation if the history row still exists. Returns false for a
    /// delayed watcher whose dictation was deleted while it slept.
    @discardableResult
    public func recordEditObservation(_ observation: DictationEditObservation, expectedInsertedText: String? = nil, expectedGeneration: String? = nil) throws -> Bool {
        try writer.write { db in
            guard let dictation = try Dictation.fetchOne(db, key: observation.dictationID),
                  dictation.status == .inserted, !dictation.text.isEmpty,
                  expectedInsertedText == nil || dictation.text == expectedInsertedText
            else { return false }
            if let expectedGeneration,
               try String.fetchOne(db, sql: "SELECT generation FROM dictation_edit_observation WHERE dictationID = ?", arguments: [observation.dictationID]) != expectedGeneration { return false }
            try db.execute(
                sql: """
                    INSERT INTO dictation_edit_observation (dictationID, generation, verdict, coverage)
                    VALUES (?, ?, ?, ?)
                    ON CONFLICT(dictationID) DO UPDATE SET verdict = excluded.verdict, coverage = excluded.coverage
                    """,
                arguments: [observation.dictationID, UUID().uuidString, observation.verdict.rawValue, observation.coverage.rawValue])
            let compatibleState: String? = switch observation.verdict {
            case .kept: Dictation.EditState.kept.rawValue
            case .edited: Dictation.EditState.edited.rawValue
            case .unknown: nil
            }
            try db.execute(
                sql: "UPDATE dictation SET editState = ? WHERE id = ?",
                arguments: [compatibleState, observation.dictationID])
            return true
        }
    }

}
