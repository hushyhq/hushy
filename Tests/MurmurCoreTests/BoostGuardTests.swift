import Testing
@testable import MurmurCore

@Suite("BoostGuard")
struct BoostGuardTests {
    let common: Set<String> = ["voice", "a", "distant", "said", "his", "face", "buried", "in", "hands",
                               "privacy", "their", "send", "the", "to", "accounting", "university"]
    let terms = ["Priya", "Siobhan", "invoice", "build"]

    func run(_ original: String, _ boosted: String) -> String {
        BoostGuard.filter(original: original, boosted: boosted, terms: terms) { common.contains($0) }
    }

    @Test("reverts a boost that replaced an ordinary English word")
    func revertsCommonWords() {
        #expect(run("Onward said a distant voice", "Onward said a distant invoice") == "Onward said a distant voice")
        #expect(run("his face buried in his hands", "his face build in his hands") == "his face buried in his hands")
        #expect(run("assured of their privacy", "assured of their Priya") == "assured of their privacy")
    }

    @Test("keeps a boost that fixed a misspelled name")
    func keepsNameFixes() {
        #expect(run("Send the notes to Sioban in accounting.", "Send the notes to Siobhan in accounting.")
                == "Send the notes to Siobhan in accounting.")
    }

    @Test("inflected forms of dictionary words count as English")
    func inflections() {
        let words: Set<String> = ["invite", "voice", "bury", "stop", "quick"]
        for word in ["invited", "voices", "buried", "stopped", "inviting", "quickly"] {
            #expect(BoostGuard.isEnglishWord(word, in: words), "\(word)")
        }
        #expect(!BoostGuard.isEnglishWord("sioban", in: words))
    }

    @Test("unchanged text passes through")
    func unchanged() {
        #expect(run("hello there", "hello there") == "hello there")
    }

    @Test("alignment finds changed runs")
    func align() {
        let regions = BoostGuard.align(["a", "b", "c"], ["a", "x", "y", "c"])
        #expect(regions == [.same(0..<1), .changed(old: 1..<2, new: 1..<3), .same(3..<4)])
    }
}
