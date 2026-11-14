import Foundation
import Testing
@testable import MurmurCore

/// Seeded, repeatable text for the field-location tests. Nothing here is real user text.
struct FieldTextMaker {
    private struct Generator: RandomNumberGenerator {
        var state: UInt64
        mutating func next() -> UInt64 {
            state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return state
        }
    }

    private var rng: Generator
    private let words: [String]

    init(seed: UInt64) {
        rng = Generator(state: seed)
        let syllables = ["ba", "ke", "mi", "so", "tu", "la", "ne", "ri", "po", "du", "fa", "go", "hi", "ju", "wa", "ze"]
        words = (0..<3_000).map { index in
            var word = ""
            var rest = index
            repeat { word += syllables[rest % syllables.count]; rest /= syllables.count } while rest > 0
            return word
        }
    }

    /// One word, skewed so a few words are very common (as in running text).
    mutating func word() -> String {
        let u = Double.random(in: 0..<1, using: &rng)
        return words[Int(Double(words.count) * u * u * u)]
    }

    mutating func tokens(_ count: Int) -> [String] { (0..<count).map { _ in word() } }

    mutating func int(_ range: Range<Int>) -> Int { Int.random(in: range, using: &rng) }

    /// `tokens` with `count` interior words replaced by words that are not in the vocabulary.
    mutating func edited(_ tokens: [String], replacing count: Int, tag: String = "zq") -> [String] {
        var result = tokens
        var used = Set<Int>()
        while used.count < min(count, max(tokens.count - 2, 0)) {
            let index = 1 + int(0..<(tokens.count - 2))
            if used.insert(index).inserted { result[index] = "\(tag)\(index)x" }
        }
        return result
    }
}

/// The original locator, kept as the oracle and the benchmark baseline: a whole-field LCS over
/// string keys, with the 600-token refusal removed so it can be timed on large fields.
enum WholeFieldLocator {
    static func locate(inserted: String, in fieldValue: String) -> CorrectionAlignment? {
        let insertedTokens = CorrectionAlignment.tokens(inserted)
        let fieldTokens = CorrectionAlignment.tokens(fieldValue)
        guard !insertedTokens.isEmpty, !fieldTokens.isEmpty else { return nil }
        let pairs = matchedPairs(insertedTokens.map(CorrectionAlignment.key), fieldTokens.map(CorrectionAlignment.key))
        guard let first = pairs.first, let last = pairs.last else { return nil }
        guard Double(pairs.count) / Double(insertedTokens.count) >= CorrectionAlignment.minSurvivingShare else { return nil }
        let start = max(0, first.field - first.inserted)
        let end = min(fieldTokens.count - 1, last.field + insertedTokens.count - 1 - last.inserted)
        let span = Array(fieldTokens[start...end])
        guard Double(pairs.count) / Double(span.count) >= CorrectionAlignment.minSurvivingShare else { return nil }
        var alignment = CorrectionAlignment.align(inserted: insertedTokens, edited: span)
        alignment.continuesAfter = end < fieldTokens.count - 1 && !CorrectionAlignment.continuesOnNewLine(fieldValue, afterToken: end)
        return alignment
    }

    private static func matchedPairs(_ a: [String], _ b: [String]) -> [(inserted: Int, field: Int)] {
        guard !a.isEmpty, !b.isEmpty else { return [] }
        var lcs = Array(repeating: Array(repeating: 0, count: b.count + 1), count: a.count + 1)
        for i in stride(from: a.count - 1, through: 0, by: -1) {
            for j in stride(from: b.count - 1, through: 0, by: -1) {
                lcs[i][j] = a[i] == b[j] && !a[i].isEmpty ? lcs[i + 1][j + 1] + 1 : max(lcs[i + 1][j], lcs[i][j + 1])
            }
        }
        var pairs: [(Int, Int)] = []
        var i = 0, j = 0
        while i < a.count, j < b.count {
            if a[i] == b[j], !a[i].isEmpty { pairs.append((i, j)); i += 1; j += 1 }
            else if lcs[i + 1][j] >= lcs[i][j + 1] { i += 1 } else { j += 1 }
        }
        return pairs.map { (inserted: $0.0, field: $0.1) }
    }
}

@Suite("Learning · anchored field location")
struct AnchoredFieldLocationTests {
    private func join(_ tokens: [String]) -> String { tokens.joined(separator: " ") }

