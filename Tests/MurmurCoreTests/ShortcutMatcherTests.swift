import Testing
@testable import MurmurCore

@Suite("ShortcutMatcher")
struct ShortcutMatcherTests {
    @Test("exact case-insensitive match ranks first")
    func exactMatchFirst() {
        let ranked = ShortcutMatcher.rank(spoken: "start focus", available: ["Other Thing", "Start Focus"])
        #expect(ranked.first == "Start Focus")
    }

    @Test("bestMatch only returns a confident exact match")
    func bestMatchRequiresExact() {
        #expect(ShortcutMatcher.bestMatch(spoken: "Start Focus", available: ["Start Focus"]) == "Start Focus")
        #expect(ShortcutMatcher.bestMatch(spoken: "start my focus", available: ["Start Focus"]) == nil)
    }

    @Test("rank returns close partial matches for a fuzzy name")
    func rankReturnsPartialMatches() {
        let ranked = ShortcutMatcher.rank(spoken: "focus routine", available: ["Start My Focus Routine", "Grocery List"])
        #expect(ranked.first == "Start My Focus Routine")
    }

    @Test("empty available list returns no matches")
    func emptyAvailable() {
        #expect(ShortcutMatcher.rank(spoken: "anything", available: []).isEmpty)
    }

    @Test("no overlap produces no matches")
    func noOverlap() {
        #expect(ShortcutMatcher.rank(spoken: "zzz qqq", available: ["Completely Different"]).isEmpty)
    }

    @Test("installedName matches only a Shortcut that exists, ignoring case and filler words")
    func installedNameMatchesLibrary() {
        let library = ["Morning Routine", "Log Water", "Leave Home", "Home Leave Timer"]
        #expect(ShortcutMatcher.installedName(spoken: "my morning routine shortcut", available: library) == "Morning Routine")
        #expect(ShortcutMatcher.installedName(spoken: "the shortcut called Log Water", available: library) == "Log Water")
        #expect(ShortcutMatcher.installedName(spoken: "routine morning", available: library) == "Morning Routine")
        // Never a near miss or a free-form name.
        #expect(ShortcutMatcher.installedName(spoken: "morning", available: library) == nil)
        #expect(ShortcutMatcher.installedName(spoken: "morning routine two", available: library) == nil)
        #expect(ShortcutMatcher.installedName(spoken: "wipe disk", available: library) == nil)
        #expect(ShortcutMatcher.installedName(spoken: "shortcut", available: library) == nil)
        #expect(ShortcutMatcher.installedName(spoken: "morning routine", available: []) == nil)
    }
}
