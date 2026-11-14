import Foundation
import Testing
@testable import Murmur

/// The surfaces outside `LockGate` that could show dictated words or note text: what each one
/// does while the app lock is on. The search palette and the menu bar's last-transcript items
/// have a pure seam here; Home's is `HomeCardContent` (`HomeLastDictationTests`).
@Suite("App lock — surfaces outside the gate")
struct AppLockSurfaceTests {
    @Test("locked, the search palette shows no results and runs no search, whatever is typed or was found")
    func paletteLocked() {
        for query in ["", "budget", "  plan  "] {
            for count in [0, 5] {
                #expect(SearchPaletteState.make(isLocked: true, query: query, resultCount: count) == .locked)
            }
            #expect(SearchPaletteState.queryToRun(isLocked: true, query: query) == nil)
        }
    }

    @Test("unlocked, the palette prompts, searches the trimmed words, and shows results or no matches")
    func paletteUnlocked() {
        #expect(SearchPaletteState.make(isLocked: false, query: "  ", resultCount: 0) == .prompt)
        #expect(SearchPaletteState.make(isLocked: false, query: "budget", resultCount: 0) == .noMatches)
        #expect(SearchPaletteState.make(isLocked: false, query: "budget", resultCount: 3) == .results)
        #expect(SearchPaletteState.queryToRun(isLocked: false, query: "  plan  ") == "plan")
        #expect(SearchPaletteState.queryToRun(isLocked: false, query: "   ") == nil)
    }

    @Test("locked, the menu bar cannot paste or copy the last transcript")
    func menuBarLastTranscript() {
        #expect(!LockedCopy.canUseLastTranscript(hasTranscript: true, isLocked: true))
        #expect(LockedCopy.canUseLastTranscript(hasTranscript: true, isLocked: false))
        #expect(!LockedCopy.canUseLastTranscript(hasTranscript: false, isLocked: false))
    }

    @Test("each locked surface says what is hidden in one plain line")
    func lockedLines() {
        #expect(LockedCopy.search == "Your dictations and notes are hidden while Hushy is locked.")
        #expect(LockedCopy.assistant == "Your notes and action items are hidden while Hushy is locked.")
        #expect(LockedCopy.unlock == "Unlock")
        for line in [LockedCopy.search, LockedCopy.assistant] {
            #expect(!line.contains("!"))
            #expect(!line.contains("—"))
            #expect(!line.contains("\n"))
        }
    }
}
