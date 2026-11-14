import Foundation

public struct MemoryIndex: Sendable, Equatable {
    public let entries: [MemoryEntry]
    public let terms: [MemoryEntry]
    public let forgottenKeys: Set<String>
    public let termsByKey: [String: [MemoryEntry]]
    public let termsByHearing: [String: [MemoryEntry]]
    public let termsByPhoneticKey: [String: [MemoryEntry]]
    public let termsBySkeleton: [String: [MemoryEntry]]
    public let stylesByApp: [String: [MemoryEntry]]
    public let correctionsByApp: [String: [MemoryEntry]]
    /// One per entry of `terms`, in the same order: the keys recall compares, computed here once.
    let recallKeys: [RecallKeys]
    let termPositionsByPhoneticKey: [String: [Int]]

    public init(entries: [MemoryEntry]) {
        self.entries = entries
        let forgottenKeys = Set(entries.filter { $0.kind == .forgotten }.map { Self.key($0.value) })
        // A word typed twice by hand is one word; the first line stands for it.
        var seen = forgottenKeys
        let terms = entries.filter { $0.kind == .term && seen.insert(Self.key($0.value)).inserted }
        let recallKeys = terms.map { RecallKeys(key: Self.key($0.value)) }
        let keyed = Array(zip(terms, recallKeys))
        self.forgottenKeys = forgottenKeys
        self.terms = terms
        self.recallKeys = recallKeys
        termPositionsByPhoneticKey = Dictionary(grouping: recallKeys.indices, by: { recallKeys[$0].phonetic })
        termsByKey = Dictionary(grouping: terms, by: { Self.key($0.value) })
        termsByHearing = Dictionary(grouping: terms.flatMap { entry in entry.heardAs.map { (Self.key($0), entry) } }, by: { $0.0 })
            .mapValues { $0.map { $0.1 } }
        termsByPhoneticKey = Dictionary(grouping: keyed, by: { $0.1.phonetic }).mapValues { $0.map { $0.0 } }
        termsBySkeleton = Dictionary(grouping: keyed, by: { CorrectionClassifier.skeleton($0.1.joined) })
            .mapValues { $0.map { $0.0 } }
        stylesByApp = Dictionary(grouping: entries.filter { $0.kind == .style }, by: { $0.appBundleID ?? "" })
        correctionsByApp = Dictionary(grouping: entries.filter { $0.kind == .correction }, by: { $0.appBundleID ?? "" })
    }

    public static func key(_ value: String) -> String {
        CorrectionAlignment.tokens(value).map(CorrectionAlignment.key).joined(separator: " ")
    }
}
