import Foundation

/// Public, citable disfluency-removal sets that are free to download without accepting licence
/// terms, scored with DRES's metric (`DRESScorer`). See docs/product/EXTERNAL-BENCHMARKS.md for
/// the full candidate review, including the sets that need an LDC licence (DRES itself,
/// MultiTurnCleanup, Switchboard/Fisher) and are therefore *not* here.
enum ExternalBenchmark: String, CaseIterable, Sendable {
    /// Wang & Herremans 2024 (arXiv 2406.08820): Switchboard-1 utterances re-recorded by one
    /// speaker, with verbatim (A), fillers-removed (B) and false-starts-removed (C) transcripts.
    case disfluencySpeech = "disfluencyspeech"
    /// Gupta et al. 2021 (ACL Findings, arXiv 2106.04016): SQuAD-v2 questions rewritten by
    /// annotators with a self-correction or restart ("… no wait …"), paired with the original.
    case disflQA = "disflqa"

    var huggingFaceID: String {
        switch self {
        case .disfluencySpeech: "amaai-lab/DisfluencySpeech"
        case .disflQA: "google-research-datasets/disfl_qa"
        }
    }

    var defaultSplit: String { "test" }

    var splits: [String] { ["train", "validation", "test"] }

    var license: String {
        switch self {
        case .disfluencySpeech:
            "Apache-2.0 as declared on the Hugging Face card (ungated). Text derives from Switchboard-1 "
                + "transcripts (LDC97S62 lineage): evaluation use only, do not redistribute the text."
        case .disflQA: "CC-BY-4.0 (Google; questions derive from SQuAD 2.0, CC-BY-SA-4.0). Attribution required."
        }
    }

    var citation: String {
        switch self {
        case .disfluencySpeech: "Wang & Herremans, DisfluencySpeech, TENCON 2024, arXiv:2406.08820"
        case .disflQA: "Gupta et al., Disfl-QA, Findings of ACL 2021, arXiv:2106.04016"
        }
    }

    var summary: String {
        switch self {
        case .disfluencySpeech: "DisfluencySpeech — conversational Switchboard utterances: fillers, discourse markers, restarts, repairs"
        case .disflQA: "Disfl-QA — questions with an annotator-written self-correction or restart"
        }
    }

    /// Builds an item from one datasets-server row, or nil if the row lacks the text fields.
    func item(from row: [String: Any], index: Int) -> ExternalItem? {
        switch self {
        case .disfluencySpeech:
            guard let a = row["transcript_a"] as? String, let b = row["transcript_b"] as? String,
                  let c = row["transcript_c"] as? String, !a.isEmpty else { return nil }
            return ExternalItem(id: "dfs-\(index)", disfluent: a, fluent: c, intermediate: b, sourceRow: index)
        case .disflQA:
            guard let disfluent = row["disfluent question"] as? String,
                  let original = row["original question"] as? String, !disfluent.isEmpty else { return nil }
            let id = (row["squad_v2_id"] as? String).map { "dqa-\($0)" } ?? "dqa-\(index)"
            return ExternalItem(id: id, disfluent: disfluent, fluent: original, intermediate: nil, sourceRow: index)
        }
    }

    /// Gold tokens and DRES tags for one item.
    func gold(for item: ExternalItem) -> ExternalGold {
        switch self {
        case .disfluencySpeech: ExternalGold.fromLevels(verbatim: item.disfluent, noFillers: item.intermediate ?? item.disfluent, fluent: item.fluent)
        case .disflQA: ExternalGold.fromPair(disfluent: item.disfluent, fluent: item.fluent)
        }
    }
}

/// One benchmark row: the text Hushy is given, and the gold fluent text.
struct ExternalItem: Codable, Equatable, Sendable {
    let id: String
    /// What the "speaker" said — the cleanup input.
    let disfluent: String
    /// The gold fluent text.
    let fluent: String
    /// DisfluencySpeech's transcript B (fillers removed, false starts kept), used to tell
    /// fillers from edits when tagging.
    let intermediate: String?
    let sourceRow: Int
}

/// A downloaded split plus its provenance. External sets are evaluation-only: never training or
/// prompt-tuning data (`FinetunePathGuard` and scripts/finetune/pathguard.py refuse their paths).
struct ExternalSetFile: Codable, Sendable {
    static let evaluationOnly = "evaluation-only: never use for training, fine-tuning, synthetic-data seeds or prompt tuning"

    let benchmark: String
    var usage: String = ExternalSetFile.evaluationOnly
    let huggingFaceID: String
    let split: String
    let license: String
    let citation: String
    let fetchedAt: String
    let totalSourceRows: Int
    let items: [ExternalItem]
}

/// Gold tokens with DRES tags, derived from the dataset's own fluent reference(s).
struct ExternalGold: Equatable, Sendable {
    let tokens: [String]
    let tags: [DRESScorer.Tag]
    /// False when a reference is not a token subsequence of the text above it, so tags could not
    /// be derived by deletion alone. Such DisfluencySpeech rows are skipped (and counted).
    let derivedByDeletion: Bool

    static let fillerWords: Set<String> = ["uh", "um", "umm", "uhm", "uhh", "er", "erm", "ah", "eh", "hmm", "mm", "oh"]

    /// Parentheticals the Switchboard Treebank brackets as PRN; other removed non-sentence
    /// elements (fillers, "well", "like", "so") count as INTJ. Only the Z_P/Z_I split depends
    /// on this list — E_P/E_R/E_F do not.
    static let parentheticals: [[String]] = [
        ["you", "know"], ["i", "mean"], ["you", "see"], ["i", "guess"], ["i", "think"],
        ["let", "'s", "see"], ["let", "me", "see"],
    ]

