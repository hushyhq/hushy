import Foundation
import GRDB
import os

/// The frozen meetings migrations, v26 to v29 (docs/engineering/meetings-schema-freeze.md). Every user's file keeps
/// what these write for good, so nothing here may change once a build ships them. The code reads raw rows, never app
/// types such as `Note`, so a later model change cannot alter a shipped migration. No existing column is rewritten.
enum MeetingsSchema {
    /// Preview builds recorded these two; `v26-attendees` replaces both (GRDB deletes them from `grdb_migrations`).
    static let v26Merged: Set<String> = ["v26-note-attendees", "meetings-ui-jots"]

    static func register(in migrator: inout DatabaseMigrator) {
        migrator.registerMigration("v26-attendees", foreignKeyChecks: .immediate, merging: v26Merged) { db, _ in
            try v26Attendees(db)
        }
        migrator.registerMigration("v27-capture-segment", foreignKeyChecks: .immediate) { db in try v27CaptureSegment(db) }
        migrator.registerMigration("v28-turn", foreignKeyChecks: .immediate) { db in try v28Turn(db) }
        migrator.registerMigration("v29-meeting-fact", foreignKeyChecks: .immediate) { db in try v29MeetingFact(db) }
    }

    // MARK: v26

    /// Brings any history (fresh, build 3005, main, either preview order) to the same tables. Each part checks the
    /// schema that exists rather than which identifiers ran, so a store converges whatever ran before.
    static func v26Attendees(_ db: Database) throws {
        if try !db.tableExists("note_attendee") { try previewNoteAttendee(db) }
        if try !db.columns(in: "note_calendar_link").contains(where: { $0.name == "seriesKey" }) {
            try db.execute(sql: "ALTER TABLE note_calendar_link ADD COLUMN seriesKey TEXT")
        }
        if try !db.tableExists("meeting_jot") { try previewMeetingJot(db) }
        if try !db.tableExists("meeting_consent") { try previewMeetingConsent(db) }
        // Every attendee row written before this came from the calendar.
        if try !db.columns(in: "note_attendee").contains(where: { $0.name == "source" }) {
            try db.execute(sql: """
                ALTER TABLE note_attendee ADD COLUMN source TEXT NOT NULL DEFAULT 'calendar' \
                CHECK (source IN ('calendar','user'))
                """)
        }
        try db.execute(sql: "CREATE INDEX IF NOT EXISTS note_calendar_link_on_seriesKey ON note_calendar_link(seriesKey)")
    }

    /// `note_attendee` exactly as preview builds created it (v26-note-attendees), so fresh and preview stores match.
    static func previewNoteAttendee(_ db: Database) throws {
        try db.create(table: "note_attendee") { t in
            t.column("noteId", .integer).notNull().references("note", onDelete: .cascade)
            t.column("ordinal", .integer).notNull()
            t.column("name", .text).notNull()
            t.column("companyDomain", .text)
            t.column("isSelf", .boolean).notNull().defaults(to: false)
            t.primaryKey(["noteId", "ordinal"])
        }
    }

    /// `meeting_jot` exactly as preview builds created it (meetings-ui-jots).
    static func previewMeetingJot(_ db: Database) throws {
        try db.create(table: "meeting_jot") { t in
            t.autoIncrementedPrimaryKey("id")
            t.column("noteId", .integer).notNull().indexed().references("note", onDelete: .cascade)
            t.column("atSeconds", .double)
            t.column("text", .text).notNull()
            t.column("createdAt", .datetime).notNull()
        }
    }

    /// `meeting_consent` exactly as preview builds created it (meetings-ui-jots).
    static func previewMeetingConsent(_ db: Database) throws {
        try db.create(table: "meeting_consent") { t in
            t.column("noteId", .integer).primaryKey().references("note", onDelete: .cascade)
            t.column("method", .text).notNull()
            t.column("at", .datetime).notNull()
        }
    }

    // MARK: v27

