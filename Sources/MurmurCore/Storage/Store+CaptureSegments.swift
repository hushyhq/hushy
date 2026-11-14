import Foundation
import GRDB

/// Writes to the capture journal (`capture_segment`, `note_finalize`, migration v27) for the journal writer and the
/// finalize runner (meetings schema freeze section 3). Every call is one transaction; every state change names the
/// state it expects, so a repeat or a second runner changes nothing.
extension Store {
    /// The pipeline the finalize runner writes into `note_finalize.pipelineVersion`.
    public static let finalizePipelineVersion = 1

    /// Inserts a new journal row (an open audio segment or a gap). Nil when the note is gone.
    @discardableResult
    public func insertSegment(_ segment: CaptureSegment) throws -> CaptureSegment? {
        try writer.write { db in
            guard try Note.exists(db, key: segment.noteId) else { return nil }
            var row = segment
            row.id = nil
            try row.insert(db)
            return row
        }
    }

    /// An open segment's running length, after a frame is synced. Only while it is still open.
    public func updateOpenSegment(id: Int64, duration: Double, sampleCount: Int, now: Date = Date()) throws {
        try writer.write { db in
            try db.execute(
                sql: "UPDATE capture_segment SET duration = ?, sampleCount = ?, updatedAt = ? WHERE id = ? AND state = 'open'",
                arguments: [duration, sampleCount, now, id])
        }
    }

    /// Open to sealed, with the file's final length and hash. Returns whether this call sealed it.
    @discardableResult
    public func sealSegment(
        id: Int64, duration: Double, sampleCount: Int, sha256: String?, speechRatio: Double?, peak: Double?,
        now: Date = Date()
    ) throws -> Bool {
        try writer.write { db in
            try db.execute(sql: """
                UPDATE capture_segment SET state = 'sealed', duration = ?, sampleCount = ?, sha256 = ?, speechRatio = ?,
                    peak = ?, updatedAt = ?
                WHERE id = ? AND state = 'open'
                """, arguments: [duration, sampleCount, sha256, speechRatio, peak, now, id])
            return db.changesCount == 1
        }
    }

    /// An open row whose file never reached the disk becomes a gap of its length ('interrupted').
    public func convertOpenSegmentToGap(id: Int64, reason: CaptureSegment.GapReason, now: Date = Date()) throws {
        try writer.write { db in
            try db.execute(sql: """
                UPDATE capture_segment SET kind = 'gap', file = NULL, format = NULL, state = 'transcribed', gapReason = ?,
                    updatedAt = ?
                WHERE id = ? AND state = 'open'
                """, arguments: [reason.rawValue, now, id])
        }
    }

    /// Removes an open row that holds no samples (a segment opened just before the stop).
    public func deleteEmptyOpenSegment(id: Int64) throws {
        try writer.write { db in
            try db.execute(sql: "DELETE FROM capture_segment WHERE id = ? AND state = 'open'", arguments: [id])
        }
    }

    /// A sealed segment recognised with no turn: silence (`gapReason = silence`), or speech that gave no words.
    @discardableResult
    public func markSegmentTranscribed(id: Int64, gapReason: CaptureSegment.GapReason?, speechRatio: Double? = nil,
                                       now: Date = Date()) throws -> Bool {
        try writer.write { db in
            try db.execute(sql: """
                UPDATE capture_segment SET state = 'transcribed', gapReason = ?, speechRatio = coalesce(?, speechRatio),
                    updatedAt = ?
                WHERE id = ? AND state = 'sealed'
                """, arguments: [gapReason?.rawValue, speechRatio, now, id])
            return db.changesCount == 1
        }
    }

    /// One failed recognition of a sealed segment. At `maxAttempts` the segment is `failed`: shown as a gap, and the
    /// note goes on. Returns the segment's state after the call.
    @discardableResult
    public func recordSegmentFailure(id: Int64, errorCode: String, maxAttempts: Int = 3, now: Date = Date()) throws
        -> CaptureSegment.State? {
        try writer.write { db in
            try db.execute(sql: """
                UPDATE capture_segment SET asrAttempts = asrAttempts + 1, errorCode = ?,
                    state = CASE WHEN asrAttempts + 1 >= ? THEN 'failed' ELSE state END, updatedAt = ?
                WHERE id = ? AND state = 'sealed'
                """, arguments: [errorCode, maxAttempts, now, id])
            return try CaptureSegment.fetchOne(db, key: id)?.state
        }
    }

    /// Try again: every audio segment of the note goes back to `sealed`, its capture turns are removed and the cache
    /// is rewritten, so the runner recognises both sides again from the saved audio.
    public func resetSegmentsForRetranscription(noteId: Int64, now: Date = Date()) throws {
        try writer.write { db in
            try db.execute(sql: """
                UPDATE capture_segment SET state = 'sealed', asrAttempts = 0, errorCode = NULL,
                    gapReason = CASE WHEN gapReason = 'silence' THEN NULL ELSE gapReason END, updatedAt = ?
                WHERE noteId = ? AND kind = 'audio' AND state IN ('transcribed', 'failed')
                """, arguments: [now, noteId])
            try NoteTurn.filter(Column("noteId") == noteId && Column("origin") != NoteTurn.Origin.legacy.rawValue).deleteAll(db)
            try Self.materializeTranscript(db, noteId: noteId)
        }
    }

