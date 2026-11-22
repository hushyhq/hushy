import Foundation
import GRDB

/// Local SQLite store for dictations, notes, dictionary and snippets.
///
/// Backed by a WAL `DatabasePool`, so the app can write while the MCP server reads.
public final class Store: Sendable {
    public let writer: any DatabaseWriter
    /// The file behind the store; nil for an in-memory one.
    let databaseURL: URL?
    static let busyTimeoutSeconds: TimeInterval = 3

    /// Opens (and migrates) the store at `url`. `preMigrationBackup` is false while data encryption is on: the
    /// pre-v26 copy would be one more unencrypted file of the person's text (see `PreMeetingsBackup`).
    public init(url: URL, preMigrationBackup: Bool = true) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        var config = Configuration()
        config.foreignKeysEnabled = true
        // A second process still closing the file, or a checkpoint, holds the lock for a moment.
        // Wait for it instead of failing the open at once.
        config.busyMode = .timeout(Self.busyTimeoutSeconds)
        // Deleted/expired rows (retention sweeps, "Clear history") are overwritten instead of
        // just unlinked from the B-tree, so their bytes don't linger recoverable in the file
        // until something else happens to reuse that page.
        config.prepareDatabase { db in
            try db.execute(sql: "PRAGMA secure_delete = ON")
        }
        let pool = try DatabasePool(path: url.path, configuration: config)
        writer = pool
        databaseURL = url
        if preMigrationBackup { PreMeetingsBackup.writeIfNeeded(pool, storeURL: url) }
        try Self.migrator.migrate(writer)
        PreMeetingsBackup.discardIfVerified(pool, migrator: Self.migrator, storeURL: url)
        PreMeetingsBackup.removeIfExpired(storeURL: url)
    }

    /// Every erase the person asks for ends here: a pre-v26 copy left by a failed upgrade would otherwise keep what
    /// they deleted.
    func discardPreMeetingsBackup() {
        if let databaseURL { PreMeetingsBackup.remove(next: databaseURL) }
    }

    /// In-memory store for tests and previews.
    public init() throws {
        var config = Configuration()
        config.foreignKeysEnabled = true
        writer = try DatabaseQueue(configuration: config)
        databaseURL = nil
        try Self.migrator.migrate(writer)
    }

    /// Read-only access for out-of-process readers such as the MCP server.
    public static func openReadOnly(url: URL) throws -> any DatabaseReader {
        var config = Configuration()
        config.readonly = true
        return try DatabasePool(path: url.path, configuration: config)
    }

    static var migrator: DatabaseMigrator {
        var migrator = DatabaseMigrator()
        migrator.registerMigration("v1") { db in
            try db.create(table: "dictation") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("createdAt", .datetime).notNull().indexed()
                t.column("rawText", .text).notNull()
                t.column("text", .text).notNull()
                t.column("appBundleID", .text)
                t.column("appName", .text)
                t.column("durationSeconds", .double).notNull()
                t.column("wordCount", .integer).notNull()
                t.column("latencyMs", .integer).notNull()
                t.column("fixes", .integer).notNull().defaults(to: 0)
                t.column("status", .text).notNull()
                t.column("audioPath", .text)
            }
            try db.create(virtualTable: "dictation_fts", using: FTS5()) { t in
                t.synchronize(withTable: "dictation")
                t.tokenizer = .porter(wrapping: .unicode61())
                t.column("text")
            }
            try db.create(table: "note") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("title", .text).notNull()
                t.column("createdAt", .datetime).notNull().indexed()
                t.column("updatedAt", .datetime).notNull()
                t.column("durationSeconds", .double).notNull()
                t.column("transcript", .text).notNull()
                t.column("summary", .text).notNull()
                t.column("actionItems", .jsonText).notNull()
                t.column("status", .text).notNull()
                t.column("audioPath", .text)
            }
            try db.create(virtualTable: "note_fts", using: FTS5()) { t in
                t.synchronize(withTable: "note")
                t.tokenizer = .porter(wrapping: .unicode61())
                t.column("title")
                t.column("transcript")
                t.column("summary")
            }
            try db.create(table: "dictionaryEntry") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("term", .text).notNull().unique(onConflict: .replace)
                t.column("soundsLike", .jsonText).notNull()
                t.column("createdAt", .datetime).notNull()
            }
            try db.create(table: "snippet") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("trigger", .text).notNull().unique(onConflict: .replace)
                t.column("expansion", .text).notNull()
                t.column("createdAt", .datetime).notNull()
            }
        }
        migrator.registerMigration("v2-edit-state") { db in
            try db.alter(table: "dictation") { t in
                t.add(column: "editState", .text)
            }
        }
        migrator.registerMigration("v3-history-indexes") { db in
            // Speeds up the History tab's keyset pagination and filters: recency ordering,
            // needs-attention (status) filtering, and per-app filtering, all newest-first.
            try db.create(index: "dictation_on_createdAt", on: "dictation", columns: ["createdAt"], ifNotExists: true)
            try db.create(
                index: "dictation_on_status_createdAt", on: "dictation",
                columns: ["status", "createdAt"], ifNotExists: true)
            try db.create(
                index: "dictation_on_appBundleID_createdAt", on: "dictation",
                columns: ["appBundleID", "createdAt"], ifNotExists: true)
        }
        migrator.registerMigration("v4-note-action-item-status") { db in
            // Persists checkbox completion for a note's action items (Home's "Open action
            // items" card and the Notes detail page). Addressed by (noteId, itemIndex) rather
            // than duplicating the item text — see NoteActionItemStatus's doc comment. Only
            // "done" rows are stored; a missing row means "not done".
            try db.create(table: "noteActionItem") { t in
                t.column("noteId", .integer).notNull().indexed()
                    .references("note", onDelete: .cascade)
                t.column("itemIndex", .integer).notNull()
                t.column("isDone", .boolean).notNull().defaults(to: false)
                t.column("updatedAt", .datetime).notNull()
                t.primaryKey(["noteId", "itemIndex"])
            }
        }
        // Appended at the end so a concurrently-developed migration (e.g. "v4-…") can land
        // before this one without conflict — each migration is additive and self-contained.
        migrator.registerMigration("v5-note-folders") { db in
            try db.create(table: "note_folder") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("name", .text).notNull().unique(onConflict: .abort).collate(.nocase)
                t.column("createdAt", .datetime).notNull()
            }
            try db.alter(table: "note") { t in
                t.add(column: "folderId", .integer)
                    .indexed()
                    .references("note_folder", onDelete: .setNull)
            }
        }
        // Appended last, per the same "each migration is additive and self-contained" rule as
        // v5 above. See docs/research/speaker-labeling.md §3.1 for the design rationale (why
        // `voiceId` exists unused, why segments store their own `speakerId` rather than being
        // implicitly grouped, why `speakerId` is SET NULL not CASCADE).
        migrator.registerMigration("v6-note-speakers") { db in
            try db.create(table: "note_speaker") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("noteId", .integer).notNull().indexed()
                    .references("note", onDelete: .cascade)
                t.column("label", .text).notNull()
                t.column("displayName", .text)
                // Reserved for a future persistent voice identity (cross-note speaker memory,
                // Phase 5 of the research doc) — no `voice` table exists yet, so this is a plain
                // nullable integer with no foreign key for now, populated by nothing in this
                // migration or any code that ships with it.
                t.column("voiceId", .integer)
                t.column("createdAt", .datetime).notNull()
            }
            try db.create(table: "note_segment") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("noteId", .integer).notNull().indexed()
                    .references("note", onDelete: .cascade)
                t.column("speakerId", .integer).indexed()
                    .references("note_speaker", onDelete: .setNull)
                t.column("startTime", .double).notNull()
                t.column("endTime", .double).notNull()
                t.column("text", .text).notNull()
                t.column("ordinal", .integer).notNull()
            }
            try db.create(
                index: "note_segment_on_noteId_ordinal", on: "note_segment",
                columns: ["noteId", "ordinal"], ifNotExists: true)
        }
        // Multi-language dictation: BCP-47 code (e.g. "es", "fr") detected from the cleaned
        // transcript by `LanguageDetector` (NLLanguageRecognizer), or nil when English/unknown/
        // not yet detected (existing rows before this migration, and any row where detection
        // confidence was too low). Add-only, appended last per the convention above — nothing
        // reads `language` until this migration has run, and no existing column is touched.
        migrator.registerMigration("v7-language") { db in
            try db.alter(table: "dictation") { t in
                t.add(column: "language", .text)
            }
            try db.alter(table: "note") { t in
                t.add(column: "language", .text)
            }
        }
        // Appended last, per the same convention. Imported-file support only needs to record
        // *where* a note's audio came from — the word/segment timings themselves are stored in
        // the existing `note_segment` table from v6 (with `speakerId` left nil for an imported
        // file, since it has no diarization run), so this migration adds no new segment table.
        // See `FileTranscriber` and .claude/DECISIONS.md for the storage-choice rationale.
        migrator.registerMigration("v8-note-source") { db in
            try db.alter(table: "note") { t in
                // Every existing row is a live recording; `.recording` is the correct default,
                // not a placeholder — see `Note.Source`'s doc comment.
                t.add(column: "source", .text).notNull().defaults(to: Note.Source.recording.rawValue)
                t.add(column: "sourcePath", .text)
            }
        }
        // Voice actions (docs/research/voice-actions.md): a record of each confirmed action
        // (Calendar event, Reminder, Shortcut run) so History can show it with an action badge.
        // Appended last per the existing convention, after "v8-note-source" landed first from a
        // concurrently-developed worktree.
        migrator.registerMigration("v9-actions") { db in
            try db.create(table: "actionRecord") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("createdAt", .datetime).notNull().indexed()
                t.column("kind", .text).notNull()
                t.column("title", .text).notNull()
                t.column("detail", .text)
                t.column("sourceText", .text).notNull()
                t.column("status", .text).notNull()
                t.column("undoBackendID", .text)
                t.column("dictationID", .integer).indexed()
                    .references("dictation", onDelete: .setNull)
            }
            try db.create(
                index: "actionRecord_on_createdAt", on: "actionRecord", columns: ["createdAt"], ifNotExists: true)
        }
        // Call detection ("Ask to record when a call starts," see `CallDetectionState` and
        // `CallDetector`): records which meeting app a note was captured from, purely for
        // display in the note's meta line ("Today · 32 min · Zoom"). Nullable and add-only —
        // every existing row and every manually-started or imported note simply has no value.
        // Appended last, after "v9-actions" landed first from a concurrently-developed worktree
        // — the gap this task asked to leave for v9 turned out to already be filled by the time
        // of this merge, so v10 is used here instead.
        migrator.registerMigration("v10-note-app") { db in
            try db.alter(table: "note") { t in
                t.add(column: "meetingApp", .text)
            }
        }
        // Appended last, deliberately leaving a gap after v8 (no v9/v10 in this codebase at the
        // time this was written) rather than renumbering — per the same "each migration is
        // additive, self-contained, and appended at the end" convention as v5/v6/v7/v8 above. By
        // the time this merged, v9/v10 above had already landed from concurrent worktrees, which
        // is exactly the scenario the gap was left for — this migration lands at v11 instead of
        // colliding. See docs/research/speaker-labeling.md and .claude/DECISIONS.md's biometric
        // consent/deletion entry for the design rationale: one `voice` row per named signature,
        // embedding stored pre-encrypted by the caller (`VoiceSignatureStore`) — this table never
        // sees a plaintext embedding, only the ciphertext `Store` persists as an opaque BLOB.
        migrator.registerMigration("v11-voices") { db in
            try db.create(table: "voice") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("name", .text).notNull()
                t.column("isYou", .boolean).notNull().defaults(to: false)
                t.column("encryptedEmbedding", .blob).notNull()
                t.column("sampleCount", .integer).notNull().defaults(to: 1)
                t.column("createdAt", .datetime).notNull()
                t.column("updatedAt", .datetime).notNull()
            }
            // `note_speaker.voiceId` was reserved-but-unpopulated since v6; this is the migration
            // that finally gives it something to reference. SET NULL (not cascade): deleting a
            // voice should un-link a note's speaker attribution, never delete the note's
            // transcript segments — the same "don't fan out a delete into transcript loss"
            // principle v6 already applied to `note_segment.speakerId`.
            //
            // SQLite's `ALTER TABLE ... ADD COLUMN ... REFERENCES` cannot retrofit a foreign key
            // onto an existing column, so `note_speaker.voiceId` (already a plain nullable
            // integer since v6) is left as-is; the FK relationship is enforced at the
            // application layer (`Store.setSpeakerVoice`/`deleteVoice`), which is already the
            // pattern `mergeSpeakers`/`renameSpeaker` established for that table.
            try db.create(
                index: "note_speaker_on_voiceId", on: "note_speaker", columns: ["voiceId"], ifNotExists: true)

            // A *suggested* (unconfirmed) voice match — "Is this Dana?" — kept separate from the
            // real `voiceId` link so a suggestion can never silently read as a confirmed
            // identity. `suggestedVoiceId` is nil once the user confirms (it becomes `voiceId`)
            // or dismisses the suggestion (`Store.dismissSpeakerVoiceSuggestion` clears both
            // columns without setting `voiceId`). Per this task's "never auto-name without a
            // confirmed match" requirement, nothing ever reads `suggestedVoiceId` as if it were
            // `voiceId` — every read path that names a speaker uses `displayName`/`voiceId` only.
            try db.alter(table: "note_speaker") { t in
                t.add(column: "suggestedVoiceId", .integer)
                t.add(column: "suggestedSimilarity", .double)
            }
        }
        // Saved Assistant chats (history, VS Code style): add-only, appended after v11. Plain
        // text rows like dictations; see `AssistantChat` and `.claude/DECISIONS.md`.
        migrator.registerMigration("v12-assistant-chats") { db in
            try AssistantChatSchema.migrate(db)
        }
        migrator.registerMigration("v13-entitlements") { db in
            // Key/value snapshot the app writes for out-of-process readers (the MCP helper),
            // see `Store.writeProSnapshot(activeUntil:)`. Never a source of truth in-app.
            try db.create(table: "entitlement") { t in
                t.primaryKey("key", .text)
                t.column("value", .text).notNull()
            }
        }
        // Learn-from-corrections: short learned terms/style signals with provenance, never field
        // contents. Add-only; see `LearnedItem` and `.claude/DECISIONS.md` (2026-09-27).
        migrator.registerMigration("v14-learned-items") { db in
            try LearnedItemSchema.migrate(db)
        }
        // The Free plan's monthly voice-action count (`VoiceActionQuota`): one row per chord use
        // that did something, given back by Undo. See `VoiceActionUse`.
        migrator.registerMigration("v15-voice-action-uses") { db in
            try VoiceActionUse.migrate(db)
        }
        // Content-free edit observation coverage. One row per saved dictation is updated by
        // EditWatcher; deleting a dictation cascades so delayed callbacks cannot leave orphans.
        migrator.registerMigration("v16-dictation-edit-observations") { db in
            try DictationEditObservationSchema.migrate(db)
        }
        // The calendar meeting a note was started from, plus its attendee names as speaker-naming
        // suggestions (task 84). Add-only; both tables cascade with the note. See `NoteCalendarLink`.
        migrator.registerMigration("v17-note-calendar") { db in
            try NoteCalendarSchema.migrate(db)
        }
        // Action items as fields (owner, task, due) next to the one-line strings (task 94).
        // Nullable and add-only: every existing note has none and reads exactly as before.
        // `actionItems` stays as it is, because check-offs address an item by its index.
        migrator.registerMigration("v18-action-item-details") { db in
            try db.alter(table: "note") { t in
                t.add(column: "actionItemDetails", .jsonText)
            }
        }
        // What the cleanup model did for each dictation, as a content-free code (task 110). Nullable and
        // add-only: older rows read as before and the History line simply is not shown for them.
        migrator.registerMigration("v19-cleanup-outcome") { db in
            try db.alter(table: "dictation") { t in
                t.add(column: "cleanupOutcome", .text)
            }
        }
        // A voice action's Undo that was tried and failed (the event or reminder is still there).
        // Nullable and add-only: every existing action reads exactly as before. Failed and
        // uncertain actions need no column; `status` is text and already holds them.
        migrator.registerMigration("v20-action-undo-failed") { db in
            try db.alter(table: "actionRecord") { t in
                t.add(column: "undoFailedAt", .datetime)
            }
        }
        // The kind of app a dictation was made in, so a History retry plans for the same kind of app (a Gmail tab is
        // email, not the browser's "other"). A category name only. Nullable and add-only.
        migrator.registerMigration("v21-dictation-app-category") { db in
            try db.alter(table: "dictation") { t in
                t.add(column: "appCategory", .text)
            }
        }
        // Where a dictation's time went (recognition, cleanup, second pass, typing), as numbers only, so History can
        // explain a slow one. Nullable and add-only: older rows have none and show the total alone.
        migrator.registerMigration("v22-dictation-time-split") { db in
            try db.alter(table: "dictation") { t in
                t.add(column: "timeSplit", .jsonText)
            }
        }
        migrator.registerMigration("v23-keep-heard") { db in try Store.migrateKeepHeard(db) }
        migrator.registerMigration("v24-learned-term-review") { db in try Store.migrateLearnedTermReview(db) }
        migrator.registerMigration("v25-learned-evidence") { db in try LearnedItemSchema.migrateEvidence(db) }
        // v26–v29: the frozen meetings schema. v26-attendees merges the preview identifiers.
        MeetingsSchema.register(in: &migrator)
        return migrator
    }
}