    /// The capture journal and each note's resume point. No backfill and no file I/O: legacy chunk files are adopted
    /// into rows only when the finalize runner resumes or retries that note.
    static func v27CaptureSegment(_ db: Database) throws {
        try db.execute(sql: """
            CREATE TABLE capture_segment (
              id          INTEGER PRIMARY KEY AUTOINCREMENT,
              noteId      INTEGER NOT NULL REFERENCES note(id) ON DELETE CASCADE,
              stream      TEXT    NOT NULL CHECK (stream IN ('mic','system','file')),
              seq         INTEGER NOT NULL CHECK (seq >= 0),
              kind        TEXT    NOT NULL CHECK (kind IN ('audio','gap')),
              t0          REAL    NOT NULL CHECK (t0 >= 0),
              duration    REAL    NOT NULL CHECK (duration >= 0),
              sampleCount INTEGER NOT NULL DEFAULT 0,
              file        TEXT,
              format      TEXT    CHECK (format IN ('hseg1','wav','wav.enc')),
              sha256      TEXT,
              state       TEXT    NOT NULL CHECK (state IN ('open','sealed','transcribed','failed')),
              gapReason   TEXT    CHECK (gapReason IN ('silence','deviceLost','stall','permission','interrupted')),
              speechRatio REAL,
              peak        REAL,
              asrAttempts INTEGER NOT NULL DEFAULT 0,
              errorCode   TEXT,
              createdAt   DATETIME NOT NULL,
              updatedAt   DATETIME NOT NULL,
              UNIQUE (noteId, stream, seq),
              CHECK ((kind = 'audio') = (file IS NOT NULL)));
            CREATE INDEX capture_segment_on_noteId_state ON capture_segment(noteId, state);

            CREATE TABLE note_finalize (
              noteId          INTEGER PRIMARY KEY REFERENCES note(id) ON DELETE CASCADE,
              step            TEXT    NOT NULL CHECK (step IN ('capturing','sealing','transcribing','assembling',
                                                               'writing','exporting','done','needsAttention')),
              attempts        INTEGER NOT NULL DEFAULT 0,
              reason          TEXT,
              pipelineVersion INTEGER NOT NULL,
              updatedAt       DATETIME NOT NULL);
            CREATE INDEX note_finalize_on_step ON note_finalize(step);
            """)
    }

    // MARK: v28

    static func v28Turn(_ db: Database) throws {
        try db.execute(sql: """
            CREATE TABLE turn (
              id        INTEGER PRIMARY KEY AUTOINCREMENT,
              noteId    INTEGER NOT NULL REFERENCES note(id) ON DELETE CASCADE,
              ordinal   INTEGER NOT NULL,
              stream    TEXT    NOT NULL CHECK (stream IN ('mic','system','file','unknown')),
              segmentId INTEGER REFERENCES capture_segment(id) ON DELETE SET NULL,
              speakerId INTEGER REFERENCES note_speaker(id)   ON DELETE SET NULL,
              t0        REAL,
              t1        REAL,
              text      TEXT    NOT NULL,
              words     TEXT    CHECK (words IS NULL OR json_valid(words)),
              origin    TEXT    NOT NULL CHECK (origin IN ('capture','import','legacy')),
              UNIQUE (noteId, ordinal));
            CREATE INDEX turn_on_noteId_t0  ON turn(noteId, t0);
            CREATE INDEX turn_on_speakerId  ON turn(speakerId);
            CREATE INDEX turn_on_segmentId  ON turn(segmentId);

            CREATE TABLE speaker_assignment (
              speakerId       INTEGER NOT NULL REFERENCES note_speaker(id) ON DELETE CASCADE,
              noteId          INTEGER NOT NULL REFERENCES note(id)         ON DELETE CASCADE,
              name            TEXT    NOT NULL CHECK (length(name) BETWEEN 1 AND 80),
              source          TEXT    NOT NULL CHECK (source IN ('micChannel','calendar','ax')),
              confidence      REAL    NOT NULL CHECK (confidence BETWEEN 0 AND 1),
              attendeeOrdinal INTEGER,
              createdAt       DATETIME NOT NULL,
              PRIMARY KEY (speakerId, source, name));
            CREATE INDEX speaker_assignment_on_noteId ON speaker_assignment(noteId);
            """)
        // A legacy note reads as one turn with exactly today's text. Whitespace-only transcripts are empty notes.
        try db.execute(sql: """
            INSERT INTO turn (noteId, ordinal, stream, t0, t1, text, origin)
            SELECT id, 0, 'unknown', 0, NULL, transcript, 'legacy' FROM note
            WHERE trim(transcript, ' ' || char(9, 10, 13)) <> ''
            """)
        // After the backfill: one rebuild of the index is cheaper than a trigger per row.
        try db.create(virtualTable: "turn_fts", using: FTS5()) { t in
            t.synchronize(withTable: "turn")
            t.tokenizer = .porter(wrapping: .unicode61())
            t.column("text")
        }
    }

    // MARK: v29

