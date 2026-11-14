import Foundation
import Testing
@testable import MurmurCore

/// The one-pass Dictionary matcher must write exactly what the regular-expression loop wrote, on every Dictionary and every
/// sentence: same text, same fix count. Invented names and sentences only.
private func reference(_ text: String, _ entries: [DictionaryEntry], _ keep: KeepHeardSet = .empty) -> (String, Int) {
    Personalizer.applyDictionarySequential(text, entries: entries, keep: keep)
}

private func current(_ text: String, _ entries: [DictionaryEntry], _ keep: KeepHeardSet = .empty) -> (String, Int) {
    Personalizer(dictionary: entries, keep: keep).applyDictionary(text)
}

private func entry(_ term: String, _ heard: [String] = []) -> DictionaryEntry { DictionaryEntry(term: term, soundsLike: heard) }

struct MatcherCase: Sendable, CustomTestStringConvertible {
    let name: String
    let entries: [DictionaryEntry]
    let texts: [String]
    var keep: [(heard: String, written: String)] = []
    var testDescription: String { name }

    var keepSet: KeepHeardSet {
        KeepHeardSet(swaps: keep.map { VocabularySwap(heard: $0.heard, written: $0.written, source: .dictionaryAlias) })
    }
}

let matcherCases: [MatcherCase] = [
    MatcherCase(name: "multi-word heard phrase", entries: [entry("Kubernetes", ["cooper netties"])], texts: [
        "I run cooper netties and cooper netties", "Cooper Netties!", "cooper netties's pods", "cooperative netties",
        "cooper  netties", "cooper\nnetties", "COOPER NETTIES", "say cooper netties, then stop.", "kubernetes", "KUBERNETES works",
    ]),
    MatcherCase(name: "longest variant first inside one entry", entries: [entry("Kubernetes", ["cooper", "cooper netties"])], texts: [
        "cooper netties", "cooper", "cooper netties cooper", "a cooper, then cooper netties.",
    ]),
    MatcherCase(name: "overlapping phrases in different entries, entry order decides", entries: [
        entry("Foo Bar", ["foo bar"]), entry("Baz", ["bar"]),
    ], texts: ["foo bar", "say foo bar now", "bar foo", "foo, bar", "Foo Bar bar"]),
    MatcherCase(name: "reverse order of the same entries", entries: [
        entry("Baz", ["bar"]), entry("Foo Bar", ["foo bar"]),
    ], texts: ["foo bar", "say foo bar now", "bar foo", "foo, bar", "Foo Bar bar"]),
    MatcherCase(name: "one entry's output is another's heard phrase", entries: [
        entry("alpha", ["beta"]), entry("gamma", ["alpha"]),
    ], texts: ["beta", "beta alpha", "say beta, then alpha.", "gamma", "Alpha"]),
    MatcherCase(name: "cascade through three entries", entries: [
        entry("b", ["a"]), entry("c", ["b"]), entry("d", ["c"]),
    ], texts: ["a", "a b c", "a a", "c"]),
    MatcherCase(name: "term made of an earlier term", entries: [
        entry("Node", ["noad"]), entry("Node.js", ["node js"]),
    ], texts: ["noad js", "node js", "noad", "use noad js today", "node.js"]),
    MatcherCase(name: "variant inside a longer word", entries: [entry("Cat", ["cat"]), entry("Dog", ["dog"])], texts: [
        "category", "concat", "cat's", "cat-food", "cat_x", "cat3", "a cat", "cats", "the cat. the dog!", "(cat)", "dogcat",
        "cat\u{2019}s", "CAT", "scat cat tac",
    ]),
    MatcherCase(name: "punctuation inside heard phrases and terms", entries: [
        entry("C++", ["see plus plus", "c++"]), entry("Node.js", ["node js", "node.js"]), entry(".NET", ["dot net"]),
        entry("e-mail", ["email"]), entry("Don't", ["dont"]),
    ], texts: [
        "see plus plus and c++ and node js", "c++.", "c+++", "use node.js, node js; dot net", "dot net", "an email", "e-mail",
        "dont stop", "don't", "x.net", ".net", "I use C++!",
    ]),
    MatcherCase(name: "term contains its heard phrase", entries: [entry("jimmylord.com", ["jimmylord", "jimmy lord"])], texts: [
        "go to jimmylord today", "go to jimmylord.com today", "Jimmylord.Com.", "go to jimmy lord.com", "go to jimmy lord today",
        "jimmylord jimmylord.com", "email jimmy lord dot com", "jimmylord.com.com",
    ]),
    MatcherCase(name: "term with leading and trailing punctuation", entries: [entry("@miraholt", ["miraholt"]), entry("(draft)", ["draft"])], texts: [
        "ping miraholt", "ping @miraholt", "ping @@miraholt", "a draft here", "a (draft) here", "draft", "(draft)",
    ]),
    MatcherCase(name: "keep-as-heard blocks one swap only", entries: [entry("Kubernetes", ["cooper netties"]), entry("Codex", ["codec"])],
         texts: ["run cooper netties with codec", "codec codec", "Cooper Netties"],
         keep: [(heard: "codec", written: "Codex")]),
    MatcherCase(name: "keep-as-heard blocks a multi-word swap", entries: [entry("Kubernetes", ["cooper netties", "cooper"])],
         texts: ["cooper netties and cooper", "cooper"], keep: [(heard: "cooper netties", written: "Kubernetes")]),
    MatcherCase(name: "same heard phrase claimed by two entries", entries: [entry("First", ["shared"]), entry("Second", ["shared"])],
         texts: ["shared", "a shared b"]),
    MatcherCase(name: "term listed as its own heard phrase, empty and duplicate phrases", entries: [
        entry("Priya", ["priya", "Priya", "", "pria", "pria"]), entry("", ["ignored"]), entry("Anil", [""]),
    ], texts: ["pria and priya", "PRIYA", "Priya", "ignored", "anil", "pria pria"]),
    MatcherCase(name: "accents, case mapping and scalars the matcher declines", entries: [
        entry("Zoë", ["zoe", "zoey"]), entry("Café Roma", ["cafe roma"]), entry("Strasse", ["straße"]), entry("Istanbul", ["i̇stanbul"]),
    ], texts: [
        "zoe and ZOË", "Zoe\u{0308}", "cafe roma", "CAFÉ ROMA", "Straße", "STRASSE", "i̇stanbul", "İstanbul", "naïve zoe", "zoé",
    ]),
    MatcherCase(name: "ordinary text around a non-ASCII word still takes the fast route", entries: [entry("Kubernetes", ["cooper netties"])], texts: [
        "café cooper netties", "naïve cooper netties résumé",
    ]),
    MatcherCase(name: "an earlier edit completes the stretch a later reading looks for", entries: [
        entry("lord", ["lard"]), entry("jimlord.com", ["jim"]),
    ], texts: ["jim lard.com", "jim lard", "see jim lard.com today", "lard.com jim", "jim, lard.com", "lard jim lard.com"]),
    MatcherCase(name: "an earlier edit breaks the stretch a later reading looks for", entries: [
        entry("lard", ["lord"]), entry("jimlord.com", ["jim", "jimlord"]),
    ], texts: ["jim lord.com", "jimlord.com", "jim lord", "go to jimlord.com now", "jimlord lord.com"]),
    MatcherCase(name: "a reading reaches over letters of a neighbour that another rule rewrites", entries: [
        entry("Mira", ["mere"]), entry("miraholt.com", ["mira", "holt"]),
    ], texts: ["mere holt.com", "mira holt.com", "mira mere holt", "holt mira", "mere mira holt.com"]),
    MatcherCase(name: "adjacent replacements", entries: [entry("Foo", ["foo"]), entry("Bar", ["bar"]), entry("-", ["dash"])], texts: [
        "foo bar", "foo,bar", "foo.bar", "foo-bar", "foo bar foo bar", "foo dash bar", "foobar", "foo\tbar", "foo\u{00a0}bar",
    ]),
    MatcherCase(name: "self-overlapping phrase", entries: [entry("AA", ["a a"])], texts: ["a a a", "a a a a", "a a", "a  a a"]),
    MatcherCase(name: "phrase of punctuation and spaces", entries: [entry("Dots", ["..."]), entry("Space", [" "])], texts: [
        "wait... what", "a ... b", "...", "x . . . y", "a b",
    ]),
    MatcherCase(name: "empty and degenerate text", entries: [entry("Kubernetes", ["cooper netties"])], texts: ["", " ", "\n", "cooper netties\n", "\n cooper netties \n"]),
    MatcherCase(name: "empty Dictionary", entries: [], texts: ["anything at all", ""]),
    MatcherCase(name: "long dictation", entries: [
        entry("Kubernetes", ["cooper netties"]), entry("Priya", ["pria"]), entry("Notion", ["motion"]),
    ], texts: [String(repeating: "we met pria about cooper netties and the motion plan, ", count: 40)]),
]