// MARK: - Dictations

extension Store {
    @discardableResult
    public func save(_ dictation: Dictation) throws -> Dictation {
        try writer.write { db in
            var copy = dictation
            try copy.save(db)
            if let id = copy.id {
                try db.execute(
                    sql: "INSERT OR IGNORE INTO dictation_edit_observation (dictationID, generation, verdict, coverage) VALUES (?, ?, 'unknown', 'notAttempted')",
                    arguments: [id, UUID().uuidString])
            }
            return copy
        }
    }

    public func deleteDictation(id: Int64) throws {
        discardPreMeetingsBackup()
        _ = try writer.write { db in try Dictation.deleteOne(db, key: id) }
    }

    /// Deletes several dictations in one transaction and returns the audio file paths the
    /// caller should remove from disk. All-or-nothing: if any delete fails, none are applied.
    @discardableResult
    public func deleteDictations(ids: [Int64]) throws -> [String] {
        discardPreMeetingsBackup()
        return try writer.write { db in
            var removedAudio: [String] = []
            for id in ids {
                if let existing = try Dictation.fetchOne(db, key: id) {
                    if let path = existing.audioPath { removedAudio.append(path) }
                    try Dictation.deleteOne(db, key: id)
                }
            }
            return removedAudio
        }
    }

    /// Erases every dictation and every voice-action record (their `sourceText` is the spoken
    /// request), in one transaction, and returns the audio paths of all the dictations so the
    /// caller can remove the files. The Free plan's usage counter is kept: it holds no words.
    @discardableResult
    public func deleteAllDictations() throws -> [String] {
        discardPreMeetingsBackup()
        return try writer.write { db in
            let paths = try String.fetchAll(db, sql: "SELECT audioPath FROM dictation WHERE audioPath IS NOT NULL")
            _ = try Dictation.deleteAll(db)
            _ = try ActionRecord.deleteAll(db)
            return paths
        }
    }