    static func v29MeetingFact(_ db: Database) throws {
        try db.execute(sql: """
            CREATE TABLE meeting_fact (
              id                   INTEGER PRIMARY KEY AUTOINCREMENT,
              uuid                 TEXT    NOT NULL UNIQUE,
              noteId               INTEGER NOT NULL REFERENCES note(id) ON DELETE CASCADE,
              kind                 TEXT    NOT NULL CHECK (kind IN ('decision','action','openQuestion','change')),
              ordinal              INTEGER NOT NULL,
              text                 TEXT    NOT NULL CHECK (length(text) BETWEEN 1 AND 2000),
              ownerText            TEXT,
              ownerSpeakerId       INTEGER REFERENCES note_speaker(id) ON DELETE SET NULL,
              ownerAttendeeOrdinal INTEGER,
              ownerClaim           TEXT,
              due                  TEXT,
              dueDate              DATE,
              status               TEXT    NOT NULL DEFAULT 'open' CHECK (status IN ('open','done','dismissed')),
              statusAt             DATETIME,
              quote                TEXT,
              evidenceTurnId       INTEGER REFERENCES turn(id) ON DELETE SET NULL,
              evidenceStart        INTEGER,
              evidenceEnd          INTEGER,
              t0                   REAL,
              t1                   REAL,
              jotId                INTEGER REFERENCES meeting_jot(id) ON DELETE SET NULL,
              grounding            TEXT    NOT NULL CHECK (grounding IN ('verified','unsupported','unchecked')),
              origin               TEXT    NOT NULL CHECK (origin IN ('model','user','jot','legacy')),
              extractor            TEXT    NOT NULL,
              supersededBy         INTEGER REFERENCES meeting_fact(id) ON DELETE SET NULL,
              userEdited           BOOLEAN NOT NULL DEFAULT 0,
              createdAt            DATETIME NOT NULL,
              updatedAt            DATETIME NOT NULL);
            CREATE INDEX meeting_fact_on_noteId_kind_ordinal ON meeting_fact(noteId, kind, ordinal);
            CREATE INDEX meeting_fact_on_kind_status         ON meeting_fact(kind, status);
            CREATE INDEX meeting_fact_on_ownerSpeakerId      ON meeting_fact(ownerSpeakerId);
            CREATE INDEX meeting_fact_on_evidenceTurnId      ON meeting_fact(evidenceTurnId);
            CREATE INDEX meeting_fact_on_extractor           ON meeting_fact(extractor, grounding);
            """)
        let report = try LegacyFactBackfill.run(db)
        if report.skippedNotes > 0 || report.skippedItems > 0 {
            log.notice("fact backfill skipped \(report.skippedNotes) notes and \(report.skippedItems) items it could not read")
        }
        try db.create(virtualTable: "meeting_fact_fts", using: FTS5()) { t in
            t.synchronize(withTable: "meeting_fact")
            t.tokenizer = .porter(wrapping: .unicode61())
            t.column("text")
            t.column("ownerText")
            t.column("quote")
        }
    }

    private static let log = Logger(subsystem: "app.hushy", category: "store-migration")
}

/// v29's backfill: action items, `Decided:` summary lines and `!` jots of every existing note become facts with
/// `origin` legacy or jot. It is total: a cell it cannot read skips that note's items and is counted, never thrown,
/// because a throw here would leave the app on an empty in-memory store. Frozen with the migration.
enum LegacyFactBackfill {
    struct Report: Equatable, Sendable {
        var facts = 0
        var skippedNotes = 0
        var skippedItems = 0
    }

    static let maxTextScalars = 2_000

    private struct Detail: Decodable {
        var owner: String?
        var task: String?
        var due: String?
    }

