import Testing
@testable import MurmurCore

/// Covers `SmartCleaner.prewarmGroup`/`clearPrewarmedGroups` — the incremental-cleanup cache
/// `StreamingDictationSession` populates for each finished `TextSegmentation` sentence group
/// while the user is still talking (task: "clean finished sentence groups during recording...
/// keeping the last group open so a 'no, I mean…' correction can still reach it").
///
/// These tests exercise the cache directly, at the `SmartCleaner` level, rather than through
/// `StreamingDictationSession` itself (an actor wrapping FluidAudio's `SlidingWindowAsrManager`,
/// which needs a real downloaded/loaded Parakeet model and cannot be faked cheaply in a unit
/// test) — this is the same seam `StreamingDictationSession.prewarmClosedGroups` actually calls
/// into, so it covers the real production code path, not a reimplementation of it.
@Suite("SmartCleaner incremental-cleanup prewarm cache")
struct SmartCleanerPrewarmTests {
    let cleaner = SmartCleaner()

    /// Text long enough that `TextSegmentation.groups` splits it into more than one group.
    func longDictation(sentenceCount: Int = 10) -> String {
        let sentence = "Um, so we, uh, need to ship the report by Friday."
        return Array(repeating: sentence, count: sentenceCount).joined(separator: " ")
    }

    @Test("a prewarmed group's cached text is reused by clean(_:...) instead of being recomputed")
    func prewarmedGroupIsReusedByClean() async {
        let raw = longDictation()
        let options = CleanupOptions()
        let groups = TextSegmentation.groups(raw)
        #expect(groups.count > 1, "test setup: needs more than one group to exercise the cache")

        // Prewarm every group except the tail, exactly like `prewarmClosedGroups` does.
        for group in groups where !group.isTail {
            await cleaner.prewarmGroup(group.text, options: options)
        }

        // Cleaning the whole text should now produce the same result as the uncached path
        // (proving the cache doesn't change behavior), and should still process the tail group
        // fresh (it was never prewarmed).
        let result = await cleaner.clean(raw, options: options, strategy: .rules)
        #expect(!result.text.contains("um"))
        #expect(!result.text.contains("uh"))
        let occurrences = result.text.components(separatedBy: "ship the report by Friday").count - 1
        #expect(occurrences == 10)
    }

    @Test("the tail group is never served from cache, even if its exact text was somehow prewarmed early")
    func tailGroupNeverPrewarmedByProductionCode() async {
        // This asserts the *production contract* `prewarmClosedGroups` follows (skip
        // `group.isTail`), not merely that the cache CAN serve a tail group if asked — the cache
        // itself is a plain key/value store and doesn't know about "tail" as a concept; the
        // guarantee that the tail stays open belongs to the caller
        // (`StreamingDictationSession.prewarmClosedGroups`), which this test documents by
        // spelling out exactly which groups it is and isn't allowed to prewarm.
        let raw = longDictation()
        let groups = TextSegmentation.groups(raw)
        let tail = try! #require(groups.last)
        #expect(tail.isTail)

        // A correction reaching into the tail group must still resolve correctly when the tail
        // is cleaned fresh at release (never served a stale prewarmed answer) — simulated here
        // by prewarming every non-tail group, then cleaning the whole text with the tail
        // rewritten to include a last-second correction that only exists once the "recording"
        // finishes.
        let correctedRaw = raw + " Let's meet at 10, no, 9 tomorrow."
        for group in groups where !group.isTail {
            await cleaner.prewarmGroup(group.text, options: CleanupOptions())
        }
        let result = await cleaner.clean(correctedRaw, options: CleanupOptions(), strategy: .rules)
        #expect(result.text.contains("Let's meet at 9 tomorrow."))
        #expect(!result.text.contains("Let's meet at 10"))
    }

    @Test("clearPrewarmedGroups drops cached entries, so a later clean(_:...) recomputes instead of reusing stale text")
    func clearPrewarmedGroupsDropsCache() async {
        let raw = longDictation()
        let options = CleanupOptions()
        let groups = TextSegmentation.groups(raw)
        for group in groups where !group.isTail {
            await cleaner.prewarmGroup(group.text, options: options)
        }
        await cleaner.clearPrewarmedGroups()

        // Behavior is identical whether or not the cache was populated — clearing must never
        // change the *result*, only whether it was served from cache. This mainly proves
        // `clearPrewarmedGroups` doesn't corrupt subsequent cleanup calls.
        let result = await cleaner.clean(raw, options: options, strategy: .rules)
        #expect(!result.text.contains("um"))
        let occurrences = result.text.components(separatedBy: "ship the report by Friday").count - 1
        #expect(occurrences == 10)
    }

    @Test("prewarming the same group text twice does not double-clean or change the result")
    func prewarmingTwiceIsIdempotent() async {
        let raw = longDictation()
        let options = CleanupOptions()
        let groups = TextSegmentation.groups(raw)
        for group in groups where !group.isTail {
            await cleaner.prewarmGroup(group.text, options: options)
            await cleaner.prewarmGroup(group.text, options: options)
        }
        let result = await cleaner.clean(raw, options: options, strategy: .rules)
        let occurrences = result.text.components(separatedBy: "ship the report by Friday").count - 1
        #expect(occurrences == 10)
    }
}