    /// Empties the write-ahead log into the database file and truncates it, so text that was just
    /// deleted does not linger in `-wal`. A no-op for an in-memory store.
    public func truncateWAL() throws {
        discardPreMeetingsBackup()
        try writer.writeWithoutTransaction { db in try db.checkpoint(.truncate) }
    }

    public func recentDictations(limit: Int = 200) throws -> [Dictation] {
        try writer.read { db in try Self.recentDictations(db, limit: limit) }
    }

    /// A paste that was sent and then read back as not in the field: the row stops saying it was inserted, so History
    /// lists it as not pasted. Only an inserted row changes; one the person already dealt with is left as it is.
    public func markUnlandedPaste(id: Int64) throws {
        try writer.write { db in
            try db.execute(
                sql: "UPDATE dictation SET status = ? WHERE id = ? AND status = ?",
                arguments: [Dictation.Status.notInserted.rawValue, id, Dictation.Status.inserted.rawValue])
        }
    }

    public func setEditState(_ state: Dictation.EditState, forDictation id: Int64) throws {
        try writer.write { db in
            try db.execute(sql: "UPDATE dictation SET editState = ? WHERE id = ?", arguments: [state.rawValue, id])
        }
    }

    /// Overwrites the transcript and status of a dictation after a retry (re-running speech
    /// and cleanup on the saved audio). Word count and fixes are recomputed to match, and so is the
    /// cleanup outcome: the old code described the old text, so it is replaced (or cleared when nil).
    public func updateTranscription(
        id: Int64, rawText: String, text: String, status: Dictation.Status, cleanupOutcome: String? = nil
    ) throws {
        try writer.write { db in
            try db.execute(
                sql: """
                    UPDATE dictation
                    SET rawText = ?, text = ?, status = ?, wordCount = ?, fixes = ?, cleanupOutcome = ?
                    WHERE id = ?
                    """,
                arguments: [
                    rawText, text, status.rawValue, TextStats.wordCount(text),
                    TextStats.changedWords(from: rawText, to: text), cleanupOutcome, id,
                ])
            // A retranscription is not a new observed paste. Retire prior field observations.
            try db.execute(sql: "UPDATE dictation SET editState = NULL WHERE id = ?", arguments: [id])
            try db.execute(sql: "UPDATE dictation_edit_observation SET generation = ?, verdict = 'unknown', coverage = 'notAttempted' WHERE dictationID = ?", arguments: [UUID().uuidString, id])
        }
    }

    public func lastDictation() throws -> Dictation? {
        try writer.read { db in
            try Dictation.filter(Column("status") != Dictation.Status.cancelled.rawValue)
                .filter(Column("text") != "")
                .order(Column("createdAt").desc).fetchOne(db)
        }
    }

    public func allDictations(since date: Date? = nil) throws -> [Dictation] {
        try writer.read { db in
            var request = Dictation.all()
            if let date { request = request.filter(Column("createdAt") >= date) }
            return try request.order(Column("createdAt")).fetchAll(db)
        }
    }

    public func searchDictations(_ query: String, limit: Int = 100) throws -> [Dictation] {
        try writer.read { db in try Self.searchDictations(db, query: query, limit: limit) }
    }

    /// How many dictations (and saved recordings) a retention change would delete, so the UI
    /// can confirm before anything is removed.
    public func retentionImpact(audioDays: Int?, textDays: Int?, now: Date = Date()) throws -> (dictations: Int, recordings: Int) {
        try writer.read { db in
            let textCount = try textDays.map {
                try Dictation.filter(Column("createdAt") < now.addingTimeInterval(-Double($0) * 86_400)).fetchCount(db)
            } ?? 0
            let audioCount = try audioDays.map {
                try Dictation.filter(Column("audioPath") != nil && Column("createdAt") < now.addingTimeInterval(-Double($0) * 86_400)).fetchCount(db)
            } ?? 0
            return (textCount, audioCount)
        }
    }

    /// How long a cancelled take stays in History before the sweep drops it.
    public static let cancelledTakeLifetime: TimeInterval = 24 * 3600

    /// The most cancelled takes History keeps at once, and the most recorded audio they may hold
    /// between them. The newest take is always kept, whatever its length, so one long take is
    /// never dropped by its own size.
    public struct CancelledTakeLimits: Sendable, Equatable {
        public var takes: Int
        public var audioSeconds: Double
        public init(takes: Int, audioSeconds: Double) {
            self.takes = takes
            self.audioSeconds = audioSeconds
        }
    }

    /// 20 takes and one hour of audio (about 115 MB as 16-bit mono at 16 kHz).
    public static let cancelledTakeLimits = CancelledTakeLimits(takes: 20, audioSeconds: 3600)

    /// Drops the oldest cancelled takes past `limits` and returns the audio files to delete.
    public func trimCancelledTakes(keeping limits: CancelledTakeLimits = Store.cancelledTakeLimits) throws -> [String] {
        try writer.write { db in try Self.trimCancelled(db, keeping: limits) }
    }

    private static func trimCancelled(_ db: Database, keeping limits: CancelledTakeLimits) throws -> [String] {
        let newestFirst = try Dictation
            .filter(Column("status") == Dictation.Status.cancelled.rawValue)
            .order(Column("createdAt").desc, Column("id").desc)
            .fetchAll(db)
        var kept = 0
        var keptSeconds = 0.0
        var doomed: [Dictation] = []
        for take in newestFirst {
            let seconds = take.audioPath == nil ? 0 : take.durationSeconds
            let fits = kept < limits.takes && (kept == 0 || keptSeconds + seconds <= limits.audioSeconds)
            if fits {
                kept += 1
                keptSeconds += seconds
            } else {
                doomed.append(take)
            }
        }
        let ids = doomed.compactMap(\.id)
        guard !ids.isEmpty else { return [] }
        try Dictation.filter(ids.contains(Column("id"))).deleteAll(db)
        return doomed.compactMap(\.audioPath)
    }

    /// Drops cancelled items older than `cancelledTakeLifetime` or past `cancelledTakeLimits`, and detaches
    /// audio older than `audioDays`. Returns the audio file paths the caller should delete from disk.
    public func applyRetention(audioDays: Int?, textDays: Int? = nil, now: Date = Date()) throws -> [String] {
        discardPreMeetingsBackup()
        return try writer.write { db in
            var removedAudio: [String] = []
            // Dictation text older than `textDays` is deleted with its audio (nil keeps it forever).
            // Notes are never touched here.
            if let textDays {
                let textCutoff = now.addingTimeInterval(-Double(textDays) * 24 * 3600)
                let old = Dictation.filter(Column("createdAt") < textCutoff)
                removedAudio += try old.fetchAll(db).compactMap(\.audioPath)
                try old.deleteAll(db)
                // A voice action keeps the words that were spoken, so it expires with the text.
                try ActionRecord.filter(Column("createdAt") < textCutoff).deleteAll(db)
            }
            let dayCutoff = now.addingTimeInterval(-Self.cancelledTakeLifetime)
            let cancelled = try Dictation
                .filter(Column("status") == Dictation.Status.cancelled.rawValue && Column("createdAt") < dayCutoff)
                .fetchAll(db)
            removedAudio += cancelled.compactMap(\.audioPath)
            try Dictation
                .filter(Column("status") == Dictation.Status.cancelled.rawValue && Column("createdAt") < dayCutoff)
                .deleteAll(db)

            removedAudio += try Self.trimCancelled(db, keeping: Self.cancelledTakeLimits)

            // nil keeps audio forever; 0 keeps none.
            guard let audioDays else { return removedAudio }
            let audioCutoff = now.addingTimeInterval(-Double(audioDays) * 24 * 3600)
            let expired = try Dictation
                .filter(Column("audioPath") != nil && Column("createdAt") < audioCutoff)
                .fetchAll(db)
            for var item in expired {
                if let path = item.audioPath { removedAudio.append(path) }
                item.audioPath = nil
                try item.update(db)
            }
            return removedAudio
        }
    }

    static func recentDictations(_ db: Database, limit: Int) throws -> [Dictation] {
        try Dictation.order(Column("createdAt").desc).limit(limit).fetchAll(db)
    }

    /// Opaque position in the newest-first dictation ordering, for keyset pagination.
    /// Using `(createdAt, id)` rather than an offset means a page fetch is a fast indexed
    /// range scan regardless of how deep into the history it is, and ties on `createdAt`
    /// (bulk imports, fast successive dictations) can't skip or duplicate a row.
    public struct DictationCursor: Sendable, Equatable {
        public let createdAt: Date
        public let id: Int64

        public init(createdAt: Date, id: Int64) {
            self.createdAt = createdAt
            self.id = id
        }
    }