    /// Puts the note at `step` whatever it was at (Try again, and legacy notes adopted at launch). Nil-safe: does
    /// nothing when the note is gone.
    public func setFinalize(noteId: Int64, step: FinalizeStep, reason: String? = nil, now: Date = Date()) throws {
        try writer.write { db in
            guard try Note.exists(db, key: noteId) else { return }
            try db.execute(sql: """
                INSERT INTO note_finalize (noteId, step, attempts, reason, pipelineVersion, updatedAt)
                VALUES (?, ?, 0, ?, ?, ?)
                ON CONFLICT(noteId) DO UPDATE SET step = excluded.step, attempts = 0, reason = excluded.reason,
                    pipelineVersion = excluded.pipelineVersion, updatedAt = excluded.updatedAt
                """, arguments: [noteId, step, reason, Self.finalizePipelineVersion, now])
        }
    }

    /// One more failed try at the note's current step. Returns the count, or nil when the note has moved on.
    @discardableResult
    public func recordFinalizeAttempt(noteId: Int64, step: FinalizeStep, reason: String, now: Date = Date()) throws -> Int? {
        try writer.write { db in
            try db.execute(sql: """
                UPDATE note_finalize SET attempts = attempts + 1, reason = ?, updatedAt = ? WHERE noteId = ? AND step = ?
                """, arguments: [reason, now, noteId, step])
            guard db.changesCount == 1 else { return nil }
            return try Int.fetchOne(db, sql: "SELECT attempts FROM note_finalize WHERE noteId = ?", arguments: [noteId])
        }
    }

    /// The notes a launch must finish: every journal not at an end, and every note left `recording` or `processing`
    /// by a build without the journal (those get a row at `sealing`). Oldest first.
    public func notesToResume(now: Date = Date()) throws -> [Int64] {
        try writer.write { db in
            let legacy = try Int64.fetchAll(db, sql: """
                SELECT n.id FROM note n LEFT JOIN note_finalize f ON f.noteId = n.id
                WHERE f.noteId IS NULL AND n.status IN (?, ?)
                """, arguments: [Note.Status.recording.rawValue, Note.Status.processing.rawValue])
            for id in legacy {
                try db.execute(sql: """
                    INSERT OR IGNORE INTO note_finalize (noteId, step, attempts, reason, pipelineVersion, updatedAt)
                    VALUES (?, 'sealing', 0, 'legacyResume', ?, ?)
                    """, arguments: [id, Self.finalizePipelineVersion, now])
            }
            return try Int64.fetchAll(db, sql: """
                SELECT f.noteId FROM note_finalize f JOIN note n ON n.id = f.noteId
                WHERE f.step NOT IN ('done', 'needsAttention') ORDER BY n.createdAt, f.noteId
                """)
        }
    }

    /// Sets only the note's status (never its transcript cache). False when the note is gone.
    @discardableResult
    public func setNoteStatus(id: Int64, _ status: Note.Status, now: Date = Date()) throws -> Bool {
        try writer.write { db in
            try db.execute(sql: "UPDATE note SET status = ?, updatedAt = ? WHERE id = ?", arguments: [status.rawValue, now, id])
            return db.changesCount == 1
        }
    }

    /// Sets the note's recorded length (seconds). Only while it is still recording.
    public func setRecordingDuration(id: Int64, seconds: Double) throws {
        try writer.write { db in
            try db.execute(sql: "UPDATE note SET durationSeconds = ? WHERE id = ? AND status = ?",
                           arguments: [seconds, id, Note.Status.recording.rawValue])
        }
    }
}

extension FinalizeStep {
    /// The note status a step shows as: capturing is `recording`, sealing to exporting `processing`, done `ready`,
    /// needsAttention `failed` (with Try again).
    public var noteStatus: Note.Status {
        switch self {
        case .capturing: .recording
        case .sealing, .transcribing, .assembling, .writing, .exporting: .processing
        case .done: .ready
        case .needsAttention: .failed
        }
    }
}

extension CaptureJournal {
    /// Audio rows of one side, in order.
    public func audio(_ stream: CaptureStream) -> [CaptureSegment] {
        segments.filter { $0.stream == stream && $0.kind == .audio }.sorted { $0.seq < $1.seq }
    }

    /// Seconds of audio sealed (or past sealing) across the note's mic or file side.
    public func sealedSeconds(_ stream: CaptureStream) -> Double {
        audio(stream).filter { $0.state != .open }.reduce(0) { $0 + $1.duration }
    }

    public var hasAudioFrames: Bool { segments.contains { $0.kind == .audio && $0.sampleCount > 0 } }
    public var hasOpenRows: Bool { segments.contains { $0.state == .open } }
    public var sealedAudio: [CaptureSegment] {
        segments.filter { $0.kind == .audio && $0.state == .sealed }.sorted { ($0.seq, $0.stream.rawValue) < ($1.seq, $1.stream.rawValue) }
    }
    public var capturesCall: Bool { segments.contains { $0.stream == .system } }
}
