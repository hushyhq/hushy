import Foundation
import GRDB

/// One push-to-talk utterance.
public struct Dictation: Codable, Sendable, Equatable, Identifiable, Hashable {
    public enum Status: String, Codable, Sendable {
        /// Pasted into the focused app.
        case inserted
        /// No text field was focused; kept for copy / paste-last.
        case notInserted
        /// Cancelled by the user; kept briefly so it can be recovered.
        case cancelled
        /// Transcription or insertion failed.
        case failed
    }

    public var id: Int64?
    public var createdAt: Date
    public var rawText: String
    public var text: String
    public var appBundleID: String?
    public var appName: String?
    public var durationSeconds: Double
    public var wordCount: Int
    public var latencyMs: Int
    /// Number of words changed by cleanup and dictionary (the "fixes made" stat).
    public var fixes: Int
    public var status: Status
    public var audioPath: String?
    /// Whether the user changed the pasted text afterwards (nil = couldn't tell).
    public var editState: EditState?
    /// BCP-47 code of the detected language ("es", "fr", …), or `nil` for English/unknown/rows
    /// created before the "v7-language" migration. See `LanguageDetector`.
    public var language: String?
    /// What the cleanup model did for this dictation, as a content-free code (see
    /// `CleanupOutcomeSummary`). Nil for rows saved before the "v19-cleanup-outcome" migration and
    /// for Verbatim, where no model pass is meant to run.
    public var cleanupOutcome: String?
    /// The kind of app the dictation was made in (`AppCategory.rawValue`), so a History retry plans for the same
    /// kind of app. A category only: never a URL, a window title or page text. Nil for rows saved before the
    /// "v21-dictation-app-category" migration; a retry then falls back to the saved app's bundle ID.
    public var appCategory: String?
    /// Where the time between key release and the text went, in numbers only (see `DictationTimeSplit`). Nil for rows
    /// saved before the "v22-dictation-time-split" migration, which show the total alone.
    public var timeSplit: DictationTimeSplit?

    public enum EditState: String, Codable, Sendable {
        /// Still in the document exactly as typed.
        case kept
        /// Still there, but the user changed it.
        case edited
    }

    public init(
        id: Int64? = nil,
        createdAt: Date = Date(),
        rawText: String,
        text: String,
        appBundleID: String? = nil,
        appName: String? = nil,
        durationSeconds: Double,
        wordCount: Int? = nil,
        latencyMs: Int = 0,
        fixes: Int = 0,
        status: Status = .inserted,
        audioPath: String? = nil,
        language: String? = nil,
        cleanupOutcome: String? = nil,
        appCategory: String? = nil,
        timeSplit: DictationTimeSplit? = nil
    ) {
        self.id = id
        self.createdAt = createdAt
        self.rawText = rawText
        self.text = text
        self.appBundleID = appBundleID
        self.appName = appName
        self.durationSeconds = durationSeconds
        self.wordCount = wordCount ?? TextStats.wordCount(text)
        self.latencyMs = latencyMs
        self.fixes = fixes
        self.status = status
        self.audioPath = audioPath
        self.language = language
        self.cleanupOutcome = cleanupOutcome
        self.appCategory = appCategory
        self.timeSplit = timeSplit
    }

    public var wordsPerMinute: Double {
        guard durationSeconds >= 1 else { return 0 }
        return Double(wordCount) / (durationSeconds / 60)
    }

    /// True for dictations that didn't make it into the document the user was looking at,
    /// so History can surface them for recovery instead of letting them blend in.
    public var needsAttention: Bool {
        switch status {
        case .failed, .notInserted, .cancelled: true
        case .inserted: false
        }
    }
}

/// A longer recording (memo or meeting) with a progressive transcript and summary.
public struct Note: Codable, Sendable, Equatable, Identifiable, Hashable {
    public enum Status: String, Codable, Sendable {
        case recording, processing, ready, failed
    }

    /// Where a note's audio came from: captured live with the microphone, or transcribed from
    /// an imported audio/video file (see `FileTranscriber`). Existing rows (migration v8)
    /// default to `.recording`, which is accurate for every note that predates file import.
    public enum Source: String, Codable, Sendable {
        case recording
        case file
    }

    /// A note is ready only when transcription produced text and every captured chunk and
    /// transcript write completed. This policy is shared with the recorder's failure tests.
    public static func finalizedStatus(
        transcript: String,
        chunkFailed: Bool,
        persistenceFailed: Bool
    ) -> Status {
        guard !transcript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !chunkFailed, !persistenceFailed else { return .failed }
        return .ready
    }