    /// Which dictations a History page should include, applied in SQL so pagination stays a
    /// bounded index scan instead of fetching everything and filtering in Swift.
    public enum DictationPageFilter: Sendable, Equatable {
        case all
        case needsAttention
        case app(String?)
    }

    /// An inclusive-start, exclusive-end local-calendar-day window for History's date filter,
    /// e.g. "Today" or a custom range. `end` is the start of the day *after* the last included
    /// day, so the bound is a plain `createdAt < end` with no off-by-one at midnight. Computing
    /// these edges (via `Calendar`) is the caller's job — `Store` just applies whatever bounds
    /// it's given, in SQL, so the semantics live in one place (`HistoryDateRange`).
    public struct DictationDateRange: Sendable, Equatable {
        public let start: Date
        public let end: Date

        public init(start: Date, end: Date) {
            self.start = start
            self.end = end
        }
    }

    /// One page of dictations, newest first, after `cursor` (exclusive). Pass `cursor: nil`
    /// for the first page. `hasMore` is true when a full page came back and a later row
    /// might still exist, so the caller can decide whether to request another page.
    public func dictationPage(
        after cursor: DictationCursor?, filter: DictationPageFilter = .all,
        dateRange: DictationDateRange? = nil, pageSize: Int = 100
    ) throws -> (items: [Dictation], hasMore: Bool) {
        try writer.read { db in
            try Self.dictationPage(db, after: cursor, filter: filter, dateRange: dateRange, pageSize: pageSize)
        }
    }

    /// Exposed publicly (not just `internal`) so `HistoryPager` in the app target can drive a
    /// `ValueObservation` directly against a `Database`, which `ValueObservation.tracking`
    /// requires — the instance method above can't be called from inside that closure.
    public static func dictationPage(
        _ db: Database, after cursor: DictationCursor?, filter: DictationPageFilter,
        dateRange: DictationDateRange? = nil, pageSize: Int
    ) throws -> (items: [Dictation], hasMore: Bool) {
        var request = Dictation.all()
        switch filter {
        case .all:
            break
        case .needsAttention:
            request = request.filter(Column("status") != Dictation.Status.inserted.rawValue)
        case .app(let bundleID):
            if let bundleID {
                request = request.filter(Column("appBundleID") == bundleID)
            } else {
                request = request.filter(Column("appBundleID") == nil)
            }
        }
        if let dateRange {
            let createdAtCol = Column("createdAt")
            request = request.filter(createdAtCol >= dateRange.start && createdAtCol < dateRange.end)
        }
        if let cursor {
            // (createdAt < cursor) OR (createdAt = cursor AND id < cursor.id), the standard
            // keyset predicate for a composite DESC ordering.
            let createdAtCol = Column("createdAt")
            let idCol = Column("id")
            request = request.filter(
                createdAtCol < cursor.createdAt
                    || (createdAtCol == cursor.createdAt && idCol < cursor.id))
        }
        request = request.order(Column("createdAt").desc, Column("id").desc).limit(pageSize + 1)
        let fetched = try request.fetchAll(db)
        let hasMore = fetched.count > pageSize
        return (Array(fetched.prefix(pageSize)), hasMore)
    }

    /// One app that has dictations, for History's app filter chips: the bundle id, the most
    /// recently recorded display name for it, and how many dictations it has in total.
    public struct AppDictationCount: Sendable, Equatable {
        public let bundleID: String
        public let appName: String?
        public let count: Int

        public init(bundleID: String, appName: String?, count: Int) {
            self.bundleID = bundleID
            self.appName = appName
            self.count = count
        }
    }

    /// Every app with at least one dictation, across the *whole* history (not just whatever
    /// pages History has loaded), most-used first. A single grouped aggregate: cheap even at
    /// tens of thousands of rows. History uses it for which app chips to show and their order.
    public func appDictationCounts() throws -> [AppDictationCount] {
        try writer.read { db in try Self.appDictationCounts(db) }
    }

    static func appDictationCounts(_ db: Database) throws -> [AppDictationCount] {
        // SQLite's bare-column rule: with a single MAX() aggregate, `appName` comes from the
        // row holding that max, i.e. the newest dictation's name for the app.
        let sql = """
            SELECT appBundleID, appName, COUNT(*) AS total, MAX(createdAt) AS newest
            FROM dictation
            WHERE appBundleID IS NOT NULL
            GROUP BY appBundleID
            ORDER BY total DESC, appBundleID ASC
            """
        return try Row.fetchAll(db, sql: sql).map { row in
            AppDictationCount(bundleID: row["appBundleID"], appName: row["appName"], count: row["total"])
        }
    }

    /// Per-local-day dictation and needs-attention counts in `[start, end)`, keyed by
    /// `calendar.startOfDay`, for History's week strip — read straight from the table so the
    /// strip is right regardless of which pages or filters History currently has loaded.
    /// Uses the `createdAt` index; a week is at most a few hundred rows of two columns.
    public func dictationDayActivity(
        start: Date, end: Date, calendar: Calendar = .current
    ) throws -> (entries: [Date: Int], attention: [Date: Int]) {
        try writer.read { db in
            let rows = try Row.fetchAll(
                db, sql: "SELECT createdAt, status FROM dictation WHERE createdAt >= ? AND createdAt < ?",
                arguments: [start, end])
            var entries: [Date: Int] = [:]
            var attention: [Date: Int] = [:]
            for row in rows {
                let createdAt: Date = row["createdAt"]
                let day = calendar.startOfDay(for: createdAt)
                entries[day, default: 0] += 1
                // Same rule as `Dictation.needsAttention`: anything not cleanly inserted.
                let status: String = row["status"]
                if status != Dictation.Status.inserted.rawValue { attention[day, default: 0] += 1 }
            }
            return (entries, attention)
        }
    }

    public func searchDictations(
        _ query: String, dateRange: DictationDateRange? = nil, limit: Int = 100
    ) throws -> [Dictation] {
        try writer.read { db in try Self.searchDictations(db, query: query, dateRange: dateRange, limit: limit) }
    }

    /// Best match first, newest as the tie-break (founder, 2026-10-26). Ordered by FTS5's `bm25()`, which
    /// scores how often and how densely the query words occur, so a small `limit` (the palette shows 8)
    /// keeps the rows that talk about the query instead of the newest rows that merely mention it. On
    /// 100,000 invented dictations newest-first held 0 of the 10 strongly relevant rows in its top 8 and
    /// BM25 held 8 of 8 (docs/research/algorithms-audit-2026-10-26.md, B5). No schema change.
    ///
    /// Two-step: find matching rowids via FTS5 first (no `dictation.*` columns touched — the FTS
    /// index alone can answer `MATCH`), then hydrate only the final page's rows in a second,
    /// `id IN (...)`-keyed query. The previous single query joined `dictation_fts` to
    /// `dictation.*` before filtering/sorting, so SQLite had to materialize (and, per
    /// `EXPLAIN QUERY PLAN`, `USE TEMP B-TREE FOR ORDER BY`) every matching row's full
    /// text/rawText columns even though most never make the final page. Measured 1.6-1.7x
    /// faster at 20k-50k rows / realistic (~5%) match rates, up to 2.8x faster at a high (60%)
    /// match rate (a common search term) — see docs/engineering/perf-audit-2026-09.md. Date-range
    /// filtering is unchanged, and the two-step fetch only changes *how* rows are fetched.
    static func searchDictations(
        _ db: Database, query: String, dateRange: DictationDateRange? = nil, limit: Int
    ) throws -> [Dictation] {
        guard let pattern = FTS5Pattern(matchingAllPrefixesIn: query) else { return [] }
        var idSQL = "SELECT dictation.id FROM dictation JOIN dictation_fts ON dictation_fts.rowid = dictation.id WHERE dictation_fts MATCH ?"
        var arguments: [DatabaseValueConvertible] = [pattern]
        if let dateRange {
            idSQL += " AND dictation.createdAt >= ? AND dictation.createdAt < ?"
            arguments += [dateRange.start, dateRange.end]
        }
        idSQL += " ORDER BY bm25(dictation_fts), dictation.createdAt DESC, dictation.id DESC LIMIT ?"
        arguments.append(limit)
        let ids = try Int64.fetchAll(db, sql: idSQL, arguments: StatementArguments(arguments))
        guard !ids.isEmpty else { return [] }
        // Re-fetch by id keeps the ranked order from the query above (GRDB's `filter(ids:)` does not
        // itself guarantee order).
        let byId = try Dictation.filter(ids: ids).fetchAll(db)
        let order = Dictionary(uniqueKeysWithValues: ids.enumerated().map { ($1, $0) })
        return byId.sorted { (order[$0.id ?? -1] ?? 0) < (order[$1.id ?? -1] ?? 0) }
    }
}

// MARK: - Insights (SQL aggregates)

extension Store {
    /// Statuses excluded from every Insights aggregate, matching `Insights.compute`'s
    /// `counted` filter (dictations that never really happened).
    private static let excludedStatuses: [String] = [
        Dictation.Status.cancelled.rawValue, Dictation.Status.failed.rawValue,
    ]

    /// How far back the per-app word counts look. A recent window is enough to order the apps by how much each is
    /// used, and keeps the query from reading every dictation ever made.
    public static let appUsageWindowDays = 90

