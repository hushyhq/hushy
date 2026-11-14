import Foundation
import GRDB

/// Memory across meetings, on this Mac. Built from the summarised meetings (`MeetingRecord`),
/// kept as rows in an SQLite database with FTS5 (decisions, action items, people, companies,
/// series, turns), and answered in code: open commitments per person, decisions per company over
/// time, what changed between meetings, a brief before the next meeting. A model may reword an
/// answer (`MemoryPhraser`) but never adds a line, and every line keeps its meeting and quote.
///
/// The rows are derived: build again from the notes whenever they change. See
/// `docs/product/meeting-memory-api.md`.
public final class MeetingMemory: Sendable {
    public struct Options: Sendable, Equatable {
        /// Use the calendar's attendees, their companies and the recurring series. Off measures
        /// how much those links are worth.
        public var calendarLinks = true
        /// Settle items closed in later meetings and decisions replaced later. Off measures the
        /// write-time settling.
        public var settle = true

        public init(calendarLinks: Bool = true, settle: Bool = true) {
            self.calendarLinks = calendarLinks
            self.settle = settle
        }
    }

    let database: DatabaseQueue
    public let meetings: [Int64: MemoryMeeting]
    public let people: [Int64: MemoryPerson]
    public let companies: [Int64: MemoryCompany]
    public let decisions: [MemoryDecision]
    public let items: [MemoryItem]
    public let selfNames: [String]
    let weights: StemWeights

    /// Builds the rows in memory (or in the file at `url`, replaced).
    public init(records: [MeetingRecord], selfNames: [String], options: Options = Options(), url: URL? = nil) throws {
        let input = options.calendarLinks ? records : records.map { record in
            var copy = record
            copy.attendees = []
            copy.seriesKey = nil
            return copy
        }
        if let url { try? FileManager.default.removeItem(at: url) }
        database = try url.map { try DatabaseQueue(path: $0.path) } ?? DatabaseQueue()
        // The invite marks the user, so their own name is known even where Settings is not read.
        let invited = input.flatMap { $0.attendees.filter(\.isSelf).map(\.name) }
        let names = (selfNames + invited).filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
            .reduce(into: [String]()) { if !$0.contains($1) { $0.append($1) } }
        self.selfNames = names
        try database.write { db in
            var builder = MemoryBuilder(records: input, selfNames: names, settles: options.settle)
            try builder.write(db)
        }
        (meetings, people, companies, decisions, items) = try database.read(Self.load)
        let turnStems = try database.read { db in
            try String.fetchAll(db, sql: "SELECT stems FROM turn_fts").map { $0.split(separator: " ").map(String.init) }
        }
        weights = StemWeights(documents: turnStems + decisions.map { MemoryText.contentStems($0.text) }
            + items.map { MemoryText.contentStems($0.task) })
    }

    /// Every ready note in `store`, as memory. `selfNames`: the user's name from Settings, if any.
    public static func build(from store: Store, selfNames: [String], options: Options = Options(), url: URL? = nil) throws -> MeetingMemory {
        try MeetingMemory(records: store.meetingRecords(), selfNames: selfNames + ["You", "Me"], options: options, url: url)
    }

