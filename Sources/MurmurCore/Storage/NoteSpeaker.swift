import Foundation
import GRDB

/// One detected (or user-named) speaker within a single note, per docs/research/speaker-labeling.md
/// §3.1. Scoped to a note by default — `label` ("Speaker 1", "Speaker 2", ...) is stable only
/// within that note's own diarization run, matching the diarizer's own per-note speaker ids.
///
/// `voiceId` is reserved, unpopulated schema for the cross-note speaker memory phase described
/// in the research doc §2.6/Phase 5 (an opt-in, encrypted-at-rest voiceprint library keyed by a
/// future `voice` table) — nothing in this task writes to it, but the column exists now so a
/// later migration doesn't have to alter this table again.
public struct NoteSpeaker: Codable, Sendable, Equatable, Identifiable, Hashable {
    public var id: Int64?
    public var noteId: Int64
    /// Stable per-note label, e.g. "Speaker 1" — derived from the diarizer's own speaker id
    /// ("S1", "S2", ...) at the time segments were saved.
    public var label: String
    /// User-set display name (a rename), nil until the user renames this speaker.
    public var displayName: String?
    /// A confirmed cross-note voice identity (populated by `Store.setSpeakerVoice`, either from
    /// the user picking a voice directly or confirming a `suggestedVoiceId` match). Nil until
    /// confirmed — never set automatically by a similarity match alone.
    public var voiceId: Int64?
    public var createdAt: Date
    /// An *unconfirmed* "Is this Dana?" suggestion from `VoiceMatcher`, nil unless a diarization
    /// pass found a known voice above the similarity threshold and the speaker isn't already
    /// linked to a voice. Never read as an identity by any display/export/summarization path —
    /// only the Speaker UI's suggestion banner reads it, and only to ask the user, never to
    /// assert it. See the v11 migration's doc comment.
    public var suggestedVoiceId: Int64?
    public var suggestedSimilarity: Double?

    public init(
        id: Int64? = nil, noteId: Int64, label: String, displayName: String? = nil,
        voiceId: Int64? = nil, createdAt: Date = Date(),
        suggestedVoiceId: Int64? = nil, suggestedSimilarity: Double? = nil
    ) {
        self.id = id
        self.noteId = noteId
        self.label = label
        self.displayName = displayName
        self.voiceId = voiceId
        self.createdAt = createdAt
        self.suggestedVoiceId = suggestedVoiceId
        self.suggestedSimilarity = suggestedSimilarity
    }

    /// What the UI should show for this speaker: the user's rename if one exists, else the
    /// stable per-note label.
    public var displayLabel: String { displayName?.isEmpty == false ? displayName! : label }
}

extension NoteSpeaker: FetchableRecord, MutablePersistableRecord {
    public static let databaseTableName = "note_speaker"

    public mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }
}
