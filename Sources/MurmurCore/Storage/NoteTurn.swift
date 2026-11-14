import Foundation
import GRDB

/// One stretch of speech in a note (migration v28): the source of the transcript. `note.transcript` is a cache that
/// only `Store.replaceTurns` writes, in the same transaction as the turns. A legacy note (from before v28) has one
/// turn with its whole transcript and `origin == .legacy`.
public struct NoteTurn: Codable, Sendable, Equatable, Identifiable, FetchableRecord, MutablePersistableRecord {
    public static let databaseTableName = "turn"

    public enum Stream: String, Codable, Sendable { case mic, system, file, unknown }
    public enum Origin: String, Codable, Sendable {
        case capture
        case imported = "import"
        case legacy
    }

    /// One recognised word, stored as `[w, start, end, conf, flags]`.
    public struct Word: Codable, Sendable, Equatable {
        /// Mic bleed of the other side, kept but not part of `text`.
        public static let echo: UInt8 = 1
        public static let boosted: UInt8 = 2

        public var w: String
        public var start: Double
        public var end: Double
        public var conf: Float
        public var flags: UInt8

        public init(w: String, start: Double, end: Double, conf: Float, flags: UInt8 = 0) {
            self.w = w
            self.start = start
            self.end = end
            self.conf = conf
            self.flags = flags
        }

        public init(from decoder: any Decoder) throws {
            var values = try decoder.unkeyedContainer()
            w = try values.decode(String.self)
            start = try values.decode(Double.self)
            end = try values.decode(Double.self)
            conf = try values.decode(Float.self)
            flags = try values.decode(UInt8.self)
        }

        public func encode(to encoder: any Encoder) throws {
            var values = encoder.unkeyedContainer()
            try values.encode(w)
            try values.encode(start)
            try values.encode(end)
            try values.encode(conf)
            try values.encode(flags)
        }
    }

    public var id: Int64?
    public var noteId: Int64
    public var ordinal: Int
    public var stream: Stream
    public var segmentId: Int64?
    public var speakerId: Int64?
    public var t0: Double?
    /// Nil only for a legacy turn.
    public var t1: Double?
    /// The cleaned display text of the non-echo words.
    public var text: String
    public var words: [Word]?
    public var origin: Origin

    public init(
        id: Int64? = nil, noteId: Int64, ordinal: Int, stream: Stream, segmentId: Int64? = nil, speakerId: Int64? = nil,
        t0: Double?, t1: Double?, text: String, words: [Word]? = nil, origin: Origin
    ) {
        self.id = id
        self.noteId = noteId
        self.ordinal = ordinal
        self.stream = stream
        self.segmentId = segmentId
        self.speakerId = speakerId
        self.t0 = t0
        self.t1 = t1
        self.text = text
        self.words = words
        self.origin = origin
    }

    public mutating func didInsert(_ inserted: InsertionSuccess) { id = inserted.rowID }

    /// The transcript cache for turns whose speakers have no names yet. The store renders with the
    /// speaker rule's names (`Store.transcript(noteId:)`); see `NoteTranscript.rendered` for the format.
    public static func render(_ turns: [NoteTurn]) -> String { NoteTranscript(turns: turns).rendered }

    /// One stream's recognised text for one captured part, as a capture turn (an import's file
    /// stream as an import turn), with its word timings moved to note time. Nil when nothing was said.
    public static func captured(
        stream: Stream, seq: Int, start: Double, duration: Double, text: String, timings: [WordTiming]?
    ) -> NoteTurn? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let words = (timings ?? []).map { Word(w: $0.word, start: $0.start + start, end: $0.end + start, conf: 1) }
        let side: CaptureStream = stream == .system ? .system : stream == .file ? .file : .mic
        return NoteTurn(
            noteId: 0, ordinal: captureOrdinal(seq: seq, stream: side), stream: stream, t0: start, t1: start + duration,
            text: trimmed, words: words.isEmpty ? nil : words, origin: stream == .file ? .imported : .capture)
    }

    /// Whether a part that came back with no words counts as a failed part (notes audit B1): only
    /// when its audio held speech and no other stream could have carried the words. Silence, a pause
    /// or a quiet tail is a gap, never a failure.
    public static func isFailedPart(text: String, otherStreamPresent: Bool, hasSpeech: Bool) -> Bool {
        text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !otherStreamPresent && hasSpeech
    }

    /// A capture turn's ordinal: two per sequence number, mic first, so a segment's turn has one fixed place.
    public static func captureOrdinal(seq: Int, stream: CaptureStream) -> Int {
        seq * 2 + (stream == .system ? 1 : 0)
    }
}

