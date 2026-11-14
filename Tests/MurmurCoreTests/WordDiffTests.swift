import Testing
@testable import MurmurCore

@Suite("WordDiff")
struct WordDiffTests {
    @Test("contractions are matched, not struck through")
    func contractions() {
        let flags = WordDiff.keptFlags(
            original: "In the word I don't know the don't is scratched",
            cleaned: "In the word I don't know the don't is scratched")
        #expect(flags.allSatisfy { $0 })
    }

    @Test("only the removed word is struck: \"it's actually working\" → \"it's working\"")
    func itsActually() {
        #expect(WordDiff.keptFlags(original: "Do you think it's actually working right now?",
                                   cleaned: "Do you think it's working right now?")
                == [true, true, true, true, false, true, true, true])
    }

    @Test("curly and straight apostrophes are the same word")
    func apostrophes() {
        #expect(WordDiff.keptFlags(original: "I don\u{2019}t know", cleaned: "I don't know") == [true, true, true])
    }

    @Test("removed fillers are marked, kept words aren't")
    func fillers() {
        let flags = WordDiff.keptFlags(original: "Uh so what I'll do is, um, go", cleaned: "So what I'll do is go.")
        #expect(flags == [false, true, true, true, true, true, false, true])
    }

    @Test("a repeated word is only struck once")
    func repeats() {
        let flags = WordDiff.keptFlags(original: "I I think", cleaned: "I think")
        #expect(flags.filter { !$0 }.count == 1)
        #expect(flags.last == true)
    }

    @Test("words cleanup only joined with a hyphen are not struck")
    func hyphenJoin() {
        #expect(WordDiff.keptFlags(original: "it runs in real time now", cleaned: "It runs in real-time now.")
                == [true, true, true, true, true, true])
    }

    @Test("words joined into one name are not struck; a repeat before them still is")
    func nameJoin() {
        #expect(WordDiff.keptFlags(original: "push it to Git Git Hub today", cleaned: "Push it to GitHub today.")
                == [true, true, true, false, true, true, true])
    }

    @Test("a word cleanup split in two is not struck")
    func split() {
        #expect(WordDiff.keptFlags(original: "send the e-mail later", cleaned: "Send the e mail later.")
                == [true, true, true, true])
    }

    @Test("a removed filler next to a join is still struck")
    func fillerBesideJoin() {
        #expect(WordDiff.keptFlags(original: "um the hand off went fine", cleaned: "The handoff went fine.")
                == [false, true, true, true, true, true])
    }

    @Test("unrelated removed words are not kept by an accidental join")
    func noFalseJoin() {
        #expect(WordDiff.keptFlags(original: "I mean the plan works", cleaned: "The plan works.")
                == [false, false, true, true, true])
    }
}
