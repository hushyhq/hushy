import Testing
@testable import MurmurCore

@Suite("Capitalise sentences keeps mixed-case words")
struct CapitalizeSentencesMixedCaseTests {
    @Test("a word with an uppercase letter after its first is left as written")
    func mixedCaseWordsAreLeftAlone() {
        #expect(Punctuation.capitalizeSentences("iPhone is working") == "iPhone is working")
        #expect(Punctuation.capitalizeSentences("macOS and iOS ship. eBay and gRPC too") == "macOS and iOS ship. eBay and gRPC too")
        #expect(Punctuation.capitalizeSentences("done\ngRPC next") == "Done\ngRPC next")
    }

    @Test("ordinary lowercase words are still capitalised")
    func ordinaryWordsAreCapitalised() {
        #expect(Punctuation.capitalizeSentences("hello there. it works") == "Hello there. It works")
        #expect(Punctuation.capitalizeSentences("i think so") == "I think so")
        #expect(Punctuation.capitalizeSentences("1. then go") == "1. Then go")
    }
}