@Suite("Dictionary one-pass matcher", .timeLimit(.minutes(5)))
struct DictionaryMatcherTests {
    @Test("matches the regular-expression loop on hand-written cases", arguments: matcherCases)
    func handWritten(_ item: MatcherCase) {
        for text in item.texts {
            let (expected, expectedFixes) = reference(text, item.entries, item.keepSet)
            let (got, gotFixes) = current(text, item.entries, item.keepSet)
            #expect(got == expected, "\(item.name): \(text.debugDescription) -> \(got.debugDescription), expected \(expected.debugDescription)")
            #expect(gotFixes == expectedFixes, "\(item.name): \(text.debugDescription) fixes \(gotFixes), expected \(expectedFixes)")
        }
    }

    @Test("matches the loop on thousands of generated Dictionaries and sentences")
    func generated() {
        var random = SplitMix64(seed: 20_261_028)
        var paths: [String: Int] = [:]
        for caseNumber in 0..<4_000 {
            let generated = GeneratedCase(&random)
            let matcher = DictionaryMatcher(entries: generated.entries)
            for text in generated.texts {
                let (expected, expectedFixes) = reference(text, generated.entries, generated.keep)
                let (got, gotFixes) = Personalizer(dictionary: generated.entries, keep: generated.keep).applyDictionary(text)
                if got != expected || gotFixes != expectedFixes {
                    Issue.record("case \(caseNumber): \(generated.describe(text)) -> \(got.debugDescription) (\(gotFixes)), expected \(expected.debugDescription) (\(expectedFixes))")
                    return
                }
                paths[matcher.apply(text, keep: generated.keep).map { "\($0.path)" } ?? "regex", default: 0] += 1
            }
        }
        print("dictionary matcher fuzz paths:", paths.sorted { $0.key < $1.key })
        #expect((paths["batch"] ?? 0) > 1_000, "the one-pass route should carry most cases: \(paths)")
        #expect((paths["rescan"] ?? 0) > 100, "cascades should reach the rescan route: \(paths)")
        #expect((paths["regex"] ?? 0) > 0, "text the matcher declines should reach the regex route: \(paths)")
    }

