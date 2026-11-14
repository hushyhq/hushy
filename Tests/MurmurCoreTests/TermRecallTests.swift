import Foundation
import Testing
@testable import MurmurCore

/// Which stored words a transcript brings back. Every name is invented.
@Suite("Term recall")
struct TermRecallTests {
    private static let veloria = MemoryEntry(kind: .term, value: "Veloria", heardAs: ["Valoria"])
    private static let nerula = MemoryEntry(kind: .term, value: "Nerula")
    private static let ridge = MemoryEntry(kind: .term, value: "Tavren Ridge")
    private static let quillpad = MemoryEntry(kind: .term, value: "Quillpad", heardAs: ["quill pad"])
    private static let index = MemoryIndex(entries: [veloria, nerula, ridge, quillpad])

    private func recalled(_ transcript: String, from index: MemoryIndex = TermRecallTests.index) -> [String] {
        TermRecall.recall(transcript, from: index).map(\.value)
    }

    @Test("a word comes back by how it was heard, its spelling, a near sound and a loose sound")
    func positives() {
        #expect(recalled("send it to Valoria today") == ["Veloria"])
        #expect(recalled("nerula, please") == ["Nerula"])
        #expect(recalled("we walked up tavren ridge") == ["Tavren Ridge"])
        #expect(recalled("ask Nerrula") == ["Nerula"])
        #expect(recalled("ask beloria") == ["Veloria"])
        #expect(recalled("the tavrenridge trail") == ["Tavren Ridge"])
    }

    @Test("ordinary words bring back only a word spelled exactly so, never one that merely sounds like them")
    func commonWords() {
        // "tarrow" is in the system word list, so both words of that name are ordinary ones.
        let index = MemoryIndex(entries: [Self.veloria, MemoryEntry(kind: .term, value: "Ridge"),
                                          MemoryEntry(kind: .term, value: "Tarrow Ridge"),
                                          MemoryEntry(kind: .term, value: "Lunches")])
        #expect(recalled("we should meet at the office after lunch", from: index).isEmpty)
        #expect(recalled("the bridges were closed", from: index).isEmpty)
        #expect(recalled("", from: index).isEmpty)
        #expect(recalled("ask Zorvex", from: index).isEmpty)
        // Spelled exactly, an ordinary word that is a stored word comes back: the model decides
        // whether it was meant.
        #expect(recalled("walk over the ridge and back", from: index) == ["Ridge"])
        #expect(Set(recalled("walk up tarrow ridge", from: index)) == ["Ridge", "Tarrow Ridge"])
    }

    @Test("ordinary words also bring a word back when they are exactly how it was heard")
    func exactHearingOfCommonWords() {
        #expect(recalled("open the quill pad now") == ["Quillpad"])
        #expect(recalled("a quill and a pad").isEmpty)
    }

    @Test("order: heard-as, spelling, near sound, loose sound; newer first within one")
    func ranking() {
        let old = Date(timeIntervalSince1970: 1_000), new = Date(timeIntervalSince1970: 2_000)
        let entries = [
            MemoryEntry(kind: .term, value: "Beloria", createdAt: old),
            MemoryEntry(kind: .term, value: "Veloriah", createdAt: old),
            MemoryEntry(kind: .term, value: "Veloria", createdAt: old),
            MemoryEntry(kind: .term, value: "Savara", heardAs: ["veloria"], createdAt: old),
            MemoryEntry(kind: .term, value: "Feloria", createdAt: new),
        ]
        #expect(recalled("veloria", from: MemoryIndex(entries: entries))
                == ["Savara", "Veloria", "Feloria", "Veloriah", "Beloria"])
    }

    @Test("a forgotten word is not recalled, and at most eleven come back")
    func forgottenAndCap() {
        let forgotten = MemoryIndex(entries: [Self.veloria, MemoryEntry(kind: .forgotten, value: "veloria")])
        #expect(recalled("Veloria and Valoria", from: forgotten).isEmpty)
        let many = MemoryIndex(entries: (0..<15).map { MemoryEntry(kind: .term, value: "Savara\($0)", heardAs: ["veloria"]) })
        #expect(TermRecall.recall("veloria", from: many).count == 11)
        #expect(TermRecall.recall("veloria", from: many, limit: 2).count == 2)
        #expect(TermRecall.recall("veloria", from: many, limit: 50).count == 11)
        #expect(TermRecall.recall("veloria", from: many, limit: 0).isEmpty)
    }

    @Test("the indexed recall answers exactly as the plain term-by-run comparison does")
    func matchesThePlainComparison() {
        var words = InventedWords(seed: 7)
        let terms = (0..<40).map { _ in MemoryEntry(kind: .term, value: words.term(), heardAs: [words.word()]) }
        let index = MemoryIndex(entries: terms)
        // A third of the transcript is stored words said slightly wrong, so every tier fires.
        let transcript = (0..<180).map { position -> String in
            let term = terms[(position * 7) % terms.count]
            switch position % 12 {
            case 0, 3, 6: return words.misheard(term.value)
            case 9: return term.heardAs[0]
            case 10: return term.value
            default: return words.word()
            }
        }.joined(separator: " ")
        // Every third word of the transcript counts as an ordinary one, so that rule is compared too.
        let ordinary = Set(CorrectionAlignment.tokens(transcript).enumerated().filter { $0.offset % 3 == 1 }
            .map { CorrectionAlignment.key($0.element) })
        let isCommon: (String) -> Bool = { ordinary.contains($0) }
        let plain = TermRecallReference.ranks(transcript, index: index, isCommonWord: isCommon)
        #expect(TermRecall.ranks(transcript, from: index, isCommonWord: isCommon) == plain)
        #expect(Set(plain.values) == [0, 1, 2, 3], "the transcript should reach every tier")
    }

    @Test("the stored-key sound check answers as the learner's does, for odd words too")
    func keyedSoundCheckAgrees() {
        var words = InventedWords(seed: 3)
        let odd = ["", "a", "aaaaaaaaaaaa", "aaaaaaaaaaab", "baaaaaaaaaaaaaaa", "veloria", "beloria", "feloria",
                   "véloria", "velória", "o'nerula", "onerula", "nerula7", "nerula42", "x9", "9x", "kt", "kd", "kate", "kody",
                   "zzzzzzzzzs", "ssssssssss", "tavrenridge", "tavrenrich", "çé", "ça"]
        let sample = odd + (0..<60).map { _ in words.word() }
        for a in sample {
            for b in sample {
                #expect(RecallKeys(key: a).soundsLike(RecallKeys(key: b)) == CorrectionClassifier.soundsAlike(a, b),
                        "\(a) / \(b)")
            }
        }
    }

    @Test("a 1,000-word transcript against 300 words is recalled in a fraction of the plain comparison's time")
    func longTranscriptIsCheap() {
        var words = InventedWords(seed: 11)
        let index = MemoryIndex(entries: (0..<300).map { _ in MemoryEntry(kind: .term, value: words.term(), heardAs: [words.word()]) })
        // The worst case: every word unusual, so every run is compared with every stored word.
        let transcript = (0..<1_000).map { _ in words.word() }.joined(separator: " ")
        let elapsed = ContinuousClock().measure { _ = TermRecall.recall(transcript, from: index, isCommonWord: { _ in false }) }
        // Loose on purpose: an unoptimised build on a busy Mac, where this takes about a second
        // alone. The plain comparison takes about 40 s on this input, so a return to it still fails.
        #expect(elapsed < .seconds(20), "took \(elapsed)")
    }
}

