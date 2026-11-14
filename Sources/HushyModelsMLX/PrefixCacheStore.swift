import Foundation
import MurmurCore

/// A small LRU of prefilled instruction prefixes, keyed by the exact system text (instructions +
/// schema block). Each entry is the token sequence of the prefix and whatever the backend keeps
/// for it (the MLX engine stores the layer caches). The store belongs to one loaded model, so a
/// model change drops it wholesale (`removeAll`).
struct PrefixCacheStore<Entry> {
    let capacity: Int
    private(set) var keys: [String] = []
    private var entries: [String: Entry] = [:]

    init(capacity: Int) {
        self.capacity = max(1, capacity)
    }

    var count: Int { keys.count }

    /// Every entry, most recently used first, without changing the order.
    var allEntries: [Entry] { keys.compactMap { entries[$0] } }

    /// The entry for `key`, marking it most recently used.
    mutating func entry(for key: String) -> Entry? {
        guard let entry = entries[key] else { return nil }
        touch(key)
        return entry
    }

    /// Inserts (or replaces) `entry`; returns the keys evicted to stay within `capacity`.
    @discardableResult
    mutating func insert(_ entry: Entry, for key: String) -> [String] {
        entries[key] = entry
        touch(key)
        var evicted: [String] = []
        while keys.count > capacity, let oldest = keys.last {
            keys.removeLast()
            entries[oldest] = nil
            evicted.append(oldest)
        }
        return evicted
    }

    mutating func removeAll() {
        keys.removeAll()
        entries.removeAll()
    }

    private mutating func touch(_ key: String) {
        keys.removeAll { $0 == key }
        keys.insert(key, at: 0)
    }
}

/// What a call does with the dictation prefix cache, and what its prefix build does when the caller is cancelled.
enum PrefixPolicy: Equatable, Sendable {
    /// Runs to the end whatever happens to its caller (warm-ups).
    case warmUp
    /// A dictation's own prompts: cached, and a cancelled build stops between chunks, then builds the prefix again
    /// off the caller's clock so the next call with these instructions is warm.
    case dictation
    /// Work no one is waiting on (`LanguageModelOptions.isBackground`: a meeting summary). A bystander to the cache:
    /// it never reads, adds or evicts, so the prompts dictation keeps warm stay warm, and the call prefills its own
    /// prompt. Meeting prompts are 5-30 s calls whose prefix is a fifth of their prompt, so a hit would save under a
    /// second; a cache slot of their own would hold another prefix in memory beside the model for that.
    case background

    init(_ options: LanguageModelOptions) {
        self = options.isBackground ? .background : .dictation
    }
}

extension PrefixCacheStore {
    /// The cached entry for `key`, or one `build` makes and caches. `built` tells which. Nil when `policy` is
    /// `.background` (nothing touched, `build` not called) or when `build` has nothing to cache.
    mutating func resolve(_ key: String, policy: PrefixPolicy, build: () throws -> Entry?) rethrows -> (entry: Entry, built: Bool)? {
        guard policy != .background else { return nil }
        if let cached = entry(for: key) { return (cached, false) }
        guard let built = try build() else { return nil }
        insert(built, for: key)
        return (built, true)
    }
}

/// How a call's full prompt reuses a cached prefix.
enum PrefixReuse: Equatable {
    /// The prompt starts with the whole prefix: feed only `suffixStart...`.
    case full(suffixStart: Int)
    /// Only the first `length` tokens match; a trimmable cache can drop the rest and resume there.
    case partial(length: Int)
    /// Nothing usable: prefill the whole prompt.
    case none

    static func plan(prefix: [Int], prompt: [Int]) -> PrefixReuse {
        guard !prefix.isEmpty else { return .none }
        let shared = commonPrefixLength(prefix, prompt)
        if shared == prefix.count, shared < prompt.count { return .full(suffixStart: shared) }
        // Leave at least one prompt token to feed, so there is always a distribution to decode from.
        let usable = min(shared, prompt.count - 1)
        return usable > 0 ? .partial(length: usable) : .none
    }

    static func commonPrefixLength(_ a: [Int], _ b: [Int]) -> Int {
        var length = 0
        for (x, y) in zip(a, b) {
            guard x == y else { break }
            length += 1
        }
        return length
    }
}