    /// For each token of `upper`: the index it keeps in `lower`, or nil if deleted; plus whether
    /// `lower` is a pure deletion of `upper` under Gestalt alignment.
    static func deletionMap(_ upper: [String], _ lower: [String]) -> (map: [Int?], byDeletion: Bool) {
        var map = [Int?](repeating: nil, count: upper.count)
        var byDeletion = true
        for op in SequenceMatcher(upper, lower).opcodes {
            switch op.tag {
            case .equal: for k in 0..<(op.i2 - op.i1) { map[op.i1 + k] = op.j1 + k }
            case .delete: break
            case .insert, .replace: byDeletion = false
            }
        }
        return (map, byDeletion)
    }

    /// DisfluencySpeech: A→B deletions are non-sentence elements (INTJ/PRN), B→C deletions are
    /// false starts (EDITED).
    static func fromLevels(verbatim: String, noFillers: String, fluent: String) -> ExternalGold {
        let a = DRESScorer.goldTokens(verbatim)
        let b = DRESScorer.goldTokens(noFillers)
        let c = DRESScorer.goldTokens(fluent)
        let (aToB, cleanAB) = deletionMap(a, b)
        let (bToC, cleanBC) = deletionMap(b, c)
        var tags = [DRESScorer.Tag](repeating: .none, count: a.count)
        for (i, target) in aToB.enumerated() {
            if let j = target {
                tags[i] = bToC[j] == nil ? .edited : .none
            } else {
                tags[i] = .intj
            }
        }
        markParentheticals(tokens: a, tags: &tags)
        return ExternalGold(tokens: a, tags: tags, derivedByDeletion: cleanAB && cleanBC)
    }

    /// Disfl-QA: disfluent tokens outside the alignment with the original question are the
    /// disfluency (fillers → INTJ, everything else → EDITED). Rewrites that add words (the
    /// original is not a subsequence) are kept: E/Z only look at disfluent tokens.
    static func fromPair(disfluent: String, fluent: String) -> ExternalGold {
        let a = DRESScorer.goldTokens(disfluent)
        let (map, byDeletion) = deletionMap(a, DRESScorer.goldTokens(fluent))
        let tags: [DRESScorer.Tag] = zip(a, map).map { token, target in
            target != nil ? .none : (fillerWords.contains(token) ? .intj : .edited)
        }
        return ExternalGold(tokens: a, tags: tags, derivedByDeletion: byDeletion)
    }

    private static func markParentheticals(tokens: [String], tags: inout [DRESScorer.Tag]) {
        var i = 0
        while i < tokens.count {
            let match = parentheticals.first { phrase in
                i + phrase.count <= tokens.count
                    && Array(tokens[i..<(i + phrase.count)]) == phrase
                    && tags[i..<(i + phrase.count)].allSatisfy { $0 == .intj }
            }
            if let match {
                for k in i..<(i + match.count) { tags[k] = .prn }
                i += match.count
            } else {
                i += 1
            }
        }
    }
}

enum ExternalImporter {
    static let pageSize = 100

    static func file(_ benchmark: ExternalBenchmark, split: String, root: URL) -> URL {
        root.appendingPathComponent("external", isDirectory: true)
            .appendingPathComponent("\(benchmark.rawValue)-\(split).json")
    }

    /// Fetches the text columns of a split through the Hugging Face datasets-server `/rows` API
    /// (no audio, no licence click-through: both sets are ungated) and writes the set file.
    static func importSet(_ benchmark: ExternalBenchmark, split: String, root: URL) async throws -> ExternalSetFile {
        guard benchmark.splits.contains(split) else {
            throw EvalError.missing("\(benchmark.rawValue) has no split \(split) (expected \(benchmark.splits.joined(separator: "|")))")
        }
        let source = (dataset: benchmark.huggingFaceID, config: "default", split: split)
        var items: [ExternalItem] = []
        var offset = 0
        var seen = 0
        while true {
            let rows = try await Downloader.fetchRows(source: source, offset: offset, length: pageSize)
            for (k, row) in rows.enumerated() {
                if let item = benchmark.item(from: row, index: offset + k) { items.append(item) }
            }
            seen += rows.count
            offset += rows.count
            if rows.count < pageSize { break }
        }
        guard !items.isEmpty else { throw EvalError.download("\(benchmark.huggingFaceID) \(split): no rows") }
        let set = ExternalSetFile(
            benchmark: benchmark.rawValue, usage: ExternalSetFile.evaluationOnly, huggingFaceID: benchmark.huggingFaceID, split: split,
            license: benchmark.license, citation: benchmark.citation,
            fetchedAt: ISO8601DateFormatter().string(from: Date()), totalSourceRows: seen, items: items)
        let url = file(benchmark, split: split, root: root)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try encoder.encode(set).write(to: url, options: .atomic)
        return set
    }

    static func load(_ benchmark: ExternalBenchmark, split: String, root: URL) throws -> ExternalSetFile? {
        let url = file(benchmark, split: split, root: root)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return try JSONDecoder().decode(ExternalSetFile.self, from: Data(contentsOf: url))
    }

    /// `count` items spread evenly over the split (deterministic; every row when count ≥ size).
    static func evenSample<T>(_ items: [T], count: Int) -> [T] {
        guard count > 0, count < items.count else { return items }
        return (0..<count).map { items[$0 * items.count / count] }
    }
}