    public var id: Int64?
    public var title: String
    public var createdAt: Date
    public var updatedAt: Date
    public var durationSeconds: Double
    /// The cache of the note's turns (`NoteTranscript.rendered`). Only the store writes it, beside the
    /// turns it is made from; `Store.save` and `Store.update` never do.
    public internal(set) var transcript: String
    public var summary: String
    /// One line per item ("Priya: Send the deck — by Friday"). Check-offs are keyed by index into
    /// this list, so its order and count never change when an item's fields are known too
    /// (`actionItemDetails`).
    public var actionItems: [String] {
        didSet { storedActionItemDetails = ActionItemDetail.aligned(storedActionItemDetails, count: actionItems.count) }
    }
    /// The same items as fields (migration v18). Persisted under the column `actionItemDetails`;
    /// read through `actionItemDetails`, which is where the "same count and order as
    /// `actionItems`" rule is enforced. See `ActionItemDetail.swift`.
    var storedActionItemDetails: [ActionItemDetail]?
    public var status: Status
    public var audioPath: String?
    /// The folder this note is filed under, or `nil` for "Unfiled". References `note_folder.id`
    /// with `ON DELETE SET NULL`, so deleting a folder never deletes its notes.
    public var folderId: Int64?
    /// BCP-47 code of the detected language ("es", "fr", …), or `nil` for English/unknown/notes
    /// created before the "v7-language" migration. See `LanguageDetector`.
    public var language: String?
    /// Live microphone recording vs. an imported file (migration v8-note-source). Defaults to
    /// `.recording` so every pre-existing row keeps its accurate meaning.
    public var source: Source
    /// For `source == .file`, the original file's path at import time (display only — "Show in
    /// Finder" etc.). Not a security-scoped bookmark: see `FileTranscriber`'s doc comment for why
    /// a plain path is sufficient here (the audio itself is copied into app storage in chunks,
    /// exactly like a live recording, so nothing durable depends on the source file surviving).
    public var sourcePath: String?
    /// The video/call app this note was recorded from ("Ask to record when a call starts"), or
    /// `nil` for a manually-started note, an imported file, or any note predating migration
    /// "v10-note-app". See `MeetingApp` and `CallDetectionState`. Purely informational — shown in
    /// the note's meta line ("Today · 32 min · Zoom") — nothing else in the app branches on it.
    public var meetingApp: MeetingApp?

    public init(
        id: Int64? = nil,
        title: String,
        createdAt: Date = Date(),
        updatedAt: Date = Date(),
        durationSeconds: Double = 0,
        transcript: String = "",
        summary: String = "",
        actionItems: [String] = [],
        status: Status = .recording,
        audioPath: String? = nil,
        folderId: Int64? = nil,
        language: String? = nil,
        source: Source = .recording,
        sourcePath: String? = nil,
        meetingApp: MeetingApp? = nil
    ) {
        self.id = id
        self.title = title
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.durationSeconds = durationSeconds
        self.transcript = transcript
        self.summary = summary
        self.actionItems = actionItems
        self.status = status
        self.audioPath = audioPath
        self.language = language
        self.folderId = folderId
        self.source = source
        self.sourcePath = sourcePath
        self.meetingApp = meetingApp
    }

    public var wordCount: Int { TextStats.wordCount(transcript) }

    /// This in-memory copy with the store's transcript cache, for a recorder or importer that just
    /// wrote turns (`Store.appendTurns`). Writes nothing.
    public func caching(_ transcript: NoteTranscript) -> Note {
        var copy = self
        copy.transcript = transcript.rendered
        return copy
    }

    private enum CodingKeys: String, CodingKey {
        case id, title, createdAt, updatedAt, durationSeconds, transcript, summary, actionItems
        case storedActionItemDetails = "actionItemDetails"
        case status, audioPath, folderId, language, source, sourcePath, meetingApp
    }
}

/// A user-created folder for organizing notes. Names are unique case-insensitively (enforced
/// both by the `COLLATE NOCASE UNIQUE` column and, redundantly, by `Store.createFolder` so the
/// error is a clear, catchable one instead of a raw SQLite constraint failure).
public struct NoteFolder: Codable, Sendable, Equatable, Identifiable, Hashable {
    public var id: Int64?
    public var name: String
    public var createdAt: Date

    public init(id: Int64? = nil, name: String, createdAt: Date = Date()) {
        self.id = id
        self.name = name
        self.createdAt = createdAt
    }
}

// MARK: - GRDB conformances

extension Dictation: FetchableRecord, MutablePersistableRecord {
    public static let databaseTableName = "dictation"

    public mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }
}

extension Note: FetchableRecord, MutablePersistableRecord {
    public static let databaseTableName = "note"

    /// Updates every column but the transcript cache, which only the turns' materializer writes.
    func updateBesideTranscript(_ db: Database) throws {
        let columns = try db.columns(in: Self.databaseTableName).map(\.name).filter { $0 != "id" && $0 != "transcript" }
        try update(db, columns: columns)
    }

    public mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }
}

extension NoteFolder: FetchableRecord, MutablePersistableRecord {
    public static let databaseTableName = "note_folder"

    public mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }
}

extension DictionaryEntry: FetchableRecord, MutablePersistableRecord {
    public static let databaseTableName = "dictionaryEntry"

    public mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }
}

extension Snippet: FetchableRecord, MutablePersistableRecord {
    public static let databaseTableName = "snippet"

    public mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }
}

public enum TextStats {
    public static func wordCount(_ text: String) -> Int {
        var count = 0
        text.enumerateSubstrings(in: text.startIndex..., options: [.byWords, .substringNotRequired]) { _, _, _, _ in
            count += 1
        }
        return count
    }

    /// Words that differ between two texts, as a rough "fixes made" measure.
    public static func changedWords(from raw: String, to cleaned: String) -> Int {
        let rawWords = words(raw)
        let cleanWords = words(cleaned)
        let diff = cleanWords.difference(from: rawWords)
        return max(diff.insertions.count, diff.removals.count)
    }

    private static func words(_ text: String) -> [String] {
        text.lowercased().components(separatedBy: CharacterSet.alphanumerics.inverted).filter { !$0.isEmpty }
    }
}