/// The comparison as first written: every term against every run, keys rebuilt each time.
/// Slow, and plainly what the blueprint asks for, so it is the oracle for the indexed version.
enum TermRecallReference {
    static func ranks(_ transcript: String, index: MemoryIndex, isCommonWord: (String) -> Bool) -> [UUID: Int] {
        let tokens = CorrectionAlignment.tokens(transcript).map(CorrectionAlignment.key).filter { !$0.isEmpty }
        var ranks: [UUID: Int] = [:]
        for entry in index.terms {
            let term = MemoryIndex.key(entry.value).replacingOccurrences(of: " ", with: "")
            let hearings = entry.heardAs.map(MemoryIndex.key)
            for start in tokens.indices {
                for length in 1...min(3, tokens.count - start) {
                    let words = Array(tokens[start..<(start + length)])
                    guard let rank = rank(words, term: term, spelled: MemoryIndex.key(entry.value), hearings: hearings,
                                          isCommonWord: isCommonWord) else { continue }
                    ranks[entry.id] = min(ranks[entry.id] ?? rank, rank)
                }
            }
        }
        return ranks
    }

    private static func rank(_ words: [String], term: String, spelled: String, hearings: [String],
                             isCommonWord: (String) -> Bool) -> Int? {
        let run = words.joined(separator: " "), heard = words.joined()
        if hearings.contains(run) { return 0 }
        if run == spelled { return 1 }
        if words.allSatisfy(isCommonWord) { return nil }
        if ContextSpellingFixer.phoneticKey(heard) == ContextSpellingFixer.phoneticKey(term),
           ContextSpellingFixer.levenshtein(heard, term) <= ContextSpellingFixer.maxEditDistance(for: term.count) { return 2 }
        return CorrectionClassifier.soundsAlike(heard, term) ? 3 : nil
    }
}

/// Pronounceable made-up words from a fixed seed, so a run is the same every time.
struct InventedWords {
    private var state: UInt64
    private static let onsets = ["b", "d", "f", "g", "k", "l", "m", "n", "p", "r", "s", "t", "v", "z", "br", "tr", "st"]
    private static let vowels = ["a", "e", "i", "o", "u", "ia", "ou"]

    init(seed: UInt64) { state = seed }

    private mutating func next(_ bound: Int) -> Int {
        state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
        return Int((state >> 33) % UInt64(bound))
    }

    mutating func word() -> String {
        (0..<(2 + next(3))).map { _ in Self.onsets[next(Self.onsets.count)] + Self.vowels[next(Self.vowels.count)] }.joined()
    }

    /// One word, or sometimes two, capitalised as a name would be.
    mutating func term() -> String {
        (0..<(next(4) == 0 ? 2 : 1)).map { _ in word().capitalized }.joined(separator: " ")
    }

    /// The word with one letter changed, dropped or doubled, or split in two, as a recogniser might hear it.
    mutating func misheard(_ value: String) -> String {
        var letters = Array(value.lowercased())
        let position = next(letters.count)
        switch next(4) {
        case 0: letters[position] = Character(Self.vowels[next(5)])
        case 1: letters.remove(at: position)
        case 2: letters.insert(letters[position], at: position)
        default: letters.insert(" ", at: max(1, position))
        }
        return String(letters)
    }
}
