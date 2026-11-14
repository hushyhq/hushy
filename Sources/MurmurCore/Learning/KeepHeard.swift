import Foundation
import GRDB

public struct KeepHeardEntry: Codable, Sendable, Equatable, Identifiable, FetchableRecord, MutablePersistableRecord {
    public enum Status: String, Codable, Sendable { case active, forgotten }
    public static let databaseTableName = "keepHeard"
    public var id: Int64?
    public var appBundleID: String
    public var heardKey: String
    public var writtenKey: String
    public var heard: String
    public var written: String
    public var source: String
    public var status: Status
    public var observations: Int
    public var createdAt: Date
    public var lastSeenAt: Date

    public init(id: Int64? = nil, appBundleID: String, heardKey: String, writtenKey: String,
                heard: String, written: String, source: String, status: Status = .active,
                observations: Int = 1, createdAt: Date = Date(), lastSeenAt: Date = Date()) {
        self.id = id
        self.appBundleID = appBundleID
        self.heardKey = heardKey
        self.writtenKey = writtenKey
        self.heard = heard
        self.written = written
        self.source = source
        self.status = status
        self.observations = observations
        self.createdAt = createdAt
        self.lastSeenAt = lastSeenAt
    }

    public mutating func didInsert(_ inserted: InsertionSuccess) { id = inserted.rowID }
}

/// Active replacement pairs for one app; loaded before dictation, never on the paste path.
public struct KeepHeardSet: Sendable, Equatable {
    private let pairs: Set<Pair>
    private struct Pair: Sendable, Hashable { let heard: String; let written: String }
    public static let empty = KeepHeardSet(swaps: [])

    public init(swaps: [VocabularySwap]) {
        pairs = Set(swaps.map { Pair(heard: $0.heardKey, written: $0.writtenKey) })
    }

    public init(entries: [KeepHeardEntry]) {
        pairs = Set(entries.filter { $0.status == .active }.map { Pair(heard: $0.heardKey, written: $0.writtenKey) })
    }

    /// Only explicit pairs may be restored inside a larger model rewrite.
    var blockedPairs: [(heard: [String], written: [String])] {
        pairs.map { (heard: $0.heard.split(separator: " ").map(String.init),
                     written: $0.written.split(separator: " ").map(String.init)) }
            .sorted {
                if $0.written.count != $1.written.count { return $0.written.count > $1.written.count }
                if $0.heard.count != $1.heard.count { return $0.heard.count > $1.heard.count }
                return $0.written.joined(separator: " ") + $0.heard.joined(separator: " ")
                    < $1.written.joined(separator: " ") + $1.heard.joined(separator: " ")
            }
    }

    public var isEmpty: Bool { pairs.isEmpty }

    public func blocks(heardKey: String, writtenKey: String) -> Bool {
        pairs.contains(Pair(heard: heardKey, written: writtenKey))
    }
}