    /// Words dictated per app identifier over the last `appUsageWindowDays` days, for ordering the apps in the
    /// tone screens. Read locally, one small query on the indexed `createdAt` column; Hushy's own windows are left
    /// out like everywhere else.
    public func appWordCounts(now: Date = Date()) throws -> [String: Int] {
        let since = now.addingTimeInterval(-Double(Self.appUsageWindowDays) * 86_400)
        return try writer.read { db in
            let placeholders = Self.excludedStatuses.map { _ in "?" }.joined(separator: ", ")
            var arguments: [DatabaseValueConvertible?] = [since]
            arguments += Self.excludedStatuses.map { $0 as DatabaseValueConvertible? }
            let rows = try Row.fetchAll(db, sql: """
                SELECT appBundleID, SUM(wordCount) AS words FROM dictation
                WHERE createdAt >= ? AND status NOT IN (\(placeholders)) AND appBundleID IS NOT NULL GROUP BY appBundleID
                """, arguments: StatementArguments(arguments))
            var counts: [String: Int] = [:]
            for row in rows {
                let id: String = row["appBundleID"]
                if !Insights.ownBundleIDs.contains(id) { counts[id] = row["words"] }
            }
            return counts
        }
    }

    /// How many dictations were made into each app on each (UTC) day over the last `appUsageWindowDays` days, for
    /// ranking the installed app names (`InstalledNameRanker`). Only the app identifier, the day and a count leave the
    /// query: no text, no title, no time of day. One grouped read on the indexed `createdAt` column, so at most
    /// apps x days rows however long the History is.
    public func appUseDays(now: Date = Date()) throws -> [String: [AppUseDay]] {
        let since = now.addingTimeInterval(-Double(Self.appUsageWindowDays) * 86_400)
        return try writer.read { db in
            let placeholders = Self.excludedStatuses.map { _ in "?" }.joined(separator: ", ")
            var arguments: [DatabaseValueConvertible?] = [since]
            arguments += Self.excludedStatuses.map { $0 as DatabaseValueConvertible? }
            let rows = try Row.fetchAll(db, sql: """
                SELECT appBundleID, CAST(strftime('%s', createdAt) AS INTEGER) / 86400 AS dayIndex, COUNT(*) AS uses
                FROM dictation
                WHERE createdAt >= ? AND status NOT IN (\(placeholders)) AND appBundleID IS NOT NULL
                GROUP BY appBundleID, dayIndex
                """, arguments: StatementArguments(arguments))
            var days: [String: [AppUseDay]] = [:]
            for row in rows {
                let id: String = row["appBundleID"]
                guard !Insights.ownBundleIDs.contains(id) else { continue }
                let dayIndex: Int = row["dayIndex"]
                let uses: Int = row["uses"]
                days[id, default: []].append(
                    AppUseDay(day: Date(timeIntervalSince1970: Double(dayIndex) * 86_400), uses: uses))
            }
            return days
        }
    }

    /// Computes `Insights` with SQL aggregates instead of fetching every row into memory.
    /// Semantics (timezone/day boundaries, own-app exclusions, status filters) are identical
    /// to `Insights.compute(from:)` — see `InsightsSQLEquivalenceTests` for a row-for-row
    /// comparison against the in-memory implementation. `now`/`calendar` are forwarded to the
    /// streak calculation exactly as `Insights.compute` uses them; `calendar` should stay the
    /// default `.current` in production since day boundaries are computed in SQL using the
    /// *system* local timezone (`'localtime'`), not an arbitrary calendar's timezone.
    public func computeInsights(now: Date = Date(), calendar: Calendar = .current) throws -> Insights {
        try writer.read { db in try Self.computeInsights(db, now: now, calendar: calendar) }
    }

    /// Exposed publicly (like `dictationPage(_:after:filter:pageSize:)`) so `Library` in the
    /// app target can drive a `ValueObservation` directly against a `Database`, which
    /// `ValueObservation.tracking` requires — the instance method above can't be called from
    /// inside that closure.
    public static func computeInsights(_ db: Database, now: Date, calendar: Calendar) throws -> Insights {
        let statusPlaceholders = excludedStatuses.map { _ in "?" }.joined(separator: ", ")
        let countedFilter = "status NOT IN (\(statusPlaceholders))"

        // 1) Whole-history totals: words, seconds, fixes, distinct apps, edit-state counts.
        let totalsSQL = """
            SELECT
                COUNT(*) AS totalDictations,
                COALESCE(SUM(wordCount), 0) AS totalWords,
                COALESCE(SUM(durationSeconds), 0.0) AS totalSeconds,
                COALESCE(SUM(fixes), 0) AS totalFixes,
                COUNT(DISTINCT CASE WHEN appBundleID IS NOT NULL THEN appBundleID END) AS appsUsed,
                COUNT(CASE WHEN editState IS NOT NULL THEN 1 END) AS editsMeasured,
                COUNT(CASE WHEN editState = 'kept' THEN 1 END) AS editsKept
            FROM dictation
            WHERE \(countedFilter)
            """
        guard let totals = try Row.fetchOne(db, sql: totalsSQL, arguments: StatementArguments(excludedStatuses)) else {
            return .empty
        }
        let totalDictations: Int = totals["totalDictations"]
        guard totalDictations > 0 else { return .empty }

        let totalWords: Int = totals["totalWords"]
        let totalSeconds: Double = totals["totalSeconds"]
        let totalFixes: Int = totals["totalFixes"]
        let appsUsed: Int = totals["appsUsed"]
        let editsMeasured: Int = totals["editsMeasured"]
        let editsKept: Int = totals["editsKept"]

        let wpm = totalSeconds > 0 ? Double(totalWords) / (totalSeconds / 60) : 0
        let typingMinutes = Double(totalWords) / Insights.typingWPM
        let minutesSaved = max(0, typingMinutes - totalSeconds / 60)
        let editFreeRate: Double? = editsMeasured > 0 ? Double(editsKept) / Double(editsMeasured) : nil

        // The same two edit numbers for the last seven local days, for "You kept 86% of dictations as typed this week".
        var weekArguments = StatementArguments(excludedStatuses)
        weekArguments += [Insights.weekStart(now: now, calendar: calendar)]
        let weekRow = try Row.fetchOne(db, sql: """
            SELECT COUNT(CASE WHEN editState IS NOT NULL THEN 1 END) AS measured,
                   COUNT(CASE WHEN editState = 'kept' THEN 1 END) AS kept
            FROM dictation
            WHERE \(countedFilter) AND createdAt >= ?
            """, arguments: weekArguments)
        let weekEditsMeasured: Int = weekRow?["measured"] ?? 0
        let weekEditsKept: Int = weekRow?["kept"] ?? 0

        // 2) Words per local calendar day, for the daily chart and streak calculation.
        // `createdAt` is stored as "yyyy-MM-dd HH:mm:ss.SSS" UTC (GRDB's default `Date`
        // encoding), so `date(createdAt, 'localtime')` yields the same Gregorian local day as
        // `Calendar.current.startOfDay(for:)` used by the in-memory implementation.
        let dailySQL = """
            SELECT date(createdAt, 'localtime') AS day, SUM(wordCount) AS words
            FROM dictation
            WHERE \(countedFilter)
            GROUP BY day
            """
        let dailyRows = try Row.fetchAll(db, sql: dailySQL, arguments: StatementArguments(excludedStatuses))
        let dayFormatter = Self.localDayFormatter
        var days: [Insights.DayCount] = []
        var activeDays: Set<Date> = []
        for row in dailyRows {
            let dayString: String = row["day"]
            guard let dayDate = dayFormatter.date(from: dayString) else { continue }
            let startOfDay = calendar.startOfDay(for: dayDate)
            let words: Int = row["words"]
            days.append(Insights.DayCount(day: startOfDay, words: words))
            activeDays.insert(startOfDay)
        }
        days.sort { $0.day < $1.day }
        let streaks = Insights.streaks(activeDays: activeDays, now: now, calendar: calendar)

        // 3) Per-app totals (words, count, fixes), for both the category breakdown (grouped by
        // `AppCategory.classify`, a Swift-side substring match not worth re-encoding in SQL)
        // and the top-apps list. The result set is one row per distinct app — small even at
        // very large history sizes — so classifying it in Swift costs nothing.
        let perAppSQL = """
            SELECT appBundleID, MAX(appName) AS appName, SUM(wordCount) AS words, COUNT(*) AS count
            FROM dictation
            WHERE \(countedFilter)
            GROUP BY appBundleID
            """
        let perAppRows = try Row.fetchAll(db, sql: perAppSQL, arguments: StatementArguments(excludedStatuses))

        var perCategory: [AppCategory: (words: Int, count: Int)] = [:]
        var topAppsSource: [(bundleID: String, name: String, words: Int)] = []
        for row in perAppRows {
            let bundleID: String? = row["appBundleID"]
            let words: Int = row["words"]
            let count: Int = row["count"]
            let category = AppCategory.classify(bundleID: bundleID)
            let current = perCategory[category] ?? (0, 0)
            perCategory[category] = (current.words + words, current.count + count)

            if let bundleID, !Insights.ownBundleIDs.contains(bundleID) {
                let name: String? = row["appName"]
                topAppsSource.append((bundleID, name ?? bundleID, words))
            }
        }
        let categories = perCategory
            .map { Insights.CategoryShare(
                category: $0.key, words: $0.value.words, count: $0.value.count,
                fraction: Double($0.value.words) / Double(max(totalWords, 1))) }
            .sorted { $0.words > $1.words }
        let topApps = topAppsSource
            .sorted { $0.words > $1.words }
            .prefix(6)
            .map { Insights.AppShare(
                bundleID: $0.bundleID, name: $0.name, words: $0.words,
                fraction: Double($0.words) / Double(max(totalWords, 1))) }

        return Insights(
            totalWords: totalWords,
            totalDictations: totalDictations,
            averageWPM: Int(wpm.rounded()),
            fixes: totalFixes,
            currentStreak: streaks.current,
            longestStreak: streaks.longest,
            minutesSaved: Int(minutesSaved.rounded()),
            days: days,
            categories: categories,
            appsUsed: appsUsed,
            editFreeRate: editFreeRate,
            editsMeasured: editsMeasured,
            weekEditsKept: weekEditsKept,
            weekEditsMeasured: weekEditsMeasured,
            topApps: Array(topApps),
            speakingSeconds: totalSeconds
        )
    }