    @Test("a plain sentence takes the one-pass route, a cascade the rescan route")
    func routes() {
        let plain = DictionaryMatcher(entries: [entry("Kubernetes", ["cooper netties"]), entry("Priya", ["pria"])])
        #expect(plain.apply("ask pria about cooper netties", keep: .empty)?.path == .batch)
        #expect(plain.apply("ask pria about cooper netties", keep: .empty)?.text == "ask Priya about Kubernetes")
        let cascade = DictionaryMatcher(entries: [entry("alpha", ["beta"]), entry("gamma", ["alpha"])])
        #expect(cascade.apply("say beta", keep: .empty)?.path == .rescan)
        #expect(cascade.apply("say beta", keep: .empty)?.text == "say gamma")
        let declined = DictionaryMatcher(entries: [entry("Strasse", ["straße"])])
        #expect(declined.apply("Straße", keep: .empty) == nil)
    }

    @Test("a scoped copy shares the matcher and each app scope gets its own Dictionary")
    func scopedCopiesAgree() {
        let personalizer = Personalizer(dictionary: [entry("Kubernetes", ["cooper netties"])])
        let first = personalizer.scoped(to: "app.one").apply("cooper netties").text
        let second = personalizer.scoped(to: nil).apply("cooper netties").text
        #expect(first == "Kubernetes")
        #expect(second == "Kubernetes")
    }

