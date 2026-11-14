import Foundation
import GRDB

/// One contiguous speaker turn within a note's transcript, per docs/research/speaker-labeling.md
/// §3.1 — the persisted form of `AlignedSegment` (see `SpeakerAlignment.swift`). `speakerId` is
/// `ON DELETE SET NULL` (not cascade) so merging/deleting a `NoteSpeaker` row never has to also
/// rewrite every segment that referenced it; a null `speakerId` means "unattributed" rather than
/// deleting the transcript text.
public struct NoteSegment: Codable, Sendable, Equatable, Identifiable, Hashable {
    public var id: Int64?
    public var noteId: Int64
    public var speakerId: Int64?
    /// Note-relative seconds (from the start of the recording), matching `WordTiming`.
    public var startTime: Double
    public var endTime: Double
    public var text: String
    /// Position within the note's speaker-turn sequence, so segments render/query in order
    /// without relying on `startTime` ordering surviving a future edit (e.g. a manual split).
    public var ordinal: Int

    public init(
        id: Int64? = nil, noteId: Int64, speakerId: Int64?, startTime: Double, endTime: Double,
        text: String, ordinal: Int
    ) {
        self.id = id
        self.noteId = noteId
        self.speakerId = speakerId
        self.startTime = startTime
        self.endTime = endTime
        self.text = text
        self.ordinal = ordinal
    }
}

extension NoteSegment: FetchableRecord, MutablePersistableRecord {
    public static let databaseTableName = "note_segment"

    public mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }
}

/// A `NoteSegment` joined with its `NoteSpeaker`, for rendering — see `Store.noteSegments(noteId:)`.
public struct NoteSegmentWithSpeaker: Sendable, Equatable, Identifiable {
    public var id: Int64? { segment.id }
    public let segment: NoteSegment
    public let speaker: NoteSpeaker?

    public init(segment: NoteSegment, speaker: NoteSpeaker?) {
        self.segment = segment
        self.speaker = speaker
    }
}