    /// Parses SQLite's `date(..., 'localtime')` output ("yyyy-MM-dd") as a date at midnight in
    /// the system's local timezone, matching how the value was computed.
    private static var localDayFormatter: DateFormatter {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone.current
        return formatter
    }
}

// MARK: - Notes

extension Store {
    @discardableResult
    /// Saves a note. Folder assignment is owned by `moveNote(id:toFolder:)`: an existing note
    /// keeps its stored folder, so a stale in-memory copy (a recording's periodic autosave, a
    /// rename) never silently moves it back to Unfiled.
    ///
    /// The transcript is not a field a save writes: it is the cache of the note's turns
    /// (`Store+Transcript`). A stored note keeps its transcript, and the returned copy carries it.
    /// A new note given a transcript gets it as one legacy turn, so the cache and turns agree.
    public func save(_ note: Note) throws -> Note {
        try writer.write { db in
            var copy = note
            copy.updatedAt = Date()
            if let id = copy.id,
               let stored = try Row.fetchOne(db, sql: "SELECT folderId, transcript FROM note WHERE id = ?", arguments: [id]) {
                copy.folderId = stored["folderId"]
                copy.transcript = stored["transcript"]
                try copy.updateBesideTranscript(db)
                return copy
            }
            try copy.insert(db)
            if let id = copy.id, !copy.transcript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                var turn = NoteTurn(noteId: id, ordinal: 0, stream: .unknown, t0: 0, t1: nil, text: copy.transcript, origin: .legacy)
                try turn.insert(db)
                copy.transcript = try Self.materializeTranscript(db, noteId: id).rendered
            }
            // A note that arrives with items (an Ask answer kept as a note, an import of an older note, a fixture) gets
            // them as facts, the same rows v29 gave every older note, so every reader reads facts only.
            if let id = copy.id, !copy.actionItems.isEmpty || copy.summary.contains("Decided:") {
                _ = try LegacyFactBackfill.run(db, noteId: id)
            }
            return copy
        }
    }

    /// Writes a note that is already stored, as `save` does (never its transcript); nil, with nothing written, when it is gone. For work that
    /// finishes after the person may have deleted or erased the note (a retry, a summary): it never brings one back.
    public func update(_ note: Note) throws -> Note? {
        try writer.write { db in
            guard let id = note.id,
                  let stored = try Row.fetchOne(db, sql: "SELECT folderId, transcript FROM note WHERE id = ?", arguments: [id]) else { return nil }
            var copy = note
            copy.folderId = stored["folderId"]
            copy.transcript = stored["transcript"]
            copy.updatedAt = Date()
            try copy.updateBesideTranscript(db)
            return copy
        }
    }

    public func note(id: Int64) throws -> Note? {
        try writer.read { db in try Note.fetchOne(db, key: id) }
    }

    public func deleteNote(id: Int64) throws {
        discardPreMeetingsBackup()
        _ = try writer.write { db in try Note.deleteOne(db, key: id) }
    }

    /// Marks note sessions that were still active at process exit as incomplete. All note
    /// Rewrites stored audio paths after the data folder moved (Murmur → Hushy). Absolute
    /// paths saved under `oldRoot` point at files that now live under `newRoot`. Idempotent.
    @discardableResult
    public func rebaseMediaPaths(from oldRoot: String, to newRoot: String) throws -> Int {
        guard oldRoot != newRoot else { return 0 }
        let old = oldRoot.hasSuffix("/") ? oldRoot : oldRoot + "/"
        let new = newRoot.hasSuffix("/") ? newRoot : newRoot + "/"
        return try writer.write { db in
            var changed = 0
            for table in ["dictation", "note"] {
                try db.execute(
                    sql: "UPDATE \(table) SET audioPath = ? || substr(audioPath, ?) WHERE substr(audioPath, 1, ?) = ?",
                    arguments: [new, old.count + 1, old.count, old])
                changed += db.changesCount
            }
            return changed
        }
    }

    public func notes(limit: Int = 500) throws -> [Note] {
        try writer.read { db in try Self.notes(db, limit: limit) }
    }

    public func searchNotes(_ query: String, limit: Int = 50) throws -> [Note] {
        try writer.read { db in try Self.searchNotes(db, query: query, limit: limit) }
    }

    static func notes(_ db: Database, limit: Int) throws -> [Note] {
        try Note.order(Column("createdAt").desc).limit(limit).fetchAll(db)
    }

    /// Completed action-item indexes for `noteId` (indexes into that note's `actionItems`
    /// array). Empty means none are done — the common case, since only "done" rows are stored.
    public func doneActionItemIndexes(noteId: Int64) throws -> Set<Int> {
        try writer.read { db in
            let rows = try NoteActionItemStatus
                .filter(Column("noteId") == noteId && Column("isDone") == true)
                .fetchAll(db)
            return Set(rows.map(\.itemIndex))
        }
    }

    /// Completed action-item indexes across every note, keyed by note id — one query for
    /// Home's "Open action items" card instead of one round trip per note.
    public func doneActionItemIndexesByNote() throws -> [Int64: Set<Int>] {
        try writer.read { db in
            let rows = try NoteActionItemStatus.filter(Column("isDone") == true).fetchAll(db)
            return Dictionary(grouping: rows, by: \.noteId)
                .mapValues { Set($0.map(\.itemIndex)) }
        }
    }

    /// Marks one action item done/not-done. Setting it to not-done deletes the row (rather than
    /// storing `isDone = false`) so the table only ever grows with real "done" state.
    /// Forgets every checked-off item for a note. Completion is keyed by item index, so it
    /// must be cleared whenever the note's action items are regenerated.
    public func clearActionItemStatus(noteId: Int64) throws {
        _ = try writer.write { db in
            try NoteActionItemStatus.filter(Column("noteId") == noteId).deleteAll(db)
        }
    }

    /// Checks legacy item `itemIndex` off (or reopens it), on its fact too, so the fact and the index-keyed row agree.
    public func setActionItemDone(noteId: Int64, itemIndex: Int, isDone: Bool) throws {
        let fact = try writer.read { db in try Self.actionFact(db, noteId: noteId, index: itemIndex) }
        if let fact, try setActionFactDone(uuid: fact.uuid, isDone: isDone) { return }
        try writer.write { db in
            if isDone {
                try NoteActionItemStatus(noteId: noteId, itemIndex: itemIndex, isDone: true).save(db)
            } else {
                try NoteActionItemStatus.deleteOne(db, key: ["noteId": noteId, "itemIndex": itemIndex])
            }
        }
    }

    /// FTS5 `bm25()` column weights for `note_fts(title, transcript, summary)`: a word in the title or the
    /// summary says more about a note than the same word somewhere in a long transcript.
    private static let noteBM25Weights = "10.0, 1.0, 5.0"

    /// Best match first, newest as the tie-break (see `searchDictations`).
    static func searchNotes(_ db: Database, query: String, limit: Int) throws -> [Note] {
        guard let pattern = FTS5Pattern(matchingAllPrefixesIn: query) else { return [] }
        // Two indexes, one answer: `note_fts` (title, the transcript cache of every turn, summary) ranks a
        // note, and `turn_fts` finds a note by one turn's words, either side of the call. Notes that match
        // the note index come first, by its rank; a note found only by a turn follows, by its best turn.
        // (FTS5's bm25 cannot run inside a CTE or an aggregate, so the two ranked lists are read apart.)
        let byNote = try Int64.fetchAll(db, sql: """
            SELECT note.id FROM note
            JOIN note_fts ON note_fts.rowid = note.id
            WHERE note_fts MATCH ?
            ORDER BY bm25(note_fts, \(noteBM25Weights)), note.createdAt DESC, note.id DESC LIMIT ?
            """, arguments: [pattern, limit])
        var ids = byNote
        if ids.count < limit {
            let byTurn = try Int64.fetchAll(db, sql: """
                SELECT turn.noteId FROM turn_fts JOIN turn ON turn.id = turn_fts.rowid
                WHERE turn_fts MATCH ? ORDER BY bm25(turn_fts)
                """, arguments: [pattern])
            var seen = Set(ids)
            for id in byTurn where seen.insert(id).inserted {
                ids.append(id)
                if ids.count == limit { break }
            }
        }
        guard !ids.isEmpty else { return [] }
        let notes = try Note.filter(keys: ids).fetchAll(db)
        let byId = Dictionary(uniqueKeysWithValues: notes.compactMap { note in note.id.map { ($0, note) } })
        return ids.compactMap { byId[$0] }
    }
}

// MARK: - Entitlement snapshot (for out-of-process readers)

