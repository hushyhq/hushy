import Foundation
import Testing

@testable import murmur_eval

/// `difflib.SequenceMatcher` port — expected values are CPython's documented outputs.
@Suite("External benchmarks · SequenceMatcher")
struct SequenceMatcherTests {
    private func chars(_ s: String) -> [String] { s.map(String.init) }

    @Test func opcodesMatchCPythonDocs() {
        let ops = SequenceMatcher(chars("qabxcd"), chars("abycdf")).opcodes
        #expect(ops == [
            .init(tag: .delete, i1: 0, i2: 1, j1: 0, j2: 0),
            .init(tag: .equal, i1: 1, i2: 3, j1: 0, j2: 2),
            .init(tag: .replace, i1: 3, i2: 4, j1: 2, j2: 3),
            .init(tag: .equal, i1: 4, i2: 6, j1: 3, j2: 5),
            .init(tag: .insert, i1: 6, i2: 6, j1: 5, j2: 6),
        ])
    }

    @Test func matchingBlocksMatchCPythonDocs() {
        #expect(SequenceMatcher(chars("abxcd"), chars("abcd")).matchingBlocks == [
            .init(a: 0, b: 0, size: 2), .init(a: 3, b: 2, size: 2), .init(a: 5, b: 4, size: 0),
        ])
    }

    @Test func longestMatchPrefersEarliestBlock() {
        #expect(SequenceMatcher(chars(" abcd"), chars("abcd abcd")).findLongestMatch(0, 5, 0, 9)
            == .init(a: 0, b: 4, size: 5))
    }
}

/// NLTK `TreebankWordTokenizer` port — expected values are NLTK's docstring outputs.
@Suite("External benchmarks · Treebank tokenizer")
struct TreebankWordTokenizerTests {
    @Test func nltkDocstringExamples() {
        let text = "Good muffins cost $3.88\nin New York.  Please buy me\ntwo of them.\nThanks."
        #expect(TreebankWordTokenizer.tokenize(text) == [
            "Good", "muffins", "cost", "$", "3.88", "in", "New", "York.", "Please", "buy", "me", "two",
            "of", "them.", "Thanks", ".",
        ])
        #expect(TreebankWordTokenizer.tokenize("They'll save and invest more.")
            == ["They", "'ll", "save", "and", "invest", "more", "."])
        #expect(TreebankWordTokenizer.tokenize("hi, my name can't hello,")
            == ["hi", ",", "my", "name", "ca", "n't", "hello", ","])
    }

    @Test func macIntyreContractions() {
        #expect(TreebankWordTokenizer.tokenize("I cannot, I'm gonna wait") == ["I", "can", "not", ",", "I", "'m", "gon", "na", "wait"])
    }
}

/// The paper's own scorer test (dres `tests/test_evaluate.py`), with the tree's tokens and tags.
@Suite("External benchmarks · DRES scorer")
struct DRESScorerTests {
    typealias Tag = DRESScorer.Tag
    // ((PRN I mean ,) (CC but) (EDITED she was truly ,) she was truly aware .)
    let tokens = ["I", "mean", "but", "she", "was", "truly", "she", "was", "truly", "aware"]
    let tags: [Tag] = [.prn, .prn, .none, .edited, .edited, .edited, .none, .none, .none, .none]

    @Test func alignmentMatchesThePaperFixture() {
        let rows = DRESScorer.align(tokens: tokens, tags: tags, generated: "I mean but cats was truly aware.")
        #expect(rows.map { $0.tag.map { $0.isDisfluent ? 1 : 0 } } == [1, 1, 0, 1, 1, 1, 0, nil, 0, 0, 0])
        #expect(rows.map { $0.removed.map { $0 ? 1 : 0 } } == [0, 0, 0, 1, 1, 1, 1, nil, 0, 0, 0])
        let s = DRESScorer.scores(DRESScorer.counts(rows))
        #expect(s.precision == 0.75)
        #expect(s.recall == 0.6)
        #expect(s.zEdited == 1)
        #expect(s.zPrn == 0)
        #expect(s.zIntj.isNaN)
    }