    static func run(_ db: Database) throws -> Report {
        var report = Report()
        let doneAt = try doneItems(db)
        let jots = try decisionJots(db)
        let insert = try db.cachedStatement(sql: """
            INSERT INTO meeting_fact (uuid, noteId, kind, ordinal, text, ownerText, due, status, statusAt, t0, jotId,
                                      grounding, origin, extractor, createdAt, updatedAt)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, 'unchecked', ?, 'legacy', ?, ?)
            """)
        func add(_ noteId: Int64, _ kind: String, _ ordinal: Int, _ text: String, owner: String? = nil, due: String? = nil,
                 statusAt: DatabaseValue = .null, t0: DatabaseValue = .null, jotId: Int64? = nil, origin: String = "legacy",
                 stamp: DatabaseValue) throws {
            guard let text = clamped(text) else { report.skippedItems += 1; return }
            try insert.execute(arguments: [
                UUID().uuidString, noteId, kind, ordinal, text, nonEmpty(owner), nonEmpty(due),
                statusAt.isNull ? "open" : "done", statusAt, t0, jotId, origin, stamp, stamp,
            ])
            report.facts += 1
        }

        let notes = try Row.fetchCursor(db, sql: "SELECT id, summary, actionItems, actionItemDetails, updatedAt FROM note")
        while let row = try notes.next() {
            let noteId: Int64 = row["id"]
            let stamp: DatabaseValue = row["updatedAt"]
            if let lines = decodeLines(row["actionItems"]) {
                let details = decodeDetails(row["actionItemDetails"], count: lines.count)
                for (index, line) in lines.enumerated() {
                    let detail = details?[index]
                    let task = nonEmpty(detail?.task) ?? line
                    try add(noteId, "action", index, task, owner: detail?.owner, due: detail?.due,
                            statusAt: doneAt[ItemKey(noteId: noteId, index: index)] ?? .null, stamp: stamp)
                }
            } else {
                report.skippedNotes += 1
            }
            var ordinal = 0
            for jot in jots[noteId] ?? [] {
                try add(noteId, "decision", ordinal, jot.text, t0: jot.atSeconds, jotId: jot.id, origin: "jot", stamp: jot.createdAt)
                ordinal += 1
            }
            let summary: String? = row["summary"]
            for decision in decidedLines(summary ?? "") {
                try add(noteId, "decision", ordinal, decision, stamp: stamp)
                ordinal += 1
            }
        }
        return report
    }

    private struct ItemKey: Hashable { var noteId: Int64; var index: Int }

    private static func doneItems(_ db: Database) throws -> [ItemKey: DatabaseValue] {
        var done: [ItemKey: DatabaseValue] = [:]
        let rows = try Row.fetchCursor(db, sql: "SELECT noteId, itemIndex, updatedAt FROM noteActionItem WHERE isDone")
        while let row = try rows.next() {
            done[ItemKey(noteId: row["noteId"], index: row["itemIndex"])] = row["updatedAt"]
        }
        return done
    }

    private struct Jot { var id: Int64; var atSeconds: DatabaseValue; var text: String; var createdAt: DatabaseValue }

    /// The person's own "!" lines, in the order they happened (timed by time, untimed after), mark dropped.
    private static func decisionJots(_ db: Database) throws -> [Int64: [Jot]] {
        let rows = try Row.fetchAll(db, sql: """
            SELECT id, noteId, atSeconds, text, createdAt FROM meeting_jot
            WHERE substr(ltrim(text), 1, 1) = '!'
            ORDER BY noteId, atSeconds IS NULL, atSeconds, createdAt, id
            """)
        var byNote: [Int64: [Jot]] = [:]
        for row in rows {
            let raw: String = row["text"]
            let text = String(raw.trimmingCharacters(in: .whitespaces).dropFirst()).trimmingCharacters(in: .whitespaces)
            byNote[row["noteId"], default: []].append(
                Jot(id: row["id"], atSeconds: row["atSeconds"], text: text, createdAt: row["createdAt"]))
        }
        return byNote
    }

    /// The summary's decision lines: "- Decided: x", "• Decided: x" or "Decided: x", as the summary reader parsed them.
    static func decidedLines(_ summary: String) -> [String] {
        let prefix = "Decided:"
        return summary.split(separator: "\n").compactMap { raw in
            var line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("- ") || line.hasPrefix("• ") { line = String(line.dropFirst(2)) }
            line = line.trimmingCharacters(in: .whitespaces)
            guard line.hasPrefix(prefix) else { return nil }
            return line.dropFirst(prefix.count).trimmingCharacters(in: .whitespaces)
        }
    }

    static func decodeLines(_ value: DatabaseValue) -> [String]? {
        guard let json = String.fromDatabaseValue(value), let data = json.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode([String].self, from: data)
    }

    /// The fields, only when they line up with the lines (same count); anything else reads as none.
    private static func decodeDetails(_ value: DatabaseValue, count: Int) -> [Detail]? {
        guard let json = String.fromDatabaseValue(value), let data = json.data(using: .utf8),
              let details = try? JSONDecoder().decode([Detail].self, from: data), details.count == count else { return nil }
        return details
    }

    /// SQLite's `length` counts code points, so the 2,000 limit is applied to scalars, not characters.
    static func clamped(_ text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        var scalars = String.UnicodeScalarView()
        scalars.append(contentsOf: trimmed.unicodeScalars.prefix(maxTextScalars))
        return String(scalars)
    }

    private static func nonEmpty(_ text: String?) -> String? {
        guard let text = text?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return nil }
        return text
    }
}