    /// A field of `size` tokens with `dictation` (possibly edited) embedded at `position`, set off by
    /// two marker words so a field word equal to the dictation's first or last word cannot make the
    /// true edges ambiguous (the tests below are about where the dictation is, not about that tie).
    private func field(_ maker: inout FieldTextMaker, size: Int, position: Int, embedding embedded: [String]) -> String {
        join(maker.tokens(position) + ["startmark"] + embedded + ["endmark"] + maker.tokens(max(0, size - position - embedded.count)))
    }

    @Test("a long field (6,000 tokens) with the edited dictation in the middle")
    func longFieldMiddle() throws {
        var maker = FieldTextMaker(seed: 1)
        let dictation = maker.tokens(40)
        let edited = maker.edited(dictation, replacing: 3)
        let text = field(&maker, size: 6_000, position: 3_000, embedding: edited)
        let alignment = try #require(CorrectionAlignment.locate(inserted: join(dictation), in: text))
        #expect(alignment.edited == edited)
        #expect(alignment.edits.count == 3)
        #expect(alignment.changedInsertedWords == 3)
        #expect(alignment.continuesAfter)
    }

    @Test("located at the start, the end, and in a 20,000-token field")
    func positions() throws {
        var maker = FieldTextMaker(seed: 2)
        let dictation = maker.tokens(25)
        let edited = maker.edited(dictation, replacing: 2)
        for (size, position) in [(500, 0), (9_000, 9_000 - 25), (20_000, 12_345), (20_000, 0)] {
            let text = field(&maker, size: size, position: position, embedding: edited)
            let alignment = try #require(CorrectionAlignment.locate(inserted: join(dictation), in: text), "size \(size) at \(position)")
            #expect(alignment.edited == edited)
        }
    }

    @Test("a dictation that was pasted twice: the closer copy wins, and a tie goes to the later one")
    func repeatedTwice() throws {
        var maker = FieldTextMaker(seed: 3)
        let dictation = maker.tokens(30)
        let farther = maker.edited(dictation, replacing: 4, tag: "aa")
        let closer = maker.edited(dictation, replacing: 1, tag: "bb")
        // The copy that is closer to what was dictated wins, whichever comes first.
        for closerFirst in [false, true] {
            let parts = closerFirst ? [closer, farther] : [farther, closer]
            let text = join(maker.tokens(2_000) + ["startmark"] + parts[0] + ["endmark"] + maker.tokens(1_500) + ["startmark"] + parts[1] + ["endmark"] + maker.tokens(500))
            let alignment = try #require(CorrectionAlignment.locate(inserted: join(dictation), in: text))
            #expect(alignment.edited == closer)
            #expect(alignment.edits.count == 1)
        }
        // Two equally good copies: the later paste.
        let tied = join(maker.tokens(1_000) + ["startmark"] + closer + ["endmark"] + maker.tokens(2_000) + ["startmark"] + closer)
        let later = try #require(CorrectionAlignment.locate(inserted: join(dictation), in: tied))
        #expect(later.edited == closer)
        #expect(!later.continuesAfter)   // the second copy ends the field; the first would continue
    }

    @Test("a dictation of one to three words behaves as the whole-field alignment did")
    func shortDictations() throws {
        var maker = FieldTextMaker(seed: 4)
        let cases: [([String], [String])] = [
            (["send", "it", "now"], ["send", "it", "later"]),
            (["call", "Pria"], ["call", "Priya"]),
            (["thanks"], ["thanks"]),
        ]
        for (dictation, edited) in cases {
            for size in [40, 600, 5_000] {
                let text = field(&maker, size: size, position: size / 2, embedding: edited)
                let now = CorrectionAlignment.locate(inserted: join(dictation), in: text)
                let before = WholeFieldLocator.locate(inserted: join(dictation), in: text)
                #expect(now == before, "\(dictation) in \(size)")
            }
        }
        let text = field(&maker, size: 5_000, position: 2_500, embedding: ["send", "it", "later"])
        let alignment = try #require(CorrectionAlignment.locate(inserted: "send it now", in: text))
        #expect(alignment.edits == [WordEdit(before: ["now"], after: ["later"])])
    }

    @Test("the field changed around the dictation: text before, after and a different tail")
    func fieldChangedAround() throws {
        var maker = FieldTextMaker(seed: 5)
        let dictation = maker.tokens(35)
        let edited = maker.edited(dictation, replacing: 2)
        let variants = [
            join(edited),
            join(maker.tokens(5_000) + ["startmark"] + edited),
            join(edited + ["endmark"] + maker.tokens(5_000)),
            join(maker.tokens(3) + ["startmark"] + edited + ["endmark"] + maker.tokens(7_000)),
            "Hi team,\n" + join(edited) + "\n\nThanks,\nAda\n" + join(maker.tokens(1_200)),
        ]
        for text in variants {
            let alignment = try #require(CorrectionAlignment.locate(inserted: join(dictation), in: text))
            #expect(alignment.edited == edited)
            #expect(alignment.edits.count == 2)
        }
    }

