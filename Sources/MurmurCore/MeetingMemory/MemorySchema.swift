import Foundation
import GRDB

/// The rows meeting memory keeps. Every row belongs to one meeting (`note_id`) and every fact row
/// carries a quote anchor: the turn it was found in (`*_turn`), so an answer line can open the
/// meeting at that moment. The tables are derived from Hushy's notes and rebuilt from them, never
/// edited by hand.
enum MemorySchema {
    static let statements = [
        """
        CREATE TABLE meeting (
          note_id INTEGER PRIMARY KEY, title TEXT NOT NULL, start REAL NOT NULL, "end" REAL NOT NULL,
          series_key TEXT, is_internal INTEGER NOT NULL DEFAULT 0)
        """,
        """
        CREATE TABLE company (
          id INTEGER PRIMARY KEY, domain TEXT UNIQUE, name TEXT NOT NULL, is_own INTEGER NOT NULL DEFAULT 0)
        """,
        """
        CREATE TABLE person (
          id INTEGER PRIMARY KEY, key TEXT NOT NULL UNIQUE, name TEXT NOT NULL, company_id INTEGER REFERENCES company(id),
          is_self INTEGER NOT NULL DEFAULT 0)
        """,
        """
        CREATE TABLE meeting_person (
          note_id INTEGER NOT NULL REFERENCES meeting(note_id), person_id INTEGER NOT NULL REFERENCES person(id),
          role TEXT NOT NULL CHECK (role IN ('attendee', 'speaker', 'mentioned')), PRIMARY KEY (note_id, person_id, role))
        """,
        """
        CREATE TABLE meeting_company (
          note_id INTEGER NOT NULL REFERENCES meeting(note_id), company_id INTEGER NOT NULL REFERENCES company(id),
          via TEXT NOT NULL CHECK (via IN ('attendee', 'title', 'mentioned')), PRIMARY KEY (note_id, company_id, via))
        """,
        """
        CREATE TABLE turn (
          note_id INTEGER NOT NULL REFERENCES meeting(note_id), ordinal INTEGER NOT NULL, speaker TEXT,
          person_id INTEGER REFERENCES person(id), start_seconds REAL, text TEXT NOT NULL, PRIMARY KEY (note_id, ordinal))
        """,
        "CREATE VIRTUAL TABLE turn_fts USING fts5(stems, note_id UNINDEXED, ordinal UNINDEXED, tokenize = 'unicode61')",
        """
        CREATE TABLE decision (
          id INTEGER PRIMARY KEY, note_id INTEGER NOT NULL REFERENCES meeting(note_id), ordinal INTEGER NOT NULL,
          text TEXT NOT NULL, quote_turn INTEGER, superseded_by INTEGER REFERENCES decision(id))
        """,
        """
        CREATE TABLE action_item (
          id INTEGER PRIMARY KEY, note_id INTEGER NOT NULL REFERENCES meeting(note_id), ordinal INTEGER NOT NULL,
          owner_text TEXT NOT NULL, owner_person_id INTEGER REFERENCES person(id), task TEXT NOT NULL, due TEXT NOT NULL,
          status TEXT NOT NULL CHECK (status IN ('open', 'done', 'cancelled')), quote_turn INTEGER,
          closed_note_id INTEGER REFERENCES meeting(note_id), closed_turn INTEGER, duplicate_of INTEGER REFERENCES action_item(id))
        """,
        "CREATE VIRTUAL TABLE meeting_fts USING fts5(stems, note_id UNINDEXED, tokenize = 'unicode61')",
    ]

    static func create(_ db: Database) throws {
        for statement in statements { try db.execute(sql: statement) }
    }
}
