import CryptoKit
import Foundation
import GRDB
import Testing
@testable import MurmurCore

/// Upgrade tests for the meetings schema freeze (docs/engineering/meetings-schema-freeze.md, section 2). The fixtures
/// are files written by the old builds' own code (scripts/fixtures/make-store-fixture.sh), never this branch's
/// migrator run `upTo:`, and hold a synthetic corpus only. These tests read the file through SQL, so they also run
/// against the code from before the freeze, where they fail.
@Suite("Store upgrades to the frozen meetings schema", .timeLimit(.minutes(3)))
struct StoreUpgradeTests {
    enum Fixture: String, CaseIterable {
        case build3005 = "store-build3005"
        case main = "store-main-bdf01317"
    }

    static let repoRoot = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent()
    static let newIdentifiers = ["v26-attendees", "v27-capture-segment", "v28-turn", "v29-meeting-fact"]
    static let newTables = ["capture_segment", "note_finalize", "turn", "speaker_assignment", "meeting_fact"]

    // MARK: Helpers

    static func copy(_ fixture: Fixture) throws -> URL {
        let source = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("Fixtures/\(fixture.rawValue).sqlite")
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("store-upgrade-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let target = directory.appendingPathComponent("hushy.sqlite")
        try FileManager.default.copyItem(at: source, to: target)
        return target
    }

    static func raw(_ url: URL) throws -> DatabaseQueue {
        var config = Configuration()
        config.foreignKeysEnabled = true
        return try DatabaseQueue(path: url.path, configuration: config)
    }

    /// Every row of every ordinary table (shadow tables of the FTS indexes included), by the columns it has now.
    static func snapshot(_ db: Database) throws -> [String: [[DatabaseValue]]] {
        let tables = try String.fetchAll(db, sql: """
            SELECT name FROM sqlite_master WHERE type = 'table' AND name NOT LIKE 'sqlite_%'
            AND name <> 'grdb_migrations' AND sql NOT LIKE 'CREATE VIRTUAL%'
            """)
        var result: [String: [[DatabaseValue]]] = [:]
        for table in tables {
            result[table] = try rows(db, table: table, columns: try db.columns(in: table).map(\.name))
        }
        return result
    }

    static func rows(_ db: Database, table: String, columns: [String]) throws -> [[DatabaseValue]] {
        let list = columns.map(\.quotedDatabaseIdentifier).joined(separator: ", ")
        let order = (1...columns.count).map(String.init).joined(separator: ", ")
        return try Row.fetchAll(db, sql: "SELECT \(list) FROM \(table.quotedDatabaseIdentifier) ORDER BY \(order)")
            .map { Array($0.databaseValues) }
    }

    static func count(_ db: Database, _ sql: String, _ arguments: StatementArguments = []) throws -> Int {
        try Int.fetchOne(db, sql: sql, arguments: arguments) ?? -1
    }

    static func decided(_ summary: String) -> [String] {
        summary.split(separator: "\n").compactMap { raw in
            var line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("- ") || line.hasPrefix("• ") { line = String(line.dropFirst(2)) }
            guard line.hasPrefix("Decided:") else { return nil }
            return line.dropFirst("Decided:".count).trimmingCharacters(in: .whitespaces)
        }
    }

    // MARK: 1. Every existing note survives

    @Test("1. every pre-existing row and column is byte-identical", arguments: Fixture.allCases)
    func everyRowSurvives(_ fixture: Fixture) throws {
        let url = try Self.copy(fixture)
        let (before, columns) = try Self.raw(url).read { (db: Database) throws in
            (try Self.snapshot(db), try Self.snapshot(db).keys.reduce(into: [String: [String]]()) { result, table in
                result[table] = try db.columns(in: table).map(\.name)
            })
        }
        #expect(before["note"]?.count == 13)
        let store = try Store(url: url)
        try store.writer.read { (db: Database) throws in
            for (table, rows) in before {
                #expect(try Self.rows(db, table: table, columns: columns[table]!) == rows, "table \(table) changed")
            }
        }
    }

    // MARK: 2. Turn backfill

    @Test("2. each non-empty legacy note reads as one turn with its exact text", arguments: Fixture.allCases)
    func turnBackfill(_ fixture: Fixture) throws {
        let store = try Store(url: try Self.copy(fixture))
        try store.writer.read { (db: Database) throws in
            let notes = try Row.fetchAll(db, sql: "SELECT id, transcript FROM note")
            for note in notes {
                let id: Int64 = note["id"]
                let transcript: String = note["transcript"]
                let turns = try Row.fetchAll(db, sql: "SELECT text, origin, ordinal FROM turn WHERE noteId = ?", arguments: [id])
                if transcript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    #expect(turns.isEmpty, "note \(id) has a turn for an empty transcript")
                    continue
                }
                #expect(turns.count == 1, "note \(id)")
                #expect(turns.first?["origin"] == "legacy")
                #expect(turns.first?["text"] == transcript)
                #expect(try Self.count(db, "SELECT count(*) FROM turn JOIN note ON note.id = turn.noteId WHERE turn.noteId = ? AND turn.text = note.transcript", [id]) == 1)
                let probe = transcript.split(whereSeparator: { !$0.isLetter }).first { $0.count >= 3 }.map(String.init)
                let found = try Int64.fetchAll(db, sql: """
                    SELECT turn.noteId FROM turn JOIN turn_fts ON turn_fts.rowid = turn.id WHERE turn_fts MATCH ?
                    """, arguments: ["\"\(probe ?? "")\""])
                #expect(found.contains(id), "turn_fts finds no '\(probe ?? "")' in note \(id)")
            }
        }
    }