/// How the MCP helper learns the plan. `murmur-mcp` runs as a separate process with its own
/// defaults domain and no access to `Entitlements`, so the app mirrors one value into the store:
/// the instant Pro lapses (`Entitlements.proActiveUntil`), or nothing on Free. The helper only
/// ever reads it; it is refreshed at every app launch and on every `Entitlements.didChange`.
extension Store {
    static let proActiveUntilKey = "pro.activeUntil"

    /// Writes `activeUntil` (seconds since the 2001 reference date — `Date`'s own representation,
    /// so it round-trips exactly) under `pro.activeUntil`, or clears the row for `nil`.
    public func writeProSnapshot(activeUntil: Date?) throws {
        try writer.write { db in
            if let activeUntil {
                try db.execute(
                    sql: "INSERT OR REPLACE INTO entitlement (key, value) VALUES (?, ?)",
                    arguments: [Self.proActiveUntilKey, String(activeUntil.timeIntervalSinceReferenceDate)])
            } else {
                try db.execute(sql: "DELETE FROM entitlement WHERE key = ?", arguments: [Self.proActiveUntilKey])
            }
        }
    }

    public func proSnapshotActiveUntil() throws -> Date? {
        try writer.read { db in try Self.proSnapshotActiveUntil(db) }
    }

    static func proSnapshotActiveUntil(_ db: Database) throws -> Date? {
        guard let raw = try String.fetchOne(
            db, sql: "SELECT value FROM entitlement WHERE key = ?", arguments: [proActiveUntilKey]),
            let seconds = TimeInterval(raw)
        else { return nil }
        return Date(timeIntervalSinceReferenceDate: seconds)
    }
}

// MARK: - Note folders

extension Store {
    public enum FolderError: Error, LocalizedError, Equatable {
        case emptyName
        case duplicateName(String)
        case notFound

        public var errorDescription: String? {
            switch self {
            case .emptyName: "Folder name can't be empty."
            case .duplicateName(let name): "A folder named “\(name)” already exists."
            case .notFound: "That folder no longer exists."
            }
        }
    }

    /// All folders, alphabetically (case-insensitive, matching the unique-name collation).
    public func folders() throws -> [NoteFolder] {
        try writer.read { db in
            try NoteFolder.order(Column("name").collating(.localizedCaseInsensitiveCompare)).fetchAll(db)
        }
    }

    /// Number of notes filed under each folder id. Folders with zero notes are omitted.
    public func noteCountsByFolder() throws -> [Int64: Int] {
        try writer.read { db in
            let rows = try Row.fetchAll(
                db,
                sql: "SELECT folderId, COUNT(*) AS count FROM note WHERE folderId IS NOT NULL GROUP BY folderId")
            var counts: [Int64: Int] = [:]
            for row in rows {
                let folderId: Int64 = row["folderId"]
                counts[folderId] = row["count"]
            }
            return counts
        }
    }

    /// Number of notes with no folder assigned ("Unfiled").
    public func unfiledNoteCount() throws -> Int {
        try writer.read { db in try Note.filter(Column("folderId") == nil).fetchCount(db) }
    }

    /// Creates a folder. Trims the name, rejects an empty result, and rejects a name that
    /// already exists case-insensitively with a clear, catchable error (rather than a raw
    /// SQLite unique-constraint failure).
    @discardableResult
    public func createFolder(name: String) throws -> NoteFolder {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw FolderError.emptyName }
        return try writer.write { db in
            if try NoteFolder.filter(Column("name").collating(.nocase) == trimmed).fetchOne(db) != nil {
                throw FolderError.duplicateName(trimmed)
            }
            var folder = NoteFolder(name: trimmed)
            try folder.insert(db)
            return folder
        }
    }

    /// Renames a folder, with the same trim/empty/duplicate validation as `createFolder`.
    /// A rename to the folder's own current name (any case) is a no-op, not a duplicate error.
    @discardableResult
    public func renameFolder(id: Int64, to name: String) throws -> NoteFolder {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw FolderError.emptyName }
        return try writer.write { db in
            guard var folder = try NoteFolder.fetchOne(db, key: id) else {
                throw FolderError.notFound
            }
            if trimmed.lowercased() != folder.name.lowercased(),
               try NoteFolder.filter(Column("name").collating(.nocase) == trimmed).fetchOne(db) != nil {
                throw FolderError.duplicateName(trimmed)
            }
            folder.name = trimmed
            try folder.update(db)
            return folder
        }
    }

    /// Deletes a folder. Its notes are kept and become unfiled (`ON DELETE SET NULL`), not
    /// deleted — this only removes the folder row itself.
    public func deleteFolder(id: Int64) throws {
        _ = try writer.write { db in try NoteFolder.deleteOne(db, key: id) }
    }

    /// Moves a note into `folderId`, or to "Unfiled" when `folderId` is `nil`.
    public func moveNote(id: Int64, toFolder folderId: Int64?) throws {
        try writer.write { db in
            try db.execute(sql: "UPDATE note SET folderId = ? WHERE id = ?", arguments: [folderId, id])
        }
    }
}

// MARK: - Note speakers & segments

extension Store {
    /// Replaces every speaker/segment for `noteId` with `speakers`/`segments`, atomically (all
    /// old rows for the note are deleted, then the new ones are inserted, in one transaction —
    /// a reader never sees a partially-replaced note). This is the only write path for these
    /// tables: `SpeakerDiarizer` always recomputes the full set for a note rather than patching
    /// it incrementally, since a fresh diarization run has no stable correspondence to the
    /// previous run's speaker ids.
    ///
    /// `segments` reference speakers by their *position* in `speakers` (an index into that
    /// array), not by a pre-existing id — new `NoteSpeaker`/`NoteSegment` rows are always
    /// inserted fresh here, so ids are assigned by SQLite and threaded through automatically.
    /// Returns the inserted speakers (with their new ids) so a caller can act on them further.
    @discardableResult
    public func replaceSpeakerSegments(
        noteId: Int64, speakers: [NoteSpeaker], segments: [(speakerIndex: Int?, segment: AlignedSegment)]
    ) throws -> [NoteSpeaker] {
        try writer.write { db in
            try NoteSegment.filter(Column("noteId") == noteId).deleteAll(db)
            try NoteSpeaker.filter(Column("noteId") == noteId).deleteAll(db)

            var insertedSpeakers: [NoteSpeaker] = []
            for speaker in speakers {
                var copy = speaker
                copy.id = nil
                copy.noteId = noteId
                try copy.insert(db)
                insertedSpeakers.append(copy)
            }

            for (ordinal, entry) in segments.enumerated() {
                let speakerId = entry.speakerIndex.flatMap { index in
                    insertedSpeakers.indices.contains(index) ? insertedSpeakers[index].id : nil
                }
                var row = NoteSegment(
                    noteId: noteId, speakerId: speakerId, startTime: entry.segment.start,
                    endTime: entry.segment.end, text: entry.segment.text, ordinal: ordinal)
                try row.insert(db)
            }
            // Removing the old speakers cleared their turns' speaker; the cache follows.
            try Self.materializeTranscript(db, noteId: noteId)
            return insertedSpeakers
        }
    }

    /// Every segment for `noteId`, in order, joined with its speaker (nil when unattributed —
    /// `speakerId` was set null by a speaker delete/merge, or the note has no diarization yet).
    public func noteSegments(noteId: Int64) throws -> [NoteSegmentWithSpeaker] {
        try writer.read { db in
            let segments = try NoteSegment
                .filter(Column("noteId") == noteId)
                .order(Column("ordinal"))
                .fetchAll(db)
            guard !segments.isEmpty else { return [] }
            let speakerIds = Set(segments.compactMap(\.speakerId))
            let speakers = try NoteSpeaker.filter(speakerIds.contains(Column("id"))).fetchAll(db)
            let speakersById = Dictionary(uniqueKeysWithValues: speakers.compactMap { speaker in
                speaker.id.map { ($0, speaker) }
            })
            return segments.map { segment in
                NoteSegmentWithSpeaker(segment: segment, speaker: segment.speakerId.flatMap { speakersById[$0] })
            }
        }
    }

    /// True when `noteId` has any saved diarization segments — the UI's cheap check for whether
    /// to render speaker turns at all (see `RecordingDetailView`).
    public func hasSpeakerSegments(noteId: Int64) throws -> Bool {
        try writer.read { db in try NoteSegment.filter(Column("noteId") == noteId).fetchCount(db) > 0 }
    }

    /// Renames a speaker within a note (sets its `displayName`). Every segment referencing this
    /// speaker id picks up the new name on next read — a single-row update, not a fan-out over
    /// segments, per docs/research/speaker-labeling.md §2.5.
    public func renameSpeaker(id: Int64, to displayName: String) throws {
        let trimmed = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        try writer.write { db in
            try db.execute(
                sql: "UPDATE note_speaker SET displayName = ? WHERE id = ?",
                arguments: [trimmed.isEmpty ? nil : trimmed, id])
            if let noteId = try Int64.fetchOne(db, sql: "SELECT noteId FROM note_speaker WHERE id = ?", arguments: [id]) {
                let transcript = try Self.materializeTranscript(db, noteId: noteId)
                // A fact owned by this speaker shows the name the speaker is now shown with.
                if let shown = transcript.names[id] { try Self.renameFactOwners(db, noteId: noteId, speakerId: id, to: shown) }
            }
        }
    }