    @Test("the automaton finds every pattern, including ones inside others, once each")
    func automaton() {
        let patterns: [[UInt32]] = ["he", "she", "his", "hers", "e"].map { $0.unicodeScalars.map(\.value) }
        let machine = PhraseAutomaton(patterns: patterns)
        var found: [String] = []
        machine.scan(Array("ushers".unicodeScalars.map(\.value))) { found.append("\($0)@\($1)") }
        #expect(found.sorted() == ["0@4", "1@4", "3@6", "4@4"])
        #expect(machine.patternLengths == [2, 3, 3, 4, 1])
    }
}

private struct SplitMix64: RandomNumberGenerator {
    var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

/// A random Dictionary (small word pool so phrases overlap, nest and cascade) with sentences built from the same pool.
private struct GeneratedCase {
    private static let words = ["alpha", "beta", "gamma", "cat", "cats", "node", "js", "kube", "net", "a", "x", "jim", "lord", "com", "dot", "café", "zoe", "lard"]
    private static let terms = ["Alpha", "Beta", "gamma", "Node.js", "C++", "Jim Lord", "jimlord.com", "@cat", "x-y", "Kube", "Cats'", "Dot Com",
                                "A", "www.jim.com", "(a)", "Zoë", "alpha beta", "beta alpha", "X", "Strasse"]
    private static let joiners = [" ", " ", " ", " ", "  ", "-", ".", "'"]
    private static let separators = [" ", " ", " ", " ", ", ", ".", " - ", "  ", "'s", "\n", "!", "-", "(", ")", ""]

    let entries: [DictionaryEntry]
    let texts: [String]
    let keep: KeepHeardSet
    private let keepPairs: [(String, String)]

    init(_ random: inout SplitMix64) {
        var entries: [DictionaryEntry] = []
        for _ in 0..<Int.random(in: 1...8, using: &random) {
            let term = Self.terms.randomElement(using: &random)!
            let heard = (0..<Int.random(in: 0...3, using: &random)).map { _ in Self.phrase(&random) }
            entries.append(DictionaryEntry(term: term, soundsLike: heard))
        }
        var pairs: [(String, String)] = []
        for _ in 0..<Int.random(in: 0...2, using: &random) {
            if let picked = entries.randomElement(using: &random), let phrase = picked.soundsLike.randomElement(using: &random) {
                pairs.append((phrase.lowercased(), picked.term))
            }
        }
        let pieces = entries.flatMap { [$0.term] + $0.soundsLike } + Self.words
        self.entries = entries
        self.keepPairs = pairs
        self.keep = KeepHeardSet(swaps: pairs.map { VocabularySwap(heard: $0.0, written: $0.1, source: .dictionaryAlias) })
        self.texts = (0..<6).map { _ in
            var text = ""
            for _ in 0..<Int.random(in: 1...14, using: &random) {
                var piece = pieces.randomElement(using: &random)!
                if Int.random(in: 0..<5, using: &random) == 0 { piece = piece.uppercased() }
                if Int.random(in: 0..<5, using: &random) == 0 { piece = piece.capitalized }
                text += piece + Self.separators.randomElement(using: &random)!
            }
            return text
        }
    }

    private static func phrase(_ random: inout SplitMix64) -> String {
        var phrase = Int.random(in: 0..<30, using: &random) == 0 ? "straße" : words.randomElement(using: &random)!
        for _ in 0..<Int.random(in: 0...2, using: &random) {
            phrase += joiners.randomElement(using: &random)! + words.randomElement(using: &random)!
        }
        return Int.random(in: 0..<6, using: &random) == 0 ? phrase.capitalized : phrase
    }

    func describe(_ text: String) -> String {
        "entries \(entries.map { "\($0.term.debugDescription)<-\($0.soundsLike)" }) keep \(keepPairs) text \(text.debugDescription)"
    }
}
