import Foundation
import GRDB

/// Facts kept tied to the turns they quote, and the note's legacy action-item columns kept as a cache of them for the
/// readers that still read those columns this release (Home's open items, the Notes list, cross-meeting memory).
extension Store {
    // MARK: - Re-resolving evidence

    /// After the note's turns were replaced (re-assembly, a retry), each fact with a quote is tied again to the turn
    /// that now holds it: the new turn ids differ, so `evidenceTurnId` (cleared by its foreign key) is found again
    /// from the quote and the old playback time. A quote no longer found leaves the fact without a turn link, never
    /// with a wrong one; its playback time stays, since re-assembly never moves the audio. A shown owner that was a
    /// speaker label gets that speaker's new id.
    static func reresolveFactEvidence(_ db: Database, noteId: Int64, transcript: NoteTranscript) throws {
        let facts = try MeetingFact.filter(Column("noteId") == noteId).fetchAll(db)
        guard !facts.isEmpty else { return }
        let lines = MeetingExtractPrompt.lines(of: transcript)
        let speakers = MeetingFactExtractor.speakers(of: transcript)
        for var fact in facts {
            let before = fact
            if let quote = fact.quote, !quote.isEmpty {
                let found = lines.compactMap { MeetingFactGrounder.locate(quote, in: [$0]) }
                let nearest = found.min { a, b in
                    distance(a.turn, to: fact.t0) < distance(b.turn, to: fact.t0)
                }
                fact.evidenceTurnId = nearest?.turn.id
                fact.evidenceStart = nearest?.start
                fact.evidenceEnd = nearest?.end
                if let nearest, fact.t0 == nil { (fact.t0, fact.t1) = MeetingFactGrounder.span(nearest) }
            }
            if let owner = fact.ownerText {
                fact.ownerSpeakerId = speakers.first { $0.label.caseInsensitiveCompare(owner) == .orderedSame }?.speakerId
            }
            if fact != before { try fact.update(db) }
        }
    }

    private static func distance(_ turn: NoteTurn, to seconds: Double?) -> Double {
        guard let seconds, let t0 = turn.t0 else { return 0 }
        let end = turn.t1 ?? t0
        return seconds < t0 ? t0 - seconds : seconds > end ? seconds - end : 0
    }

    // MARK: - Writing a new extraction

    /// `replaceModelFacts`, then the legacy action-item columns and check-offs rewritten from the visible actions.
    @discardableResult
    public func replaceModelFactsAndCache(noteId: Int64, extractor: String, facts: [MeetingFact], now: Date = Date()) throws -> [MeetingFact] {
        // A legacy note summarized again: the items backfilled from its old columns give way to the new extraction,
        // except the ones the person checked off or edited.
        try writer.write { db in
            try db.execute(sql: """
                DELETE FROM meeting_fact WHERE noteId = ? AND origin = 'legacy' AND userEdited = 0 AND status = 'open'
                """, arguments: [noteId])
        }
        let inserted = try replaceModelFacts(noteId: noteId, extractor: extractor, facts: facts, now: now)
        try writer.write { db in try Self.cacheLegacyActionItems(db, noteId: noteId, force: true) }
        return inserted
    }

    /// The note's visible facts in reading order, from a read the caller holds.
    static func visibleFacts(_ db: Database, noteId: Int64) throws -> [MeetingFact] {
        try MeetingFact.filter(Column("noteId") == noteId).filter(MeetingFact.visible)
            .order(Column("ordinal"), Column("id")).fetchAll(db)
    }

    /// Whether the note's facts came from an extraction (any model fact), as opposed to a legacy note whose facts were
    /// backfilled from its own columns, which stay exactly as they were.
    static func hasModelFacts(_ db: Database, noteId: Int64) throws -> Bool {
        try Bool.fetchOne(db, sql: "SELECT EXISTS(SELECT 1 FROM meeting_fact WHERE noteId = ? AND origin = 'model')",
                          arguments: [noteId]) ?? false
    }

