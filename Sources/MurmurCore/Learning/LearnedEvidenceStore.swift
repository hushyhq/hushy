import Foundation
import GRDB

extension Store {
    /// The learned terms whose heard spellings are worth watching for in a dictation made in `app`: terms still
    /// being judged, and terms active only in some apps (which `app` is not one of, so Hushy does not swap there).
    /// A term that is swapped everywhere never shows its heard spelling again, so there is nothing to watch.
    public func watchedTerms(app: String?) throws -> [WatchedTerm] {
        try writer.read { db in try Self.watchedTerms(app: app, db: db) }
    }

    static func watchedTerms(app: String?, db: Database) throws -> [WatchedTerm] {
        try LearnedItem.filter(Column("kind") == LearnedItem.Kind.term.rawValue && Column("appBundleID") == nil)
            .fetchAll(db)
            .filter { $0.status == .candidate || ($0.status == .active && !$0.applies(inApp: app)) }
            .compactMap { item in
                let heard = item.heardAs.map(VocabularySwap.key).filter { !$0.isEmpty }
                return heard.isEmpty ? nil : WatchedTerm(itemKey: item.key, heardKeys: Array(Set(heard)).sorted())
            }
    }

    /// Adds one "left alone" in `app` to each term in `keys` and judges the term again. Counts only. Nothing is
    /// written when the dictation was deleted, retried or watched again in the meantime. Returns the items it changed.
    @discardableResult
    public func recordLeftAlone(
        _ keys: Set<String>, app: String?, dictationID: Int64, at now: Date = Date(), policy: LearningPolicy = .standard,
        expectedInsertedText: String? = nil, expectedObservationGeneration: String? = nil
    ) throws -> [LearnedItem] {
        guard policy.useEvidence, !keys.isEmpty else { return [] }
        return try writer.write { db in
            if let expectedInsertedText {
                guard let row = try Dictation.fetchOne(db, key: dictationID),
                      row.status == .inserted, row.text == expectedInsertedText else { return [] }
            }
            if let expectedObservationGeneration,
               try String.fetchOne(db, sql: "SELECT generation FROM dictation_edit_observation WHERE dictationID = ?", arguments: [dictationID]) != expectedObservationGeneration { return [] }
            var changed: [LearnedItem] = []
            for item in try LearnedItem.filter(Column("kind") == LearnedItem.Kind.term.rawValue && Column("appBundleID") == nil).fetchAll(db)
            where keys.contains(item.key) && item.status != .forgotten {
                var updated = Learner.expose(item, app: app ?? "", now: now, policy: policy)
                try updated.update(db)
                changed.append(updated)
            }
            return changed
        }
    }

    /// What History says about a word that has just become a candidate: the dictations of the last
    /// `policy.backfillWindow` where Hushy wrote one of its heard spellings and the person left the whole dictation
    /// alone (`editState == .kept`), as "left alone" counts per app, faded by age. Counts only: the text is read
    /// here and dropped. A person with no History has no earlier evidence, and the term starts from its first fix.
    static func earlierLeftAlone(
        for item: LearnedItem, before now: Date, excluding dictationID: Int64, policy: LearningPolicy, db: Database
    ) -> [EvidenceCell] {
        let phrases = item.heardAs.map(VocabularySwap.key).filter { !$0.isEmpty }.map { $0.split(separator: " ").map(String.init) }
        guard let anchor = phrases.compactMap(\.first).first else { return [] }
        let since = now.addingTimeInterval(-policy.backfillWindow)
        let rows = (try? Row.fetchAll(db, sql: """
            SELECT text, appBundleID, createdAt FROM dictation
            WHERE status = 'inserted' AND editState = 'kept' AND id != ? AND createdAt >= ? AND createdAt < ?
              AND instr(lower(text), ?) > 0
            ORDER BY createdAt DESC LIMIT 2000
            """, arguments: [dictationID, since, now, anchor])) ?? []
        var byApp: [String: EvidenceCell] = [:]
        for row in rows {
            let text: String = row["text"]
            let keys = CorrectionAlignment.tokens(text).map(CorrectionAlignment.key).filter { !$0.isEmpty }
            guard phrases.contains(where: { ExposureDerivation.occurrences(of: $0, in: keys) > 0 }) else { continue }
            let when: Date = row["createdAt"]
            let app: String = row["appBundleID"] ?? ""
            let weight = EvidenceMath.weight(afterSeconds: now.timeIntervalSince(when), halfLife: policy.termHalfLife)
            var cell = byApp[app] ?? EvidenceCell(app: app, updatedAt: now)
            cell.kept += weight
            byApp[app] = cell
        }
        return byApp.values.sorted { $0.app < $1.app }
    }

    /// Dictations of the last `styleLookback` that the edit check saw left exactly as inserted, newest first.
    static func keptDictationRows(
        before now: Date, excluding dictationID: Int64, policy: LearningPolicy, db: Database
    ) throws -> [(text: String, app: String, at: Date)] {
        let since = now.addingTimeInterval(-policy.styleLookback)
        let rows = try Row.fetchAll(db, sql: """
            SELECT text, appBundleID, createdAt FROM dictation
            WHERE status = 'inserted' AND editState = 'kept' AND appBundleID IS NOT NULL AND id != ? AND createdAt >= ? AND createdAt < ?
            ORDER BY createdAt DESC LIMIT ?
            """, arguments: [dictationID, since, now, StyleHabitEvidence.historyLimit])
        return rows.map { row in (text: row["text"], app: row["appBundleID"], at: row["createdAt"]) }
    }
}
