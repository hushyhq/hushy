import Foundation
import GRDB

/// Content-free edit-observation outcome for one saved dictation.
/// The field value and the inserted words never enter this record.
public struct DictationEditObservation: Codable, Sendable, Equatable, FetchableRecord, TableRecord {
    public enum Verdict: String, Codable, Sendable, CaseIterable {
        case kept
        case edited
        case unknown
    }

    public enum Coverage: String, Codable, Sendable, CaseIterable {
        case observed
        case secure
        case unknownSecurity
        case fieldUnreadable
        case fieldCleared
        case insufficientSignal
        case notAttempted
    }

    public enum ValidationError: Error, Sendable, Equatable {
        case verdictDoesNotMatchCoverage
    }

    public static let databaseTableName = "dictation_edit_observation"

    public let dictationID: Int64
    public let verdict: Verdict
    public let coverage: Coverage

    public init(dictationID: Int64, verdict: Verdict, coverage: Coverage) throws {
        guard (coverage == .observed) == (verdict != .unknown) else {
            throw ValidationError.verdictDoesNotMatchCoverage
        }
        self.dictationID = dictationID
        self.verdict = verdict
        self.coverage = coverage
    }

    public init(row: Row) throws {
        dictationID = row["dictationID"]
        guard let decodedVerdict = Verdict(rawValue: row["verdict"]),
              let decodedCoverage = Coverage(rawValue: row["coverage"]),
              (decodedCoverage == .observed) == (decodedVerdict != .unknown)
        else {
            throw ValidationError.verdictDoesNotMatchCoverage
        }
        verdict = decodedVerdict
        coverage = decodedCoverage
    }


}

public enum DictationEditObservationSchema {
    public static func migrate(_ db: Database) throws {
        try db.create(table: DictationEditObservation.databaseTableName) { t in
            t.column("dictationID", .integer).primaryKey()
                .references("dictation", onDelete: .cascade)
            t.column("generation", .text).notNull()
            t.column("verdict", .text).notNull()
                .check(sql: "verdict IN ('kept', 'edited', 'unknown')")
            t.column("coverage", .text).notNull()
                .check(sql: "coverage IN ('observed', 'secure', 'unknownSecurity', 'fieldUnreadable', 'fieldCleared', 'insufficientSignal', 'notAttempted')")
            t.check(sql: "(coverage = 'observed' AND verdict IN ('kept', 'edited')) OR (coverage <> 'observed' AND verdict = 'unknown')")
        }
    }
}