    @Test func punctuationAndCaseVariantsScoreIdentically() {
        let variants = [
            "I mean but cats was truly aware.", "I mean but cats was truly aware!", "I mean but... cats was truly aware",
            "I mean but. cats was truly aware.", "I mean but cats, was truly aware.", "I mean BUT cats, was truly aware.",
        ]
        let counts = variants.map { DRESScorer.counts(DRESScorer.align(tokens: tokens, tags: tags, generated: $0)) }
        #expect(Set(counts.map { "\($0.tp)/\($0.fp)/\($0.fn)" }).count == 1)
    }

    @Test func perfectRemovalAndNoRemoval() {
        let perfect = DRESScorer.scores(DRESScorer.counts(DRESScorer.align(tokens: tokens, tags: tags, generated: "But she was truly aware.")))
        #expect(perfect.precision == 1 && perfect.recall == 1 && perfect.f1 == 1)
        let untouched = DRESScorer.scores(DRESScorer.counts(DRESScorer.align(tokens: tokens, tags: tags, generated: tokens.joined(separator: " "))))
        #expect(untouched.precision.isNaN)
        #expect(untouched.recall == 0)
        #expect(untouched.f1.isNaN)
    }

    @Test func paperAggregationSkipsNaNAndPooledDoesNot() {
        let removedAll = DRESScorer.Counts(tp: 2, fp: 0, fn: 0, tn: 3)
        let removedNothing = DRESScorer.Counts(tp: 0, fp: 0, fn: 4, tn: 3)
        let paper = DRESScorer.Aggregate(rows: [removedAll, removedNothing].map(DRESScorer.scores))
        #expect(paper.precision == 100)   // the untouched row has NaN precision and drops out
        #expect(paper.recall == 50)
        let pooled = DRESScorer.Aggregate(pooled: removedAll + removedNothing)
        #expect(pooled.precision == 100)
        #expect(abs(pooled.recall - 100.0 / 3) < 1e-9)
    }
}

/// Gold derivation and the importer's row parsing.
@Suite("External benchmarks · importer and gold")
struct ExternalImporterTests {
    typealias Tag = DRESScorer.Tag

    @Test func disfluencySpeechLevelsTagFillersParentheticalsAndEdits() {
        // Test-split row 3's shape: A (verbatim) → B (non-sentence elements out) → C (false starts out).
        let gold = ExternalGold.fromLevels(
            verbatim: "Well, what about, uh, papyrus, you know, made out of bam-, you know, bamboo stuff, from the from the banks of the Nile.",
            noFillers: "what about, papyrus, made out of bam-, bamboo stuff, from the from the banks of the Nile.",
            fluent: "what about, papyrus, made out of bamboo stuff, from the banks of the Nile.")
        #expect(gold.derivedByDeletion)
        let tagged = Dictionary(zip(gold.tokens.indices, zip(gold.tokens, gold.tags)).map { ($0, $1) }, uniquingKeysWith: { a, _ in a })
        #expect(tagged[0]! == ("well", .intj))
        #expect(tagged[3]! == ("uh", .intj))
        #expect(tagged[5]! == ("you", .prn) && tagged[6]! == ("know", .prn))
        #expect(tagged[10]! == ("bam-", .edited))
        #expect(gold.tags.filter { $0 == .edited }.count == 3)   // "bam-" + one "from the"
        #expect(gold.tags.filter { $0 == .none }.count == 14)
    }

    @Test func disflQAPairTagsTheCorrection() {
        let gold = ExternalGold.fromPair(disfluent: "What is Denmark a region of uh no France?", fluent: "What is France a region of?")
        #expect(gold.tokens == ["what", "is", "denmark", "a", "region", "of", "uh", "no", "france"])
        #expect(gold.tags == [.none, .none, .edited, .none, .none, .none, .intj, .edited, .edited])
        #expect(!gold.derivedByDeletion)   // "France" moved: the original is not a subsequence
        let restart = ExternalGold.fromPair(disfluent: "When I mean Who was the Norse leader?", fluent: "Who was the Norse leader?")
        #expect(restart.derivedByDeletion)
        #expect(restart.tags.prefix(3) == [.edited, .edited, .edited])
    }

