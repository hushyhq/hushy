import Foundation
import MurmurCore
import Testing
@testable import HushyModelsMLX

/// What a meeting summary's calls (`LanguageModelOptions.isBackground`) do to the prefixes dictation keeps warm
/// (`PrefixCacheStore.resolve`, the step `MLXEngine.prefix` goes through for every call).
@Suite("Background calls and the dictation prefix cache")
struct MLXBackgroundPrefixTests {
    private let dictationPrompts = ["cleanup", "cleanup+variant", "cleanup+professional", "cleanup+casual"]

    private func key(_ prompt: String) -> PrefixKey { PrefixKey(system: prompt) }

    private func warmedStore() -> (PrefixCacheStore<Int>, builds: Counter) {
        var store = PrefixCacheStore<Int>(pinnedCapacity: 4, transientCapacity: 2)
        let counter = Counter()
        for (index, prompt) in dictationPrompts.enumerated() {
            _ = store.resolve(key(prompt), slot: .pinned, policy: .dictation) { counter.builds += 1; return index }
        }
        return (store, counter)
    }

    private final class Counter { var builds = 0 }

    @Test("a long meeting's piece and merge calls leave the dictation prefixes and their order alone")
    func backgroundCallsLeaveTheCacheAlone() {
        var (store, counter) = warmedStore()
        let before = store.keys(.pinned)
        #expect(before.count == 4, "dictation holds all four cleanup slots")

        for (prompt, slot) in [("meeting-piece", PrefixSlot.transient), ("meeting-merge", .transient),
                               ("meeting-piece", .transient), ("cleanup+casual", .pinned), ("cleanup", .pinned)] {
            let resolved = store.resolve(key(prompt), slot: slot, policy: .background) { counter.builds += 1; return -1 }
            #expect(resolved == nil, "a background call prefills its own prompt")
        }

        #expect(store.keys(.pinned) == before, "nothing added, evicted or reordered, even when a prompt matches a dictation's")
        #expect(store.keys(.transient).isEmpty, "and background calls take no transient slot either")
        #expect(counter.builds == 4, "and no prefix was built for them")
    }

    @Test("the next Professional dictation after a summary still finds its prefix warm")
    func dictationStaysWarm() {
        var (store, counter) = warmedStore()
        _ = store.resolve(key("meeting-piece"), slot: .transient, policy: .background) { counter.builds += 1; return -1 }
        _ = store.resolve(key("meeting-merge"), slot: .transient, policy: .background) { counter.builds += 1; return -1 }

        for (index, prompt) in dictationPrompts.enumerated() {
            let resolved = store.resolve(key(prompt), slot: .pinned, policy: .dictation) { counter.builds += 1; return -1 }
            #expect(resolved?.built == false, "\(prompt) is a hit, not a rebuild after the key release")
            #expect(resolved?.entry == index)
        }
        #expect(counter.builds == 4)
    }

    @Test("a fifth cleanup prompt still caches, and evicts the least recently used cleanup prompt")
    func dictationStillCaches() {
        var (store, _) = warmedStore()
        let resolved = store.resolve(key("cleanup+prompt"), slot: .pinned, policy: .dictation) { 9 }
        #expect(resolved?.built == true)
        #expect(store.keys(.pinned) == ["cleanup+prompt", "cleanup+casual", "cleanup+professional", "cleanup+variant"].map(key))
    }

    @Test("a prefix with nothing to cache is not stored")
    func emptyBuildIsNotStored() {
        var store = PrefixCacheStore<Int>(pinnedCapacity: 2, transientCapacity: 2)
        #expect(store.resolve(key("empty"), slot: .pinned, policy: .dictation) { nil } == nil)
        #expect(store.count == 0)
    }
}