    @Test("a field that does not hold the dictation is not located, at any length")
    func absentDictation() {
        var maker = FieldTextMaker(seed: 6)
        let dictation = maker.tokens(40)
        var located = 0
        for size in [100, 600, 5_000, 20_000] {
            for _ in 0..<10 where CorrectionAlignment.locate(inserted: join(dictation), in: join(maker.tokens(size))) != nil {
                located += 1
            }
        }
        #expect(located == 0)
    }

    @Test("a field of one repeated word cannot stall the locator")
    func repetitiveField() {
        let field = Array(repeating: "word", count: 20_000).joined(separator: " ")
        let start = DispatchTime.now().uptimeNanoseconds
        for dictation in ["word word word word", "word word word word word word word word word word word word"] {
            _ = CorrectionAlignment.locate(inserted: dictation + " end", in: field)
        }
        #expect(Double(DispatchTime.now().uptimeNanoseconds - start) / 1e9 < 2)
    }

    @Test("a heavily rewritten dictation is not located")
    func rewritten() {
        var maker = FieldTextMaker(seed: 7)
        let dictation = maker.tokens(30)
        let rewritten = maker.edited(dictation, replacing: 22)
        let text = field(&maker, size: 4_000, position: 2_000, embedding: rewritten)
        #expect(CorrectionAlignment.locate(inserted: join(dictation), in: text) == nil)
    }

    @Test("random edits, positions and sizes: always located, exactly where it was placed")
    func randomisedAgainstGroundTruth() throws {
        var maker = FieldTextMaker(seed: 8)
        for trial in 0..<150 {
            let size = [100, 300, 600, 2_000, 8_000][trial % 5]
            let dictation = maker.tokens(12 + maker.int(0..<60))
            let edited = maker.edited(dictation, replacing: maker.int(0..<4))
            let position = maker.int(0..<(size - edited.count))
            let text = field(&maker, size: size, position: position, embedding: edited)
            guard edited != dictation else { continue }
            let alignment = try #require(CorrectionAlignment.locate(inserted: join(dictation), in: text), "trial \(trial) size \(size)")
            #expect(alignment.edited == edited, "trial \(trial) size \(size)")
        }
    }

    @Test("up to 600 tokens: the anchored locator is right whenever the whole-field one was, and more often")
    func atLeastAsGoodAsWholeField() throws {
        var maker = FieldTextMaker(seed: 9)
        var wholeFieldRight = 0, anchoredRight = 0, trials = 0
        for _ in 0..<300 {
            let size = 30 + maker.int(0..<570)
            let dictation = maker.tokens(5 + maker.int(0..<50))
            let edited = maker.edited(dictation, replacing: 1 + maker.int(0..<max(1, min(3, dictation.count / 5))))
            let text = field(&maker, size: max(size, edited.count), position: maker.int(0..<max(1, size - edited.count)), embedding: edited)
            let before = WholeFieldLocator.locate(inserted: join(dictation), in: text)
            let now = CorrectionAlignment.locate(inserted: join(dictation), in: text)
            trials += 1
            if before?.edited == edited { wholeFieldRight += 1; #expect(now == before) }
            // A dictation like "ba ba x" with its second word replaced is ambiguous about whether the
            // marker word beside it belongs to it; accept the marker as part of the span.
            if now.map({ $0.edited.filter { $0 != "startmark" && $0 != "endmark" } }) == edited { anchoredRight += 1 }
        }
        print("whole-field right \(wholeFieldRight) / \(trials), anchored right \(anchoredRight) / \(trials)")
        #expect(anchoredRight >= wholeFieldRight)
        #expect(anchoredRight == trials)
    }
}

@Suite("Learning · field token scan")
struct FieldTokenScanTests {
    /// The scan must agree token for token with `tokens` + `key` + interning, on ASCII and on text
    /// with curly quotes, accents, emoji, CJK, no-break and line-separator spaces, tabs and CRLF.
    @Test("same tokens, keys and line-break answers as the Character-based code")
    func agreesWithCharacterCode() {
        let pieces = ["hello", "Hello,", "don't", "don\u{2019}t", "caf\u{e9}", "CAF\u{c9}", "na\u{ef}ve", "\u{1F600}", "\u{4F60}\u{597D}",
                      "a\u{a0}b", "x\u{2028}y", "--", "—", "3.14", "U.S.A.", "e\u{301}", "I'm", "Pria", "Priya", "$5", "(ok)", "", "https://example.com/a-very-long-path-that-goes-on-and-on-and-on-and-on-and-on-and-on-and-on"]
        let separators = [" ", "  ", "\t", "\n", "\r\n", "\n\n", " \n ", "\u{a0}", "\u{2028}", "\u{3000}"]
        var maker = FieldTextMaker(seed: 11)
        for trial in 0..<300 {
            var text = trial % 7 == 0 ? " \n" : ""
            for _ in 0..<(1 + maker.int(0..<40)) {
                text += pieces[maker.int(0..<pieces.count)] + separators[maker.int(0..<separators.count)]
            }
            let dictation = (0..<5).map { _ in pieces[maker.int(0..<pieces.count)] }.joined(separator: " ")
            let (ids, vocabulary) = CorrectionAlignment.intern(CorrectionAlignment.tokens(dictation).map(CorrectionAlignment.key))
            let scan = FieldTokenScan(text, vocabulary: vocabulary)
            let tokens = CorrectionAlignment.tokens(text)
            #expect(scan.count == tokens.count, "trial \(trial)")
            guard scan.count == tokens.count, !tokens.isEmpty else { continue }
            #expect(scan.tokens(0...(tokens.count - 1)) == tokens, "trial \(trial)")
            let expected = tokens.map { CorrectionAlignment.key($0) }.map { key -> Int32 in
                key.isEmpty ? -1 : (vocabulary[key] ?? -1)
            }
            #expect(scan.ids == expected, "trial \(trial)")
            for index in tokens.indices {
                #expect(scan.continuesOnNewLine(afterToken: index) == (index < tokens.count - 1 && CorrectionAlignment.continuesOnNewLine(text, afterToken: index)), "trial \(trial) token \(index)")
            }
            _ = ids
        }
    }

