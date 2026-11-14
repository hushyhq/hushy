import Foundation
import GRDB

// MARK: - Learned items (on-device learn-from-corrections)

/// What folding one capture into the learned items did. Counts only.
public struct CorrectionRecord: Sendable, Equatable {
    /// Why nothing was written.
    public enum Skip: String, Sendable, Equatable {
        /// The dictation was deleted, retried or watched again in the meantime.
        case stale
        /// The person's own Dictionary already has the word with that hearing.
        case known
        /// The person told Hushy to forget it.
        case forgotten
        /// The capture held nothing that is stored (a formatting change with no app, for one).
        case nothing
    }

    public struct Progress: Sendable, Equatable {
        public let seen: Int
        public let needed: Int
    }

    /// Items that came into use because of this capture.
    public var activated: [LearnedItem] = []
    /// Items written, in use or not.
    public var written = 0
    public var keptHeard = 0
    public var reactivatedHeard = 0
    /// The candidate nearest to being used, when one was written.
    public var progress: Progress?
    public var skip: Skip?
}

extension Store {
    /// Folds one capture into the learned items in a single transaction and returns the items
    /// that became active because of it (for the "Learned from your edits" notice). With the
    /// default policy terms never activate here — only `confirmLearnedItem` does that.
    @discardableResult
    public func recordCorrections(
        _ capture: CorrectionCapture, policy: LearningPolicy = .standard, expectedInsertedText: String? = nil, expectedObservationGeneration: String? = nil
    ) throws -> [LearnedItem] {
        try reportCorrections(capture, policy: policy, expectedInsertedText: expectedInsertedText,
                              expectedObservationGeneration: expectedObservationGeneration).activated
    }

    /// `recordCorrections`, with what it wrote and why it wrote nothing (for the `learning` log line).
    public func reportCorrections(
        _ capture: CorrectionCapture, policy: LearningPolicy = .standard, expectedInsertedText: String? = nil, expectedObservationGeneration: String? = nil
    ) throws -> CorrectionRecord {
        try writer.write { db in
            if let expectedInsertedText {
                guard let row = try Dictation.fetchOne(db, key: capture.dictationID),
                      row.status == .inserted, row.text == expectedInsertedText else { return CorrectionRecord(skip: .stale) }
            }
            if let expectedObservationGeneration,
               try String.fetchOne(db, sql: "SELECT generation FROM dictation_edit_observation WHERE dictationID = ?", arguments: [capture.dictationID]) != expectedObservationGeneration { return CorrectionRecord(skip: .stale) }
            let dictionary = try DictionaryEntry.fetchAll(db)
            let knownTerms = Set(dictionary.map { $0.term.lowercased() })
            let knownHearings = Dictionary(
                dictionary.map { ($0.term.lowercased(), Set($0.soundsLike.map(Learner.listedKey))) },
                uniquingKeysWith: { $0.union($1) })
            let existing = try LearnedItem.fetchAll(db)
            let wasActive = Set(existing.filter { $0.status == .active }.map(\.identity))
            var record = CorrectionRecord()
            if let app = capture.appBundleID, !capture.reverts.isEmpty {
                let forgotten = Set(try KeepHeardEntry.filter(Column("appBundleID") == app && Column("status") == KeepHeardEntry.Status.forgotten.rawValue)
                    .fetchAll(db).compactMap(\.id))
                let kept = try Self.recordReverts(capture.reverts, app: app, at: capture.capturedAt, db: db)
                record.keptHeard = kept.count
                record.reactivatedHeard = Set(kept.compactMap(\.id)).intersection(forgotten).count
            }
            let earlier: (LearnedItem) -> [EvidenceCell] = { item in
                Self.earlierLeftAlone(for: item, before: capture.capturedAt, excluding: capture.dictationID, policy: policy, db: db)
            }
            let hasHabits = Learner.observations(from: capture).contains { $0.kind == .styleSignal }
            let keptRows = policy.useEvidence && hasHabits
                ? try Self.keptDictationRows(before: capture.capturedAt, excluding: capture.dictationID, policy: policy, db: db) : []
            let styleKept: (String) -> [EvidenceCell] = { key in
                StyleHabitEvidence.keptCells(for: key, rows: keptRows, now: capture.capturedAt, halfLife: policy.styleHalfLife)
            }
            for item in Learner.observe(capture, existing: existing, knownTerms: knownTerms, knownHearings: knownHearings, policy: policy,
                                        backfill: earlier, styleKept: styleKept) {
                var copy = item
                try copy.save(db)
                record.written += 1
                if copy.status == .active, !wasActive.contains(copy.identity) { record.activated.append(copy) }
                let progress = Learner.progress(of: copy, now: capture.capturedAt, policy: policy)
                // The candidate nearest to being used speaks for the capture.
                if copy.status == .candidate, record.progress.map({ progress.seen * $0.needed > $0.seen * progress.needed }) ?? true {
                    record.progress = CorrectionRecord.Progress(seen: progress.seen, needed: progress.needed)
                }
            }
            if record.written == 0 && record.keptHeard == 0 {
                let observed = Learner.observations(from: capture)
                let forgotten = Set(existing.filter { $0.status == .forgotten }.map(\.identity))
                let isForgotten = observed.contains {
                    forgotten.contains(LearnedItem.identity(kind: $0.kind, key: $0.key, appBundleID: $0.appBundleID))
                }
                record.skip = observed.isEmpty ? .nothing : (isForgotten ? .forgotten : .known)
            }
            return record
        }
    }

    /// All learned items (including forgotten tombstones), newest first.
    public func learnedItems() throws -> [LearnedItem] {
        try writer.read { db in try Self.learnedItems(db) }
    }

    public static func learnedItems(_ db: Database) throws -> [LearnedItem] {
        try LearnedItem.order(Column("lastSeenAt").desc).fetchAll(db)
    }

    /// Accepts a suggestion: the item becomes active now (no second edit needed).
    @discardableResult
    public func confirmLearnedItem(id: Int64, now: Date = Date()) throws -> LearnedItem? {
        try updateLearnedItem(id: id) { Learner.confirm($0, now: now) }
    }

    /// Undo / Forget: stops using the item and deletes its evidence. The same edits will not
    /// teach it again; `deleteAllLearnedItems()` removes the tombstone too.
    @discardableResult
    public func forgetLearnedItem(id: Int64) throws -> LearnedItem? {
        discardPreMeetingsBackup()
        return try updateLearnedItem(id: id, Learner.forget)
    }

    /// Marks items as shown in the "Learned from your edits" notice.
    public func markLearnedItemsAnnounced(ids: [Int64]) throws {
        guard !ids.isEmpty else { return }
        try writer.write { db in
            _ = try LearnedItem.filter(ids.contains(Column("id"))).updateAll(db, Column("announced").set(to: true))
        }
    }

    /// Deletes every learned item, tombstones included ("Delete learning data").
    public func deleteAllLearnedItems() throws {
        discardPreMeetingsBackup()
        try writer.write { db in
            try db.execute(sql: "DELETE FROM learnedTermReview")
            _ = try LearnedItem.deleteAll(db)
            _ = try KeepHeardEntry.deleteAll(db)
        }
    }

    private func updateLearnedItem(id: Int64, _ transform: @escaping @Sendable (LearnedItem) -> LearnedItem) throws -> LearnedItem? {
        try writer.write { db in
            guard let item = try LearnedItem.fetchOne(db, key: id) else { return nil }
            let updated = transform(item)
            try updated.update(db)
            return updated
        }
    }
}