    // MARK: 3. Fact backfill

    @Test("3. action items, Decided lines and ! jots become facts", arguments: Fixture.allCases)
    func factBackfill(_ fixture: Fixture) throws {
        let store = try Store(url: try Self.copy(fixture))
        try store.writer.read { (db: Database) throws in
            for note in try Row.fetchAll(db, sql: "SELECT id, summary, actionItems, actionItemDetails FROM note") {
                let id: Int64 = note["id"]
                let lines = try JSONDecoder().decode([String].self, from: Data((note["actionItems"] as String).utf8))
                let details = (note["actionItemDetails"] as String?).flatMap {
                    try? JSONDecoder().decode([ActionItemDetail].self, from: Data($0.utf8))
                }.flatMap { $0.count == lines.count ? $0 : nil }
                let facts = try Row.fetchAll(db, sql: """
                    SELECT ordinal, text, ownerText, due, status, statusAt, origin, grounding, extractor FROM meeting_fact
                    WHERE noteId = ? AND kind = 'action' ORDER BY ordinal
                    """, arguments: [id])
                #expect(facts.count == lines.count, "note \(id)")
                let done = Set(try Int.fetchAll(db, sql: "SELECT itemIndex FROM noteActionItem WHERE noteId = ? AND isDone", arguments: [id]))
                for (index, fact) in facts.enumerated() {
                    #expect(fact["ordinal"] == index)
                    #expect(fact["origin"] == "legacy" && fact["grounding"] == "unchecked" && fact["extractor"] == "legacy")
                    #expect((fact["status"] as String) == (done.contains(index) ? "done" : "open"), "note \(id) item \(index)")
                    #expect(((fact["statusAt"] as DatabaseValue).isNull) == !done.contains(index))
                    if let detail = details?[index] {
                        #expect(fact["text"] == detail.task)
                        #expect(fact["ownerText"] == (detail.owner.isEmpty ? nil : detail.owner))
                        #expect(fact["due"] == (detail.due.isEmpty ? nil : detail.due))
                    } else {
                        #expect(fact["text"] == lines[index])
                    }
                }
                let decisions = try String.fetchAll(db, sql: """
                    SELECT text FROM meeting_fact WHERE noteId = ? AND kind = 'decision' AND origin = 'legacy' ORDER BY ordinal
                    """, arguments: [id])
                #expect(decisions == Self.decided(note["summary"]), "note \(id)")
            }
            let jots = try Row.fetchAll(db, sql: "SELECT id, noteId, atSeconds, text FROM meeting_jot WHERE text LIKE '!%'")
            #expect(jots.count == (fixture == .main ? 1 : 0))
            for jot in jots {
                let fact = try #require(try Row.fetchOne(
                    db, sql: "SELECT text, t0, kind, noteId FROM meeting_fact WHERE jotId = ? AND origin = 'jot'",
                    arguments: [jot["id"] as Int64]))
                #expect(fact["kind"] as String == "decision")
                #expect(fact["noteId"] as Int64 == jot["noteId"] as Int64)
                #expect(fact["t0"] as Double? == jot["atSeconds"] as Double?)
                #expect(fact["text"] as String == "ship the beta on Monday")
            }
            #expect(try Self.count(db, "SELECT count(*) FROM meeting_fact WHERE jotId IS NOT NULL") == jots.count)
            #expect(try Self.count(db, "SELECT count(*) FROM meeting_fact WHERE kind = 'action' AND status = 'done'") == 2)
        }
    }

    // MARK: 4. Attendees

    @Test("4. preview attendees are calendar rows, seriesKey is kept, 'ax' is refused", arguments: Fixture.allCases)
    func attendees(_ fixture: Fixture) throws {
        let store = try Store(url: try Self.copy(fixture))
        try store.writer.write { (db: Database) throws in
            let sources = try String.fetchAll(db, sql: "SELECT source FROM note_attendee")
            #expect(sources.count == (fixture == .main ? 3 : 0))
            #expect(sources.allSatisfy { $0 == "calendar" })
            let series = try String.fetchOne(db, sql: "SELECT seriesKey FROM note_calendar_link WHERE noteId = 8")
            #expect(series == (fixture == .main ? "fixture-series-acme" : nil))
            #expect(throws: DatabaseError.self) {
                try db.execute(sql: "INSERT INTO note_attendee (noteId, ordinal, name, source) VALUES (8, 9, 'From the window', 'ax')")
            }
            try db.execute(sql: "INSERT INTO note_attendee (noteId, ordinal, name, source) VALUES (8, 9, 'Added by hand', 'user')")
            #expect(try db.indexes(on: "note_calendar_link").contains { $0.name == "note_calendar_link_on_seriesKey" })
        }
    }

    // MARK: 5. Identifiers

    @Test("5. the migration list ends v26-attendees to v29 and no preview identifier is left", arguments: Fixture.allCases)
    func identifiers(_ fixture: Fixture) throws {
        let store = try Store(url: try Self.copy(fixture))
        try store.writer.read { (db: Database) throws in
            let applied = try String.fetchAll(db, sql: "SELECT identifier FROM grdb_migrations ORDER BY rowid")
            #expect(Array(applied.suffix(4)) == Self.newIdentifiers)
            #expect(!applied.contains("meetings-ui-jots") && !applied.contains("v26-note-attendees"))
            #expect(try Store.migrator.hasCompletedMigrations(db))
            #expect(try !Store.migrator.hasBeenSuperseded(db))
        }
    }

    // MARK: 6. Same schema three ways

    struct Schema: Equatable, CustomStringConvertible {
        var tables: [String: [String]] = [:]
        var triggers: [String] = []
        var description: String {
            tables.keys.sorted().map { "\($0):\n  " + tables[$0]!.joined(separator: "\n  ") }.joined(separator: "\n")
                + "\ntriggers: \(triggers)"
        }
    }

    static func schema(_ db: Database) throws -> Schema {
        var schema = Schema()
        for table in try String.fetchAll(db, sql: "SELECT name FROM sqlite_master WHERE type = 'table' AND name NOT LIKE 'sqlite_%'") {
            let quoted = table.quotedDatabaseIdentifier
            var lines = try Row.fetchAll(db, sql: "PRAGMA table_info(\(quoted))").map { row in
                "col \(row["name"] as String) \((row["type"] as String).uppercased()) notnull=\(row["notnull"] as Int) default=\(row["dflt_value"] as String? ?? "-") pk=\(row["pk"] as Int)"
            }
            for index in try Row.fetchAll(db, sql: "PRAGMA index_list(\(quoted))") {
                let name: String = index["name"]
                let columns = try String.fetchAll(db, sql: "SELECT coalesce(name, '<expression>') FROM pragma_index_info(?)", arguments: [name])
                let label = name.hasPrefix("sqlite_autoindex") ? "autoindex" : name
                let sql = try String.fetchOne(db, sql: "SELECT sql FROM sqlite_master WHERE type = 'index' AND name = ?", arguments: [name])
                    .map { $0.lowercased().filter { !$0.isWhitespace && $0 != "\"" } } ?? "-"
                lines.append("index \(label) unique=\(index["unique"] as Int) origin=\(index["origin"] as String) partial=\(index["partial"] as Int) \(columns) \(sql)")
            }
            lines += try Row.fetchAll(db, sql: "PRAGMA foreign_key_list(\(quoted))").map { row in
                "fk \(row["from"] as String) -> \(row["table"] as String).\(row["to"] as String? ?? "-") update=\(row["on_update"] as String) delete=\(row["on_delete"] as String)"
            }
            schema.tables[table] = lines.sorted()
        }
        schema.triggers = try String.fetchAll(db, sql: "SELECT name FROM sqlite_master WHERE type = 'trigger' ORDER BY name")
        return schema
    }

    /// A preview build's store: build 3005's file plus the preview migrations in the given order, each run with the
    /// SQL the preview build wrote (taken from the main fixture) and recorded under its old identifier.
    static func previewStore(_ order: [String]) throws -> URL {
        let url = try copy(.build3005)
        let previewSQL = try raw(try copy(.main)).read { (db: Database) throws in
            try [String: String](uniqueKeysWithValues: Row.fetchAll(db, sql: """
                SELECT name, sql FROM sqlite_master WHERE name IN ('note_attendee', 'meeting_jot', 'meeting_jot_on_noteId', 'meeting_consent')
                """).map { ($0["name"] as String, $0["sql"] as String) })
        }
        try raw(url).write { (db: Database) throws in
            for identifier in order {
                switch identifier {
                case "v26-note-attendees":
                    try db.execute(sql: previewSQL["note_attendee"]!)
                    try db.execute(sql: "ALTER TABLE note_calendar_link ADD COLUMN seriesKey TEXT")
                case "meetings-ui-jots":
                    try db.execute(sql: previewSQL["meeting_jot"]!)
                    try db.execute(sql: previewSQL["meeting_jot_on_noteId"]!)
                    try db.execute(sql: previewSQL["meeting_consent"]!)
                default:
                    Issue.record("unknown preview migration \(identifier)")
                }
                try db.execute(sql: "INSERT INTO grdb_migrations (identifier) VALUES (?)", arguments: [identifier])
            }
        }
        return url
    }

    @Test("6. fresh, 3005, main and both preview orders end with the same schema")
    func sameSchemaEveryWay() throws {
        let freshURL = FileManager.default.temporaryDirectory.appendingPathComponent("fresh-\(UUID().uuidString)/hushy.sqlite")
        let fresh = try Store(url: freshURL).writer.read(Self.schema)
        #expect(fresh.tables["turn"] != nil && fresh.tables["meeting_fact"] != nil)
        let histories: [(String, URL)] = [
            ("build 3005", try Self.copy(.build3005)),
            ("main", try Self.copy(.main)),
            ("jots first", try Self.previewStore(["meetings-ui-jots"])),
            ("attendees first", try Self.previewStore(["v26-note-attendees"])),
            ("attendees then jots", try Self.previewStore(["v26-note-attendees", "meetings-ui-jots"])),
        ]
        for (name, url) in histories {
            let upgraded = try Store(url: url).writer.read(Self.schema)
            for table in Set(fresh.tables.keys).union(upgraded.tables.keys) where fresh.tables[table] != upgraded.tables[table] {
                Issue.record("\(name): table \(table) differs\nfresh:    \(fresh.tables[table] ?? [])\nupgraded: \(upgraded.tables[table] ?? [])")
            }
            #expect(upgraded.triggers == fresh.triggers, "\(name) triggers")
            #expect(try Store(url: url).writer.read { try Store.migrator.hasCompletedMigrations($0) }, "\(name)")
        }
    }

    // MARK: 7. Idempotent

    @Test("7. a second open changes nothing", arguments: Fixture.allCases)
    func secondOpenChangesNothing(_ fixture: Fixture) throws {
        let url = try Self.copy(fixture)
        let first = try Store(url: url).writer.read(Self.snapshot)
        let store = try Store(url: url)
        #expect(try store.writer.write { try Self.count($0, "SELECT total_changes()") } == 0)
        #expect(try store.writer.read(Self.snapshot) == first)
    }

    // MARK: 8. Constraints

    @Test("8. the new tables refuse impossible rows")
    func constraints() throws {
        let store = try Store(url: try Self.copy(.main))
        try store.writer.write { (db: Database) throws in
            let now = "2026-11-07 10:00:00.000"
            func segment(_ stream: String, _ seq: Int, _ kind: String, _ file: String?, _ state: String) throws {
                try db.execute(sql: """
                    INSERT INTO capture_segment (noteId, stream, seq, kind, t0, duration, file, state, createdAt, updatedAt)
                    VALUES (2, ?, ?, ?, 0, 1, ?, ?, ?, ?)
                    """, arguments: [stream, seq, kind, file, state, now, now])
            }
            try segment("mic", 0, "audio", "seg-0-mic.hseg", "open")
            try segment("system", 0, "gap", nil, "sealed")
            #expect(throws: DatabaseError.self) { try segment("mic", 1, "audio", nil, "open") }
            #expect(throws: DatabaseError.self) { try segment("mic", 2, "gap", "a.hseg", "open") }
            #expect(throws: DatabaseError.self) { try segment("mic", 3, "video", "a.hseg", "open") }
            #expect(throws: DatabaseError.self) { try segment("tv", 4, "audio", "a.hseg", "open") }
            #expect(throws: DatabaseError.self) { try segment("mic", 5, "audio", "a.hseg", "done") }
            #expect(throws: DatabaseError.self) { try segment("mic", 0, "audio", "dup.hseg", "open") }
            let speaker = try Int64.fetchOne(db, sql: "SELECT id FROM note_speaker WHERE noteId = 2 ORDER BY id")!
            func assign(_ confidence: Double, _ name: String) throws {
                try db.execute(sql: """
                    INSERT INTO speaker_assignment (speakerId, noteId, name, source, confidence, createdAt) VALUES (?, 2, ?, 'ax', ?, ?)
                    """, arguments: [speaker, name, confidence, now])
            }
            try assign(0.9, "Avery")
            #expect(throws: DatabaseError.self) { try assign(1.5, "Too sure") }
            #expect(throws: DatabaseError.self) { try assign(0.5, "") }
            #expect(throws: DatabaseError.self) {
                try db.execute(sql: "INSERT INTO turn (noteId, ordinal, stream, text, origin) VALUES (2, 5, 'radio', 'x', 'capture')")
            }
            #expect(throws: DatabaseError.self) {
                try db.execute(sql: "INSERT INTO turn (noteId, ordinal, stream, text, words, origin) VALUES (2, 6, 'mic', 'x', 'not json', 'capture')")
            }
            #expect(throws: DatabaseError.self) {
                try db.execute(sql: """
                    INSERT INTO meeting_fact (uuid, noteId, kind, ordinal, text, grounding, origin, extractor, createdAt, updatedAt)
                    VALUES ('u1', 2, 'rumour', 0, 'x', 'verified', 'model', 'test', ?, ?)
                    """, arguments: [now, now])
            }
            #expect(throws: DatabaseError.self) {
                try db.execute(sql: "INSERT INTO note_finalize (noteId, step, pipelineVersion, updatedAt) VALUES (2, 'finished', 1, ?)", arguments: [now])
            }
        }
    }

    // MARK: 9. Cascades

    static func seedNewRows(_ db: Database, noteId: Int64, word: String) throws {
        let now = "2026-11-07 10:00:00.000"
        try db.execute(sql: "INSERT INTO speaker_assignment (speakerId, noteId, name, source, confidence, createdAt) SELECT id, noteId, 'Guess', 'calendar', 0.8, ? FROM note_speaker WHERE noteId = ?", arguments: [now, noteId])
        try db.execute(sql: """
            INSERT INTO capture_segment (noteId, stream, seq, kind, t0, duration, file, format, state, createdAt, updatedAt)
            VALUES (?, 'mic', 0, 'audio', 0, 30, 'seg-0-mic.hseg', 'hseg1', 'transcribed', ?, ?)
            """, arguments: [noteId, now, now])
        let segment = db.lastInsertedRowID
        let speaker = try Int64.fetchOne(db, sql: "SELECT max(id) FROM note_speaker WHERE noteId = ?", arguments: [noteId])
        try db.execute(sql: """
            INSERT INTO turn (noteId, ordinal, stream, segmentId, speakerId, t0, t1, text, origin)
            VALUES (?, 1, 'mic', ?, ?, 0, 30, ?, 'capture')
            """, arguments: [noteId, segment, speaker, "the \(word) turn"])
        let turn = db.lastInsertedRowID
        try db.execute(sql: """
            INSERT INTO meeting_fact (uuid, noteId, kind, ordinal, text, ownerSpeakerId, quote, evidenceTurnId,
                                      grounding, origin, extractor, createdAt, updatedAt)
            VALUES (?, ?, 'action', 9, ?, ?, ?, ?, 'verified', 'model', 'test', ?, ?)
            """, arguments: [UUID().uuidString, noteId, "do the \(word) thing", speaker, word, turn, now, now])
        try db.execute(sql: "INSERT INTO note_finalize (noteId, step, pipelineVersion, updatedAt) VALUES (?, 'done', 1, ?)", arguments: [noteId, now])
        try db.execute(sql: "INSERT INTO note_attendee (noteId, ordinal, name, source) VALUES (?, 40, 'Hand added', 'user')", arguments: [noteId])
    }

    static func rowsFor(_ db: Database, noteId: Int64) throws -> Int {
        try (newTables + ["note_attendee"]).reduce(0) { total, table in
            total + (try count(db, "SELECT count(*) FROM \(table) WHERE noteId = ?", [noteId]))
        }
    }

    @Test("9. deleting a note or a speaker or erasing meetings clears every new table and index")
    func cascades() throws {
        let store = try Store(url: try Self.copy(.main))
        try store.writer.write { (db: Database) throws in
            try Self.seedNewRows(db, noteId: 2, word: "zebracascade")
            let speaker = try Int64.fetchOne(db, sql: "SELECT max(id) FROM note_speaker WHERE noteId = 2")!
            try db.execute(sql: "DELETE FROM note_speaker WHERE id = ?", arguments: [speaker])
            #expect(try Self.count(db, "SELECT count(*) FROM turn WHERE noteId = 2 AND ordinal = 1 AND speakerId IS NULL") == 1)
            #expect(try Self.count(db, "SELECT count(*) FROM meeting_fact WHERE noteId = 2 AND ordinal = 9 AND ownerSpeakerId IS NULL") == 1)
            #expect(try Self.count(db, "SELECT count(*) FROM speaker_assignment WHERE speakerId = ?", [speaker]) == 0)
            #expect(try Self.count(db, "SELECT count(*) FROM speaker_assignment WHERE noteId = 2") == 1)
            try db.execute(sql: "DELETE FROM note WHERE id = 2")
            #expect(try Self.rowsFor(db, noteId: 2) == 0)
            #expect(try Self.count(db, "SELECT count(*) FROM turn_fts WHERE turn_fts MATCH 'zebracascade'") == 0)
            #expect(try Self.count(db, "SELECT count(*) FROM meeting_fact_fts WHERE meeting_fact_fts MATCH 'zebracascade'") == 0)
            try Self.seedNewRows(db, noteId: 9, word: "okapierase")
            #expect(try Self.count(db, "SELECT count(*) FROM turn_fts WHERE turn_fts MATCH 'okapierase'") == 1)
            #expect(try Self.count(db, "SELECT count(*) FROM meeting_fact_fts WHERE meeting_fact_fts MATCH 'okapierase'") == 1)
        }
        let plan = try store.meetingErasePlan()
        #expect(plan.noteIDs.contains(9) && plan.noteIDs.contains(8))
        try store.eraseMeetings(plan)
        try store.writer.read { (db: Database) throws in
            for id in plan.noteIDs { #expect(try Self.rowsFor(db, noteId: id) == 0, "note \(id)") }
            #expect(try Self.count(db, "SELECT count(*) FROM meeting_jot WHERE noteId = 9") == 0)
            #expect(try Self.count(db, "SELECT count(*) FROM turn_fts WHERE turn_fts MATCH 'okapierase'") == 0)
            #expect(try Self.count(db, "SELECT count(*) FROM meeting_fact_fts WHERE meeting_fact_fts MATCH 'okapierase'") == 0)
            #expect(try Self.count(db, "SELECT count(*) FROM meeting_fact WHERE noteId NOT IN (SELECT id FROM note)") == 0)
        }
    }

    // MARK: 10. Total backfill

    @Test("10. an unreadable actionItems cell skips that note and the migration still completes")
    func corruptCellIsSkipped() throws {
        let url = try Self.copy(.main)
        try Self.raw(url).write { (db: Database) throws in
            try db.execute(sql: "UPDATE note SET actionItems = 'not json at all' WHERE id = 9")
            try db.execute(sql: "UPDATE note SET actionItemDetails = '{broken' WHERE id = 12")
        }
        let store = try Store(url: url)
        try store.writer.read { (db: Database) throws in
            #expect(try Store.migrator.hasCompletedMigrations(db))
            #expect(try Self.count(db, "SELECT count(*) FROM meeting_fact WHERE noteId = 9 AND kind = 'action'") == 0)
            #expect(try String.fetchOne(db, sql: "SELECT actionItems FROM note WHERE id = 9") == "not json at all")
            #expect(try String.fetchAll(db, sql: "SELECT text FROM meeting_fact WHERE noteId = 12 AND kind = 'action'") == ["Répondre à José 🎯"])
            #expect(try Self.count(db, "SELECT count(*) FROM meeting_fact WHERE noteId = 9 AND origin = 'jot'") == 1)
            #expect(try Self.count(db, "SELECT count(*) FROM meeting_fact WHERE noteId = 10 AND kind = 'decision'") == 2)
        }
    }

    // MARK: 11. Speed

    @Test("11. 2,000 notes of 30 kB and 20k items migrate v25 to v29 within budget")
    func speed() throws {
        let url = try Self.copy(.build3005)
        let sentence = String(repeating: "Budget speed sentence about the pilot and the roadmap. ", count: 560)
        let items = (0..<10).map { "Owner \($0): task number \($0)" }
        let itemsJSON = String(data: try JSONEncoder().encode(items), encoding: .utf8)!
        let detailsJSON = String(data: try JSONEncoder().encode(items.indices.map {
            ActionItemDetail(owner: "Owner \($0)", task: "task number \($0)", due: "by Friday")
        }), encoding: .utf8)!
        try Self.raw(url).write { (db: Database) throws in
            let insert = try db.makeStatement(sql: """
                INSERT INTO note (title, createdAt, updatedAt, durationSeconds, transcript, summary, actionItems, actionItemDetails, status, source)
                VALUES (?, '2026-10-01 10:00:00.000', '2026-10-01 11:00:00.000', 1800, ?, ?, ?, ?, 'ready', 'recording')
                """)
            for index in 0..<2_000 {
                try insert.execute(arguments: [
                    "Speed \(index)", "\(index) \(sentence)", "- Point\n- Decided: option \(index)", itemsJSON, detailsJSON,
                ])
            }
        }
        let start = ContinuousClock.now
        let store = try Store(url: url)
        let elapsed = ContinuousClock.now - start
        #expect(try store.writer.read { try Self.count($0, "SELECT count(*) FROM meeting_fact WHERE kind = 'action'") } >= 20_000)
        #if DEBUG
        let budget = Duration.seconds(20)
        #else
        let budget = Duration.seconds(3)
        #endif
        print("store-upgrade speed: v25→v29 with backup over 2,013 notes took \(elapsed)")
        #expect(elapsed < budget, "took \(elapsed)")
    }

    // MARK: 12. Rollback

    static let reader3005 = repoRoot.appendingPathComponent(".build/store-fixtures/v1.0.0-build3005/fixture-writer")

    static func sha(_ text: String) -> String {
        SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    @Test("12. build 3005 opens the v29 file and lists every note with its old text",
          .enabled(if: FileManager.default.isExecutableFile(atPath: reader3005.path),
                   "build the 3005 reader with scripts/fixtures/make-store-fixture.sh v1.0.0-build3005"))
    func rollbackTo3005() throws {
        let url = try Self.copy(.build3005)
        let expected = try Self.raw(url).read { (db: Database) throws in
            try Row.fetchAll(db, sql: "SELECT id, status, title, transcript, summary, actionItems FROM note ORDER BY id").map { row in
                let items = try JSONDecoder().decode([String].self, from: Data((row["actionItems"] as String).utf8))
                return [String(row["id"] as Int64), row["status"], Self.sha(row["title"]), Self.sha(row["transcript"]),
                        Self.sha(row["summary"]), String(items.count)].joined(separator: "\t")
            }
        }
        try Store(url: url).writer.read { (db: Database) throws in
            #expect(try Array(String.fetchAll(db, sql: "SELECT identifier FROM grdb_migrations ORDER BY rowid").suffix(4)) == Self.newIdentifiers)
        }
        let home = url.deletingLastPathComponent().appendingPathComponent("home")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        let process = Process()
        process.executableURL = Self.reader3005
        process.arguments = ["list", url.path]
        process.environment = ["HUSHY_HOME": home.path, "MURMUR_HOME": home.path, "PATH": "/usr/bin:/bin"]
        let output = Pipe()
        process.standardOutput = output
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        #expect(process.terminationStatus == 0)
        let listed = String(decoding: data, as: UTF8.self).split(separator: "\n").map(String.init)
        #expect(listed == expected)
    }
}
