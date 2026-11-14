import Foundation

/// Terms already known at key-down. This snapshot never persists screen or field text.
public struct TermEvidence: Sendable, Equatable {
    private let keys: Set<String>
    public static let none = TermEvidence(dictionary: [], screenTerms: [], appNames: [])

    public init(dictionary: [DictionaryEntry], screenTerms: [String], appNames: [String]) {
        keys = Set((dictionary.map(\.term) + screenTerms + appNames).map(MemoryIndex.key))
    }

    public func supports(_ typed: String) -> Bool { keys.contains(MemoryIndex.key(typed)) }
}
