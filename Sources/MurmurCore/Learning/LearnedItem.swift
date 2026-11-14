import Foundation
import GRDB

/// Something Hushy learned from the user's edits: a vocabulary term (with how it was misheard)
/// or a per-app style signal. Every item keeps its provenance and can be forgotten; a forgotten
/// item stays as a tombstone so the same edit never re-teaches it.
public struct LearnedItem: Codable, Sendable, Equatable, Identifiable, Hashable {
    public enum Kind: String, Codable, Sendable, CaseIterable {
        /// A name/term: boosted in ASR, applied as a replacement for safe misrecognitions, and
        /// protected from model rewrites.
        case term
        /// A per-app formatting/cleanup habit, exposed as a preference hint only.
        case styleSignal
    }

    public enum Status: String, Codable, Sendable, CaseIterable {
        /// Seen, not yet trusted: shown as a suggestion ("Add Kubernetes to your dictionary?").
        case candidate
        /// In use: fed to boosting, replacements and guards.
        case active
        /// The user said no (Undo / Forget). Never re-learned from edits.
        case forgotten
    }

    public static let maxProvenance = 20

    public var id: Int64?
    public var kind: Kind
    /// Unique per kind+app: the lowercased term, or "<signal>" for a style signal.
    public var key: String
    /// The canonical spelling to use ("Priya"), or the signal name ("lowercased", "keep:actually").
    public var value: String
    /// How the recognizer rendered the term, most recent last ("Pria", "Preeya").
    public var heardAs: [String]
    /// The app a style signal or case-only term belongs to; nil for global term corrections.
    public var appBundleID: String?
    public var status: Status
    /// Total times this was observed in edits.
    public var observations: Int
    /// The user explicitly confirmed it (from a suggestion), bypassing the repetition threshold.
    public var confirmed: Bool
    /// 0…1: how sure we are (observations inside the window over the threshold; 1 when confirmed).
    public var confidence: Double
    /// Dictation rows the evidence came from (most recent `maxProvenance`).
    public var sourceDictationIDs: [Int64]
    /// Observation times (most recent `maxProvenance`), for the "N times within D days" rule.
    public var observedAt: [Date]
    public var createdAt: Date
    public var lastSeenAt: Date
    public var activatedAt: Date?
    /// True once the UI has told the user about this item becoming active ("Learned from your
    /// edits: Priya · Undo"). Items the user hasn't been told about are what the notice shows.
    public var announced: Bool
    /// Two decayed counts per app: times the person changed the word and times they left it as
    /// heard (`EvidenceCell`). Empty for rows written before the counts existed; `Learner` then
    /// reads the evidence from `observedAt`. Counts only, never text.
    public var evidence: [EvidenceCell]
    /// Where an active term applies (`LearnedScope.stored`); nil means everywhere, which is what every
    /// term did before scopes existed.
    public var scopeStored: String?

    public init(
        id: Int64? = nil, kind: Kind, key: String, value: String, heardAs: [String] = [],
        appBundleID: String? = nil, status: Status = .candidate, observations: Int = 0, confirmed: Bool = false,
        confidence: Double = 0, sourceDictationIDs: [Int64] = [], observedAt: [Date] = [],
        createdAt: Date = Date(), lastSeenAt: Date = Date(), activatedAt: Date? = nil, announced: Bool = false,
        evidence: [EvidenceCell] = [], scope: LearnedScope? = nil
    ) {
        self.id = id
        self.kind = kind
        self.key = key
        self.value = value
        self.heardAs = heardAs
        self.appBundleID = appBundleID
        self.status = status
        self.observations = observations
        self.confirmed = confirmed
        self.confidence = confidence
        self.sourceDictationIDs = sourceDictationIDs
        self.observedAt = observedAt
        self.createdAt = createdAt
        self.lastSeenAt = lastSeenAt
        self.activatedAt = activatedAt
        self.announced = announced
        self.evidence = evidence
        self.scopeStored = scope?.stored
    }

    /// A suggestion with enough evidence to have activated on its own (e.g. 2 fixes in 14 days)
    /// if auto-activation were on: the UI should offer it first ("Add Priya? You fixed it twice").
    public var isReadySuggestion: Bool { status == .candidate && confidence >= 1 }

    /// Where this term applies. A term tied to one app by its identity (`appBundleID`, a casing habit) stays
    /// with that app; every other term is global unless evidence narrowed it.
    public var scope: LearnedScope {
        get {
            if let appBundleID { return .app(appBundleID) }
            return scopeStored.flatMap(LearnedScope.init(stored:)) ?? .global
        }
        set { scopeStored = newValue == .global ? nil : newValue.stored }
    }

    /// Applies everywhere: the terms every dictation gets.
    public var isGlobal: Bool { scope == .global }

    /// Whether this item is used in `app` (nil = no app known).
    public func applies(inApp app: String?) -> Bool { scope.applies(inApp: app) }

    /// For the dictionary lists: with no app, the terms that apply everywhere; with an app, the narrower terms that apply in it.
    func isUsed(inApp app: String?) -> Bool {
        guard let app else { return isGlobal }
        return !isGlobal && applies(inApp: app)
    }

    /// Identity used to merge a new observation into an existing row.
    public var identity: String { Self.identity(kind: kind, key: key, appBundleID: appBundleID) }

    public static func identity(kind: Kind, key: String, appBundleID: String?) -> String {
        "\(kind.rawValue)|\(appBundleID ?? "*")|\(key)"
    }
}

extension LearnedItem: FetchableRecord, MutablePersistableRecord {
    public static let databaseTableName = "learnedItem"

    public mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }
}

extension LearnedItem.Kind: DatabaseValueConvertible {}
extension LearnedItem.Status: DatabaseValueConvertible {}

/// Schema for learned items (migration "v14-learned-items"). Add-only.
enum LearnedItemSchema {
    static func migrate(_ db: Database) throws {
        try db.create(table: "learnedItem") { t in
            t.autoIncrementedPrimaryKey("id")
            t.column("kind", .text).notNull()
            t.column("key", .text).notNull()
            t.column("value", .text).notNull()
            t.column("heardAs", .jsonText).notNull()
            t.column("appBundleID", .text)
            t.column("status", .text).notNull()
            t.column("observations", .integer).notNull().defaults(to: 0)
            t.column("confirmed", .boolean).notNull().defaults(to: false)
            t.column("confidence", .double).notNull().defaults(to: 0)
            t.column("sourceDictationIDs", .jsonText).notNull()
            t.column("observedAt", .jsonText).notNull()
            t.column("createdAt", .datetime).notNull()
            t.column("lastSeenAt", .datetime).notNull()
            t.column("activatedAt", .datetime)
            t.column("announced", .boolean).notNull().defaults(to: false)
        }
        // IFNULL so "applies everywhere" (NULL app) is one value — SQLite treats NULLs as distinct.
        try db.execute(sql: "CREATE UNIQUE INDEX learnedItem_identity ON learnedItem(kind, IFNULL(appBundleID, ''), key)")
        try db.create(index: "learnedItem_status", on: "learnedItem", columns: ["status"])
    }
}

extension LearnedItemSchema {
    /// Migration "v25-learned-evidence": the two counts per app and the scope an active term applies in. Add-only
    /// (columns with defaults), so rows written by older builds read back unchanged: no counts, applies everywhere.
    static func migrateEvidence(_ db: Database) throws {
        try db.alter(table: "learnedItem") { t in
            t.add(column: "evidence", .jsonText).notNull().defaults(to: "[]")
            t.add(column: "scopeStored", .text)
        }
    }
}
