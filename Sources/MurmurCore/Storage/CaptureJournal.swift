import Foundation
import GRDB

/// Which side of a recording a segment holds: the person's microphone, the call's audio, or an imported file.
public enum CaptureStream: String, Codable, Sendable, CaseIterable {
    case mic, system, file
}

/// One durable piece of a recording (migration v27): a sealed audio file of up to about 30 s, or a gap with its
/// reason. The capture journal is the list of these for a note, and the finalize runner resumes from it.
public struct CaptureSegment: Codable, Sendable, Equatable, Identifiable, FetchableRecord, MutablePersistableRecord {
    public static let databaseTableName = "capture_segment"

    public enum Kind: String, Codable, Sendable { case audio, gap }
    public enum State: String, Codable, Sendable { case open, sealed, transcribed, failed }
    public enum GapReason: String, Codable, Sendable { case silence, deviceLost, stall, permission, interrupted }
    /// `wav` and `wav.enc` are legacy chunk files adopted into rows.
    public enum Format: String, Codable, Sendable { case hseg1, wav, wavEncrypted = "wav.enc" }

    public var id: Int64?
    public var noteId: Int64
    public var stream: CaptureStream
    public var seq: Int
    public var kind: Kind
    /// Note seconds, from host time, so a stalled stream keeps its alignment.
    public var t0: Double
    public var duration: Double
    public var sampleCount: Int
    /// Relative to the note's audio folder; nil for a gap.
    public var file: String?
    public var format: Format?
    /// Set when the segment is sealed.
    public var sha256: String?
    public var state: State
    public var gapReason: GapReason?
    public var speechRatio: Double?
    public var peak: Double?
    public var asrAttempts: Int
    /// A content-free code, never text.
    public var errorCode: String?
    public var createdAt: Date
    public var updatedAt: Date

    public init(
        id: Int64? = nil, noteId: Int64, stream: CaptureStream, seq: Int, kind: Kind, t0: Double, duration: Double,
        sampleCount: Int = 0, file: String? = nil, format: Format? = nil, sha256: String? = nil, state: State,
        gapReason: GapReason? = nil, speechRatio: Double? = nil, peak: Double? = nil, asrAttempts: Int = 0,
        errorCode: String? = nil, createdAt: Date = Date(), updatedAt: Date = Date()
    ) {
        self.id = id
        self.noteId = noteId
        self.stream = stream
        self.seq = seq
        self.kind = kind
        self.t0 = t0
        self.duration = duration
        self.sampleCount = sampleCount
        self.file = file
        self.format = format
        self.sha256 = sha256
        self.state = state
        self.gapReason = gapReason
        self.speechRatio = speechRatio
        self.peak = peak
        self.asrAttempts = asrAttempts
        self.errorCode = errorCode
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    public mutating func didInsert(_ inserted: InsertionSuccess) { id = inserted.rowID }
}

/// A note's segments as one read sees them, ordered by sequence and then stream.
public struct CaptureJournal: Sendable, Equatable {
    public let noteId: Int64
    public let segments: [CaptureSegment]
}

/// Where a note's finalize run stands. Each step is resumable; `done` and `needsAttention` are the ends.
public enum FinalizeStep: String, Codable, Sendable, CaseIterable {
    case capturing, sealing, transcribing, assembling, writing, exporting, done, needsAttention
}

/// A note's resume point (`note_finalize`, migration v27): one row per note.
public struct FinalizeState: Codable, Sendable, Equatable, FetchableRecord, PersistableRecord {
    public static let databaseTableName = "note_finalize"

    public var noteId: Int64
    public var step: FinalizeStep
    public var attempts: Int
    /// A content-free code.
    public var reason: String?
    public var pipelineVersion: Int
    public var updatedAt: Date

    public init(noteId: Int64, step: FinalizeStep, attempts: Int = 0, reason: String? = nil, pipelineVersion: Int, updatedAt: Date = Date()) {
        self.noteId = noteId
        self.step = step
        self.attempts = attempts
        self.reason = reason
        self.pipelineVersion = pipelineVersion
        self.updatedAt = updatedAt
    }
}

extension Store {
    /// The note's whole journal in one read transaction.
    public func captureJournal(noteId: Int64) throws -> CaptureJournal {
        try writer.read { db in
            CaptureJournal(noteId: noteId, segments: try CaptureSegment
                .filter(Column("noteId") == noteId)
                .order(Column("seq"), Column("stream"))
                .fetchAll(db))
        }
    }

    public func finalizeState(noteId: Int64) throws -> FinalizeState? {
        try writer.read { db in try FinalizeState.fetchOne(db, key: noteId) }
    }

    /// Moves a note from `current` to `next` only while it is still at `current` (compare and swap), so two runners
    /// or a repeated step never both apply. `current == nil` creates the row, only when the note has none. A move
    /// resets `attempts`. Returns whether this call made the change.
    @discardableResult
    public func advanceFinalize(
        noteId: Int64, from current: FinalizeStep?, to next: FinalizeStep, reason: String? = nil,
        pipelineVersion: Int, now: Date = Date()
    ) throws -> Bool {
        try writer.write { db in
            if let current {
                try db.execute(sql: """
                    UPDATE note_finalize SET step = ?, attempts = 0, reason = ?, pipelineVersion = ?, updatedAt = ?
                    WHERE noteId = ? AND step = ?
                    """, arguments: [next, reason, pipelineVersion, now, noteId, current])
            } else {
                try db.execute(sql: """
                    INSERT OR IGNORE INTO note_finalize (noteId, step, attempts, reason, pipelineVersion, updatedAt)
                    VALUES (?, ?, 0, ?, ?, ?)
                    """, arguments: [noteId, next, reason, pipelineVersion, now])
            }
            return db.changesCount == 1
        }
    }
}

extension FinalizeStep: DatabaseValueConvertible {}