    @Test func rowsParseAndMissingFieldsAreSkipped() {
        let dqa = ExternalBenchmark.disflQA.item(
            from: ["squad_v2_id": "abc", "original question": "Who was the Norse leader?", "disfluent question": "When I mean Who was the Norse leader?"],
            index: 3)
        #expect(dqa == ExternalItem(id: "dqa-abc", disfluent: "When I mean Who was the Norse leader?", fluent: "Who was the Norse leader?", intermediate: nil, sourceRow: 3))
        #expect(ExternalBenchmark.disflQA.item(from: ["original question": "x"], index: 0) == nil)
        let dfs = ExternalBenchmark.disfluencySpeech.item(
            from: ["transcript_a": "Well, yes.", "transcript_b": "yes.", "transcript_c": "yes.", "audio": [:]], index: 7)
        #expect(dfs?.id == "dfs-7" && dfs?.intermediate == "yes.")
        #expect(ExternalBenchmark.disfluencySpeech.item(from: ["transcript_a": "", "transcript_b": "", "transcript_c": ""], index: 0) == nil)
    }

    @Test func setFileRoundTripsAndSamplingIsDeterministic() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = ExternalImporter.file(.disflQA, split: "test", root: root)
        #expect(url.lastPathComponent == "disflqa-test.json")
        #expect(try ExternalImporter.load(.disflQA, split: "test", root: root) == nil)
        let items = (0..<10).map { ExternalItem(id: "dqa-\($0)", disfluent: "a uh b", fluent: "a b", intermediate: nil, sourceRow: $0) }
        let set = ExternalSetFile(benchmark: "disflqa", huggingFaceID: "x", split: "test", license: "CC-BY-4.0",
                                  citation: "c", fetchedAt: "t", totalSourceRows: 10, items: items)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(set).write(to: url)
        let loaded = try ExternalImporter.load(.disflQA, split: "test", root: root)
        #expect(loaded?.items == items)
        #expect(loaded?.usage.hasPrefix("evaluation-only") == true)
        #expect(ExternalImporter.evenSample(items, count: 4).map(\.sourceRow) == [0, 2, 5, 7])
        #expect(ExternalImporter.evenSample(items, count: 50).count == 10)
    }
}

/// The Hushy guard view on top of DRES.
@Suite("External benchmarks · guards")
struct ExternalGuardTests {
    private func scored(_ gold: ExternalGold, fluent: String, output: String) -> ExternalRunner.Scored {
        let counts = DRESScorer.counts(DRESScorer.align(tokens: gold.tokens, tags: gold.tags, generated: output))
        let outcome = ExternalRunner.CaseOutcome(
            id: "dfs-0", input: "", output: output, fluent: fluent, goldTokens: gold.tokens, goldTags: gold.tags,
            counts: counts, exactMatch: false, usedModel: true, rejection: nil, latencyMs: 1)
        return ExternalRunner.Scored(outcome: outcome, scores: DRESScorer.scores(counts), outputWords: DRESScorer.outputTokens(output).count)
    }

    @Test func numberFormattingIsNotAMissingWordButDRESCountsIt() {
        let verbatim = "Well, it costs, uh, about seventeen dollars."
        let fluent = "it costs, about seventeen dollars."
        let gold = ExternalGold.fromLevels(verbatim: verbatim, noFillers: fluent, fluent: fluent)
        let summary = ExternalSummary(benchmark: .disfluencySpeech, outcomes: [scored(gold, fluent: fluent, output: "It costs about $17.")], skipped: 0)
        #expect(summary.fluentWordsMissing == 0)
        #expect(summary.pooledCounts.fp > 0)   // DRES: "seventeen dollars" removed, "$ 17" inserted
        let dropped = ExternalSummary(benchmark: .disfluencySpeech, outcomes: [scored(gold, fluent: fluent, output: "It costs.")], skipped: 0)
        #expect(dropped.fluentWordsMissing == 0.5)   // "about $17" of "it costs about $17"
    }

    @Test func fallbackBreakdownNamesWhyTheModelWasNotUsed() {
        let gold = ExternalGold.fromPair(disfluent: "a uh b", fluent: "a b")
        var rows = [scored(gold, fluent: "a b", output: "a b")]
        let outcome = rows[0].outcome
        rows.append(ExternalRunner.Scored(
            outcome: .init(id: "dqa-1", input: "", output: "a b", fluent: "a b", goldTokens: gold.tokens, goldTags: gold.tags,
                           counts: outcome.counts, exactMatch: true, usedModel: false, rejection: "timeout", latencyMs: 1),
            scores: rows[0].scores, outputWords: 2))
        #expect(ExternalSummary(benchmark: .disflQA, outcomes: rows, skipped: 0).fallbackBreakdown == "timeout 1")
    }
}