/// A machine guess at a speaker's name (migration v28). The person's own choice stays `note_speaker.displayName`
/// and always wins. Names read from a meeting app's window are `ax` guesses here, never attendee rows.
public struct SpeakerAssignment: Codable, Sendable, Equatable, FetchableRecord, PersistableRecord {
    public static let databaseTableName = "speaker_assignment"

    public enum Source: String, Codable, Sendable { case micChannel, calendar, ax }

    public var speakerId: Int64
    public var noteId: Int64
    /// 1 to 80 code points.
    public var name: String
    public var source: Source
    public var confidence: Double
    /// Into `note_attendee(noteId, ordinal)`; kept by the app, not a foreign key.
    public var attendeeOrdinal: Int?
    public var createdAt: Date

    public init(speakerId: Int64, noteId: Int64, name: String, source: Source, confidence: Double, attendeeOrdinal: Int? = nil, createdAt: Date = Date()) {
        self.speakerId = speakerId
        self.noteId = noteId
        self.name = name
        self.source = source
        self.confidence = confidence
        self.attendeeOrdinal = attendeeOrdinal
        self.createdAt = createdAt
    }
}

extension Store {
    /// The note's turns in order.
    public func turns(noteId: Int64) throws -> [NoteTurn] {
        try writer.read { db in
            try NoteTurn.filter(Column("noteId") == noteId).order(Column("ordinal")).fetchAll(db)
        }
    }

    /// Records a sealed segment's recognised text as its turn, marks the segment transcribed and rewrites the
    /// transcript cache, in one transaction.
    /// A segment that is not `sealed` any more (a repeat, or another runner got there first) is left alone.
    /// Returns whether this call wrote the turn.
    @discardableResult
    public func insertSegmentTurn(
        segmentId: Int64, text: String, words: [NoteTurn.Word]?, speakerId: Int64? = nil, now: Date = Date()
    ) throws -> Bool {
        try writer.write { db in
            guard let segment = try CaptureSegment.fetchOne(db, key: segmentId), segment.state == .sealed else { return false }
            let stream = NoteTurn.Stream(rawValue: segment.stream.rawValue) ?? .unknown
            var turn = NoteTurn(
                noteId: segment.noteId, ordinal: NoteTurn.captureOrdinal(seq: segment.seq, stream: segment.stream),
                stream: stream, segmentId: segmentId, speakerId: speakerId, t0: segment.t0,
                t1: segment.t0 + segment.duration, text: text, words: words, origin: .capture)
            try turn.insert(db)
            try db.execute(
                sql: "UPDATE capture_segment SET state = 'transcribed', updatedAt = ? WHERE id = ?",
                arguments: [now, segmentId])
            try Self.materializeTranscript(db, noteId: segment.noteId)
            return true
        }
    }

    /// Replaces all of a note's turns and rewrites `note.transcript` from them, in one transaction. Ordinals are
    /// renumbered in the given order.
    public func replaceTurns(noteId: Int64, turns: [NoteTurn]) throws {
        try writer.write { db in
            try NoteTurn.filter(Column("noteId") == noteId).deleteAll(db)
            for (ordinal, turn) in turns.enumerated() {
                var row = turn
                row.id = nil
                row.noteId = noteId
                row.ordinal = ordinal
                try row.insert(db)
            }
            try Self.materializeTranscript(db, noteId: noteId)
        }
    }
}