    /// `note.actionItems`, `actionItemDetails` and the index-keyed check-offs, rebuilt from the visible actions in
    /// order. Only for a note with model facts, or after an extraction (`force`), which may have found none.
    static func cacheLegacyActionItems(_ db: Database, noteId: Int64, force: Bool = false) throws {
        guard try force || hasModelFacts(db, noteId: noteId), var note = try Note.fetchOne(db, key: noteId) else { return }
        let actions = try visibleFacts(db, noteId: noteId).filter { $0.kind == .action }
        let details = actions.map(MeetingFactText.detail)
        note.setActionItems(details.map(\.line), details: details)
        try note.update(db, columns: ["actionItems", "actionItemDetails"])
        try NoteActionItemStatus.filter(Column("noteId") == noteId).deleteAll(db)
        for (index, fact) in actions.enumerated() where fact.status == .done {
            try NoteActionItemStatus(noteId: noteId, itemIndex: index, isDone: true, updatedAt: fact.statusAt ?? Date()).insert(db)
        }
    }

    /// The action fact behind legacy item `index`: its place among the visible actions for an extracted note, its
    /// ordinal for a legacy note (whose backfill numbered them by index).
    static func actionFact(_ db: Database, noteId: Int64, index: Int) throws -> MeetingFact? {
        if try hasModelFacts(db, noteId: noteId) {
            let actions = try visibleFacts(db, noteId: noteId).filter { $0.kind == .action }
            return actions.indices.contains(index) ? actions[index] : nil
        }
        return try MeetingFact.filter(Column("noteId") == noteId && Column("kind") == MeetingFact.Kind.action.rawValue
                                      && Column("ordinal") == index && Column("origin") == MeetingFact.Origin.legacy.rawValue).fetchOne(db)
    }

    // MARK: - Check-offs

    /// Checks an action off (or reopens it) by its fact, and keeps the legacy check-off of the same item in step.
    @discardableResult
    public func setActionFactDone(uuid: String, isDone: Bool, at now: Date = Date()) throws -> Bool {
        try writer.write { db in
            guard var fact = try MeetingFact.filter(Column("uuid") == uuid).fetchOne(db) else { return false }
            fact.status = isDone ? .done : .open
            fact.statusAt = isDone ? now : nil
            fact.updatedAt = now
            try fact.update(db)
            if try Self.hasModelFacts(db, noteId: fact.noteId) {
                try Self.cacheLegacyActionItems(db, noteId: fact.noteId)
            } else if fact.origin == .legacy, fact.kind == .action {
                if isDone {
                    try NoteActionItemStatus(noteId: fact.noteId, itemIndex: fact.ordinal, isDone: true).save(db)
                } else {
                    try NoteActionItemStatus.deleteOne(db, key: ["noteId": fact.noteId, "itemIndex": fact.ordinal])
                }
            }
            return true
        }
    }

    // MARK: - Scorecard

    /// Counts only, per extractor, for the trust page and the on-device self-check (schema freeze section 5). The
    /// drop rate is a self-check, not a gold-scored rate.
    public struct FactScore: Sendable, Equatable {
        public var extractor: String
        public var modelFacts: Int
        public var unsupported: Int
        public var ownersClaimed: Int
        public var ownersDropped: Int
        public var visible: Int
        public var visibleWithEvidence: Int
        public var dismissed: Int
        public var edited: Int
    }

    public func factScorecard() throws -> [FactScore] {
        try writer.read { db in
            try Row.fetchAll(db, sql: """
                SELECT extractor,
                       SUM(origin = 'model') AS modelFacts,
                       SUM(origin = 'model' AND grounding = 'unsupported') AS unsupported,
                       SUM(ownerClaim IS NOT NULL) AS ownersClaimed,
                       SUM(ownerClaim IS NOT NULL AND ownerText IS NULL) AS ownersDropped,
                       SUM(\(MeetingFact.visibleCondition)) AS visible,
                       SUM((\(MeetingFact.visibleCondition)) AND quote IS NOT NULL AND t0 IS NOT NULL) AS visibleWithEvidence,
                       SUM(status = 'dismissed') AS dismissed,
                       SUM(userEdited) AS edited
                FROM meeting_fact GROUP BY extractor ORDER BY extractor
                """).map { row in
                FactScore(extractor: row["extractor"], modelFacts: row["modelFacts"] ?? 0, unsupported: row["unsupported"] ?? 0,
                          ownersClaimed: row["ownersClaimed"] ?? 0, ownersDropped: row["ownersDropped"] ?? 0,
                          visible: row["visible"] ?? 0, visibleWithEvidence: row["visibleWithEvidence"] ?? 0,
                          dismissed: row["dismissed"] ?? 0, edited: row["edited"] ?? 0)
            }
        }
    }
}