    static func load(_ db: Database) throws -> ([Int64: MemoryMeeting], [Int64: MemoryPerson], [Int64: MemoryCompany], [MemoryDecision], [MemoryItem]) {
        var peopleIn: [Int64: [Int64: Set<String>]] = [:]
        for row in try Row.fetchAll(db, sql: "SELECT note_id, person_id, role FROM meeting_person") {
            peopleIn[row["note_id"], default: [:]][row["person_id"], default: []].insert(row["role"])
        }
        var companiesIn: [Int64: Set<Int64>] = [:]
        for row in try Row.fetchAll(db, sql: "SELECT note_id, company_id FROM meeting_company") {
            companiesIn[row["note_id"], default: []].insert(row["company_id"])
        }
        let meetings = try Row.fetchAll(db, sql: #"SELECT note_id, title, start, "end", series_key, is_internal FROM meeting"#).map { row in
            let id: Int64 = row["note_id"]
            return MemoryMeeting(
                id: id, title: row["title"], start: Date(timeIntervalSince1970: row["start"]),
                end: Date(timeIntervalSince1970: row["end"]), seriesKey: row["series_key"], isInternal: row["is_internal"],
                people: peopleIn[id] ?? [:], companies: companiesIn[id] ?? [])
        }
        let people = try Row.fetchAll(db, sql: "SELECT id, name, company_id, is_self FROM person").map {
            MemoryPerson(id: $0["id"], name: $0["name"], companyId: $0["company_id"], isSelf: $0["is_self"])
        }
        let companies = try Row.fetchAll(db, sql: "SELECT id, domain, name, is_own FROM company").map {
            MemoryCompany(id: $0["id"], domain: $0["domain"], name: $0["name"], isOwn: $0["is_own"])
        }
        let decisions = try Row.fetchAll(db, sql: "SELECT id, note_id, text, quote_turn, superseded_by FROM decision ORDER BY id").map {
            MemoryDecision(id: $0["id"], noteId: $0["note_id"], text: $0["text"], quoteTurn: $0["quote_turn"], supersededBy: $0["superseded_by"])
        }
        let items = try Row.fetchAll(db, sql: """
            SELECT id, note_id, ordinal, owner_text, owner_person_id, task, due, status, quote_turn, closed_note_id, closed_turn, duplicate_of
            FROM action_item ORDER BY id
            """).map {
            MemoryItem(
                id: $0["id"], noteId: $0["note_id"], ordinal: $0["ordinal"], ownerText: $0["owner_text"], ownerId: $0["owner_person_id"], task: $0["task"],
                due: $0["due"], status: MemoryItem.Status(rawValue: $0["status"]) ?? .open, quoteTurn: $0["quote_turn"],
                closedNoteId: $0["closed_note_id"], closedTurn: $0["closed_turn"], duplicateOf: $0["duplicate_of"])
        }
        return (Dictionary(uniqueKeysWithValues: meetings.map { ($0.id, $0) }),
                Dictionary(uniqueKeysWithValues: people.map { ($0.id, $0) }),
                Dictionary(uniqueKeysWithValues: companies.map { ($0.id, $0) }),
                decisions, items)
    }

    // MARK: Reading

    public var selfPerson: MemoryPerson? { people.values.first(where: \.isSelf) }

    func ref(_ noteId: Int64) -> MemoryMeetingRef {
        let meeting = meetings[noteId]
        return MemoryMeetingRef(noteId: noteId, title: meeting?.title ?? "", start: meeting?.start ?? .distantPast)
    }

    /// The turn `ordinal` of meeting `noteId`, as a quote.
    public func quote(noteId: Int64, ordinal: Int?) -> MemoryQuote? {
        guard let ordinal else { return nil }
        return try? database.read { db in
            try Row.fetchOne(db, sql: "SELECT speaker, start_seconds, text FROM turn WHERE note_id = ? AND ordinal = ?",
                             arguments: [noteId, ordinal]).map {
                MemoryQuote(noteId: noteId, ordinal: ordinal, speaker: $0["speaker"], startSeconds: $0["start_seconds"], text: $0["text"])
            }
        }
    }

    /// Turns whose words match `stems`, best first (FTS5 bm25), limited to `noteIds` when given.
    public func searchTurns(_ stems: [String], in noteIds: Set<Int64>? = nil, limit: Int = 12) -> [MemoryQuote] {
        guard let match = MemoryText.ftsAny(stems) else { return [] }
        let rows = (try? database.read { db in
            try Row.fetchAll(db, sql: """
                SELECT t.note_id, t.ordinal, t.speaker, t.start_seconds, t.text, f.stems
                FROM turn_fts f JOIN turn t ON t.note_id = f.note_id AND t.ordinal = f.ordinal
                WHERE turn_fts MATCH ? ORDER BY bm25(turn_fts) LIMIT 400
                """, arguments: [match])
        }) ?? []
        let wanted = Set(stems)
        return rows.compactMap { row -> (MemoryQuote, Int)? in
            let noteId: Int64 = row["note_id"]
            if let noteIds, !noteIds.contains(noteId) { return nil }
            let hits = Set((row["stems"] as String).split(separator: " ").map(String.init)).intersection(wanted).count
            let quote = MemoryQuote(noteId: noteId, ordinal: row["ordinal"], speaker: row["speaker"], startSeconds: row["start_seconds"], text: row["text"])
            return (quote, hits)
        }
        .sorted { $0.1 > $1.1 }
        .prefix(limit).map(\.0)
    }

    /// Meetings whose title and summary carry at least `share` of `stems`.
    func meetingsAbout(_ stems: [String], share: Double = 0.6) -> Set<Int64> {
        guard !stems.isEmpty, let match = MemoryText.ftsAny(stems) else { return [] }
        let rows = (try? database.read { db in
            try Row.fetchAll(db, sql: "SELECT note_id, stems FROM meeting_fts WHERE meeting_fts MATCH ?", arguments: [match])
        }) ?? []
        return Set(rows.compactMap { row in
            let have = Set((row["stems"] as String).split(separator: " ").map(String.init))
            return MemoryText.coverage(of: stems, in: have) >= share ? row["note_id"] as Int64 : nil
        })
    }
}