    /// Merges `sourceId` into `targetId` within the same note: every `note_segment` row pointing
    /// at `sourceId` is re-pointed to `targetId`, then the now-unreferenced `sourceId` speaker
    /// row is deleted. Per docs/research/speaker-labeling.md §2.5, this is the common
    /// diarization-correction case (one real person split into two clusters).
    public func mergeSpeakers(sourceId: Int64, intoTargetId targetId: Int64) throws {
        guard sourceId != targetId else { return }
        try writer.write { db in
            let noteId = try Int64.fetchOne(db, sql: "SELECT noteId FROM note_speaker WHERE id = ?", arguments: [sourceId])
            try db.execute(
                sql: "UPDATE note_segment SET speakerId = ? WHERE speakerId = ?",
                arguments: [targetId, sourceId])
            try db.execute(sql: "UPDATE turn SET speakerId = ? WHERE speakerId = ?", arguments: [targetId, sourceId])
            try NoteSpeaker.deleteOne(db, key: sourceId)
            if let noteId { try Self.materializeTranscript(db, noteId: noteId) }
        }
    }

    /// Links a per-note speaker to a persistent `Voice` (a confirmed "Is this Dana?" match, or a
    /// user picking a voice from a menu). Setting `voiceId` to `nil` unlinks it without touching
    /// the speaker's `displayName` — per docs/research/speaker-labeling.md §2.6, a remembered
    /// name must never be invented without the user's own prior action, so linking a voice here
    /// never itself renames the speaker; callers that want the name to follow the voice should
    /// call `renameSpeaker` explicitly alongside this.
    public func setSpeakerVoice(id: Int64, voiceId: Int64?) throws {
        try writer.write { db in
            try db.execute(sql: "UPDATE note_speaker SET voiceId = ? WHERE id = ?", arguments: [voiceId, id])
        }
    }

    /// Records an unconfirmed "Is this Dana?" suggestion for a speaker, per this task's "suggest,
    /// never auto-name" requirement — this never touches `voiceId` or `displayName`. Called by
    /// `SpeakerDiarizer` after a diarization pass finds a candidate above
    /// `VoiceMatcher.defaultThreshold` for a speaker that isn't already linked to a voice.
    public func suggestSpeakerVoice(id: Int64, voiceId: Int64, similarity: Double) throws {
        try writer.write { db in
            try db.execute(
                sql: "UPDATE note_speaker SET suggestedVoiceId = ?, suggestedSimilarity = ? WHERE id = ? AND voiceId IS NULL",
                arguments: [voiceId, similarity, id])
        }
    }

    /// Confirms a pending suggestion: sets `voiceId` to the suggested voice and clears the
    /// suggestion columns, in one update. Links only; the app confirms through
    /// `confirmSpeakerVoiceSuggestionApplyingName`, which also names the speaker and the digest.
    public func confirmSpeakerVoiceSuggestion(id: Int64) throws {
        try writer.write { db in
            try db.execute(
                sql: """
                    UPDATE note_speaker
                    SET voiceId = suggestedVoiceId, suggestedVoiceId = NULL, suggestedSimilarity = NULL
                    WHERE id = ? AND suggestedVoiceId IS NOT NULL
                    """,
                arguments: [id])
        }
    }

    /// Dismisses a pending suggestion without linking it — the user said "no, that's not them."
    /// Never re-suggested for the same note (a fresh diarization run, e.g. on retry, may propose
    /// it again; that's a new run's decision, not this method's concern).
    public func dismissSpeakerVoiceSuggestion(id: Int64) throws {
        try writer.write { db in
            try db.execute(
                sql: "UPDATE note_speaker SET suggestedVoiceId = NULL, suggestedSimilarity = NULL WHERE id = ?",
                arguments: [id])
        }
    }
}

// MARK: - Voices (Pro)

extension Store {
    /// All saved voices, newest-first update order (most-recently-confirmed/renamed first, a
    /// more useful default for a management list than alphabetical).
    public func voices() throws -> [Voice] {
        try writer.read { db in try Voice.order(Column("updatedAt").desc).fetchAll(db) }
    }

    /// The single reserved "You" voice, if enrolled.
    public func youVoice() throws -> Voice? {
        try writer.read { db in try Voice.filter(Column("isYou") == true).fetchOne(db) }
    }

    public func voice(id: Int64) throws -> Voice? {
        try writer.read { db in try Voice.fetchOne(db, key: id) }
    }

    /// Inserts a new voice. Enforces the "at most one `isYou` row" invariant referenced in
    /// `Voice`'s doc comment: enrolling a new "You" voice replaces (deletes) any existing one
    /// rather than creating a second, ambiguous "you" — re-enrollment is expected to happen when
    /// the user redoes Tune, not to accumulate silently.
    @discardableResult
    public func saveVoice(_ voice: Voice) throws -> Voice {
        try writer.write { db in
            if voice.isYou {
                try Voice.filter(Column("isYou") == true).deleteAll(db)
            }
            var copy = voice
            copy.id = nil
            try copy.insert(db)
            return copy
        }
    }

    /// Re-averages `embedding` (already encoded, plaintext `[Float]`) into an existing voice's
    /// stored signature and bumps `sampleCount`/`updatedAt`. The caller is responsible for
    /// decrypting the existing embedding, averaging (`VoiceSimilarity.weightedAverage`), and
    /// re-encrypting before calling this — `Store` itself never touches plaintext biometric data,
    /// consistent with `Voice`'s own doc comment.
    public func updateVoiceEmbedding(id: Int64, encryptedEmbedding: Data, sampleCount: Int) throws {
        try writer.write { db in
            try db.execute(
                sql: "UPDATE voice SET encryptedEmbedding = ?, sampleCount = ?, updatedAt = ? WHERE id = ?",
                arguments: [encryptedEmbedding, sampleCount, Date(), id])
        }
    }

    /// Renames a voice (does not touch any `note_speaker.displayName` — those are independent per
    /// docs/research/speaker-labeling.md §2.6's "never invent a name" rule; the Voices list is
    /// its own naming surface).
    public func renameVoice(id: Int64, to name: String) throws {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        try writer.write { db in
            try db.execute(
                sql: "UPDATE voice SET name = ?, updatedAt = ? WHERE id = ?", arguments: [trimmed, Date(), id])
        }
    }

    /// Deletes one voice. Every `note_speaker.voiceId` pointing at it is set null first (the
    /// column has no DB-level foreign key — see the v11 migration's doc comment — so this is done
    /// explicitly rather than relying on `ON DELETE SET NULL`), so past notes keep their
    /// transcript and speaker labels; only the cross-note "this is the same person" link and the
    /// biometric signature itself are removed. The names already given to speakers (and carried into
    /// summaries) stay; forgetting a voice is not a rename. Pending "Is this X?" suggestions that
    /// pointed at it are withdrawn. Per the DECISIONS.md consent/deletion entry, this
    /// is a real, immediate, unrecoverable delete — no soft-delete/trash state for biometric data.
    public func deleteVoice(id: Int64) throws {
        discardPreMeetingsBackup()
        try writer.write { db in
            try db.execute(sql: "UPDATE note_speaker SET voiceId = NULL WHERE voiceId = ?", arguments: [id])
            try db.execute(
                sql: "UPDATE note_speaker SET suggestedVoiceId = NULL, suggestedSimilarity = NULL WHERE suggestedVoiceId = ?",
                arguments: [id])
            try Voice.deleteOne(db, key: id)
        }
    }

    /// Deletes every voice (the Voices pane's "Delete all" control). Same unlink-then-delete
    /// shape as `deleteVoice`, in one transaction.
    public func deleteAllVoices() throws {
        discardPreMeetingsBackup()
        try writer.write { db in
            try db.execute(sql: "UPDATE note_speaker SET voiceId = NULL WHERE voiceId IS NOT NULL")
            try db.execute(
                sql: "UPDATE note_speaker SET suggestedVoiceId = NULL, suggestedSimilarity = NULL WHERE suggestedVoiceId IS NOT NULL")
            try Voice.deleteAll(db)
        }
    }
}

// MARK: - Personalization

extension Store {
    @discardableResult
    public func save(_ entry: DictionaryEntry) throws -> DictionaryEntry {
        try writer.write { db in
            var copy = entry
            try copy.save(db)
            return copy
        }
    }

    @discardableResult
    public func save(_ snippet: Snippet) throws -> Snippet {
        try snippet.validate()
        return try writer.write { db in
            var copy = snippet
            try copy.save(db)
            return copy
        }
    }

    public func deleteDictionaryEntry(id: Int64) throws {
        _ = try writer.write { db in try DictionaryEntry.deleteOne(db, key: id) }
    }

    public func deleteSnippet(id: Int64) throws {
        _ = try writer.write { db in try Snippet.deleteOne(db, key: id) }
    }

    public func dictionary() throws -> [DictionaryEntry] {
        try writer.read { db in try DictionaryEntry.order(Column("term").collating(.localizedCaseInsensitiveCompare)).fetchAll(db) }
    }

    public func snippets() throws -> [Snippet] {
        try writer.read { db in try Snippet.order(Column("trigger").collating(.localizedCaseInsensitiveCompare)).fetchAll(db) }
    }

    public func personalizer() throws -> Personalizer {
        try writer.read { db in
            Personalizer(
                dictionary: try DictionaryEntry.fetchAll(db),
                snippets: try Snippet.fetchAll(db)
            )
        }
    }
}
