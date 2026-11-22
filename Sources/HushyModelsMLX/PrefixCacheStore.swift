import Foundation
import MurmurCore

/// Which part of the prefix cache a prompt lives in.
enum PrefixSlot: Equatable, Sendable {
    /// Dictation cleanup's own prompts (the plain prompt and one per register line: 4 on the intent models). Only
    /// another cleanup prompt can evict one, so the next dictation after a voice action, a voice edit or a restyle
    /// finds its prefix warm.
    case pinned
    /// Everything else a person waits on: voice actions, voice edit and restyle, grammar, screen and own-stuff
    /// answers. They take turns in a small LRU of their own.
    case transient

    /// Cleanup's answer schemas mark its prompts: in the app only `SmartCleaner` asks for them, and the intent prompt
    /// builder keys on the same schema (`MLXLanguageModel.systemText`). A prefix built with a per-call adapter on is a
    /// different prefix from cleanup's, so it is never pinned.
    static func of(schemaName: String, adapterOn: Bool) -> PrefixSlot {
        guard !adapterOn, cleanupSchemaNames.contains(schemaName) else { return .transient }
        return .pinned
    }

    static let cleanupSchemaNames: Set<String> = [SmartCleaner.cleanedSchema.name, SmartCleaner.groupCleanedSchema.name]
}

/// What a cached prefix is filed under: the exact system text (instructions + schema block) and whether a per-call
/// adapter was on when it was prefilled (the KV state differs, so the two never share an entry).
struct PrefixKey: Hashable, Sendable {
    var system: String
    var adapterOn = false

    /// Where the prefix of `system`, asked for with `schema`, is filed (what `MLXEngine` looks up for every call).
    static func filing(system: String, schema: GenerationSchemaSpec, adapterOn: Bool) -> (key: PrefixKey, slot: PrefixSlot) {
        (PrefixKey(system: system, adapterOn: adapterOn), PrefixSlot.of(schemaName: schema.name, adapterOn: adapterOn))
    }
}

/// A small LRU of prefilled instruction prefixes, split in two partitions (`PrefixSlot`) that never evict each
/// other. Each entry is the token sequence of the prefix and whatever the backend keeps for it (the MLX engine stores
/// the layer caches). The store belongs to one loaded model, so a model change drops it wholesale (`removeAll`).
struct PrefixCacheStore<Entry> {
    private var pinned: LRU
    private var transient: LRU

    init(pinnedCapacity: Int, transientCapacity: Int) {
        pinned = LRU(capacity: max(1, pinnedCapacity))
        transient = LRU(capacity: max(0, transientCapacity))
    }

    var count: Int { pinned.keys.count + transient.keys.count }
    var capacity: Int { pinned.capacity + transient.capacity }

    /// The keys of `slot`, most recently used first.
    func keys(_ slot: PrefixSlot) -> [PrefixKey] { partition(slot).keys }

    /// Every entry, pinned first, each partition most recently used first, without changing the order.
    var allEntries: [Entry] { pinned.allEntries + transient.allEntries }

    /// The entry for `key` in `slot`, marking it most recently used there.
    mutating func entry(for key: PrefixKey, in slot: PrefixSlot) -> Entry? {
        switch slot {
        case .pinned: pinned.entry(for: key)
        case .transient: transient.entry(for: key)
        }
    }

    /// Inserts (or replaces) `entry` in `slot`; returns the keys evicted from that slot to stay within its capacity.
    /// A partition with no capacity keeps nothing.
    @discardableResult
    mutating func insert(_ entry: Entry, for key: PrefixKey, in slot: PrefixSlot) -> [PrefixKey] {
        switch slot {
        case .pinned: pinned.insert(entry, for: key)
        case .transient: transient.insert(entry, for: key)
        }
    }

    mutating func removeAll() {
        pinned.removeAll()
        transient.removeAll()
    }

    private func partition(_ slot: PrefixSlot) -> LRU {
        switch slot {
        case .pinned: pinned
        case .transient: transient
        }
    }

    private struct LRU {
        let capacity: Int
        private(set) var keys: [PrefixKey] = []
        private var entries: [PrefixKey: Entry] = [:]

        init(capacity: Int) { self.capacity = capacity }

        var allEntries: [Entry] { keys.compactMap { entries[$0] } }

        mutating func entry(for key: PrefixKey) -> Entry? {
            guard let entry = entries[key] else { return nil }
            touch(key)
            return entry
        }

        mutating func insert(_ entry: Entry, for key: PrefixKey) -> [PrefixKey] {
            entries[key] = entry
            touch(key)
            var evicted: [PrefixKey] = []
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

        private mutating func touch(_ key: PrefixKey) {
            keys.removeAll { $0 == key }
            keys.insert(key, at: 0)
        }
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
    /// The cached entry for `key` in `slot`, or one `build` makes and caches there. `built` tells which. Nil when
    /// `policy` is `.background` (nothing touched, `build` not called) or when `build` has nothing to cache.
    mutating func resolve(
        _ key: PrefixKey, slot: PrefixSlot, policy: PrefixPolicy, build: () throws -> Entry?
    ) rethrows -> (entry: Entry, built: Bool)? {
        guard policy != .background else { return nil }
        if let cached = entry(for: key, in: slot) { return (cached, false) }
        guard let built = try build() else { return nil }
        insert(built, for: key, in: slot)
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