    @Test("a field past the byte bound is not scanned")
    func bound() {
        let huge = String(repeating: "word ", count: CorrectionAlignment.maxFieldBytes / 5 + 10)
        #expect(CorrectionAlignment.locate(inserted: "send the deck to Priya", in: huge) == nil)
    }
}

/// The old (whole-field LCS) and new (anchored) locator, timed. Off by default.
/// Run: `HUSHY_ANCHOR_BENCH=1 swift test --filter AnchoredFieldLocationBenchmark`.
@Suite(
    "Anchored field location benchmark",
    .enabled(if: ProcessInfo.processInfo.environment["HUSHY_ANCHOR_BENCH"] != nil))
struct AnchoredFieldLocationBenchmark {
    private func median(_ samples: [Double]) -> Double { samples.sorted()[samples.count / 2] }

    private func milliseconds(runs: Int, _ body: () -> Void) -> Double {
        median((0..<runs).map { _ in
            let start = DispatchTime.now().uptimeNanoseconds
            body()
            return Double(DispatchTime.now().uptimeNanoseconds - start) / 1e6
        })
    }

    @Test("old versus new on 600, 2,000 and 20,000 token fields")
    func timings() throws {
        var maker = FieldTextMaker(seed: 10)
        var lines: [String] = ["field tokens | dictation | old (whole-field LCS) ms | new (anchored) ms | old right | new right"]
        for dictationWords in [60, 400] {
            for size in [600, 2_000, 20_000] {
                let dictation = maker.tokens(dictationWords)
                let edited = maker.edited(dictation, replacing: 3)
                let text = (maker.tokens(size / 2) + edited + maker.tokens(max(0, size / 2 - dictationWords))).joined(separator: " ")
                let inserted = dictation.joined(separator: " ")
                var oldResult: CorrectionAlignment?, newResult: CorrectionAlignment?
                let runs = size >= 20_000 && dictationWords == 400 ? 3 : 9
                let old = milliseconds(runs: runs) { oldResult = WholeFieldLocator.locate(inserted: inserted, in: text) }
                let new = milliseconds(runs: 15) { newResult = CorrectionAlignment.locate(inserted: inserted, in: text) }
                #expect(newResult != nil)
                lines.append(String(format: "%6d | %4d words | %9.2f | %7.2f | %@ | %@", size, dictationWords, old, new,
                                    oldResult?.edited == edited ? "yes" : (oldResult == nil ? "missed" : "wrong span"),
                                    newResult?.edited == edited ? "yes" : "NO"))
                if size == 20_000 { #expect(new < 100) }
            }
        }
        print("ANCHOR-BENCH\n" + lines.joined(separator: "\n"))
    }
}
