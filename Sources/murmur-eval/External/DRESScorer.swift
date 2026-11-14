import Foundation

/// DRES's disfluency-removal scoring (Teleki et al., "DRES: Benchmarking LLMs for Disfluency
/// Removal", arXiv 2509.20321), ported from the paper's own code (github.com/mariateleki/dres,
/// MIT: `utils_evaluate.py` `align` / `build_alignment_df` / `e_prf` / `z_eip`, aggregated as in
/// `data_6_analyze_results.py`).
///
/// Every gold token is tagged `NONE` (fluent, must stay) or one of the disfluency classes
/// `EDITED` (reparandum: restarts, repairs, repetitions), `INTJ` (fillers, discourse markers) or
/// `PRN` (parentheticals/editing terms such as "you know", "I mean"). The model's output is
/// stripped of `,.!?`, Treebank-tokenized and lower-cased, then aligned to the disfluent tokens
/// with Gestalt pattern matching in which *disfluent* gold tokens are disguised so they align
/// late. A gold token is "removed" when it has no aligned output token.
///
///   E_P = removed disfluent / all removed          (low = over-deletion of fluent words)
///   E_R = removed disfluent / all disfluent        (low = under-deletion)
///   Z_E / Z_I / Z_P = share of EDITED / INTJ / PRN tokens removed
///
/// Output tokens that match nothing (rewrites, hallucinations) are ignored by E and Z, exactly as
/// in the paper — the Hushy guard view (`ExternalGuards`) counts them separately.
enum DRESScorer {
    enum Tag: String, Codable, CaseIterable, Sendable {
        case none = "NONE", edited = "EDITED", intj = "INTJ", prn = "PRN"
        var isDisfluent: Bool { self != .none }
    }

    /// One row of the paper's alignment frame. `gold` is nil for an inserted output token ("*").
    struct AlignedToken: Equatable {
        let disfluent: String
        let tag: Tag?
        let generated: String
        /// 1 when the gold token was removed, 0 when kept, nil for an inserted output token.
        var removed: Bool? { tag == nil ? nil : disfluent != generated }
    }

    struct Counts: Equatable, Sendable, Codable {
        var tp = 0, fp = 0, fn = 0, tn = 0
        /// Output tokens aligned to no gold token.
        var inserted = 0
        /// Per disfluency class: (total, removed).
        var classTotals: [String: Int] = [:]
        var classRemoved: [String: Int] = [:]

        static func + (lhs: Counts, rhs: Counts) -> Counts {
            var out = lhs
            out.tp += rhs.tp; out.fp += rhs.fp; out.fn += rhs.fn; out.tn += rhs.tn
            out.inserted += rhs.inserted
            out.classTotals.merge(rhs.classTotals, uniquingKeysWith: +)
            out.classRemoved.merge(rhs.classRemoved, uniquingKeysWith: +)
            return out
        }
    }

    /// Per-row scores in [0, 1]; NaN where the paper's Python yields NaN (a zero denominator).
    struct Scores: Sendable {
        let precision: Double, recall: Double, f1: Double
        let zEdited: Double, zIntj: Double, zPrn: Double
    }

    // MARK: Tokenisation (paper: `align`)

    /// Output side: strip `,.!?`, Treebank-tokenize, lower-case.
    static func outputTokens(_ text: String) -> [String] {
        let stripped = String(text.unicodeScalars.filter { !",.!?".unicodeScalars.contains($0) })
        return TreebankWordTokenizer.tokenize(stripped).map { $0.lowercased() }
    }

    /// Gold side for sets that ship text rather than Treebank trees: the same pipeline, minus
    /// tokens that are only punctuation (tree leaves carry no punctuation in the paper's data).
    static func goldTokens(_ text: String) -> [String] {
        outputTokens(text).filter { token in token.unicodeScalars.contains { CharacterSet.alphanumerics.contains($0) } }
    }

    // MARK: Alignment (paper: `build_alignment_df`)

    static func align(tokens: [String], tags: [Tag], generated: String) -> [AlignedToken] {
        precondition(tokens.count == tags.count, "token/tag count mismatch")
        let disfluent = tokens.map { $0.lowercased() }
        return align(disfluent: disfluent, tags: tags, generatedTokens: outputTokens(generated))
    }

    static func align(disfluent d: [String], tags: [Tag], generatedTokens g: [String]) -> [AlignedToken] {
        // Disfluent gold tokens get a suffix so they can only align inside "replace" blocks.
        let prime = zip(d, tags).map { word, tag in tag == .none ? word : "\(word)§\(tag.rawValue)" }
        var rows: [AlignedToken] = []
        for op in SequenceMatcher(prime, g).opcodes {
            switch op.tag {
            case .equal:
                for k in 0..<(op.i2 - op.i1) {
                    rows.append(AlignedToken(disfluent: d[op.i1 + k], tag: tags[op.i1 + k], generated: g[op.j1 + k]))
                }
            case .delete:
                for k in op.i1..<op.i2 { rows.append(AlignedToken(disfluent: d[k], tag: tags[k], generated: "")) }
            case .insert:
                for k in op.j1..<op.j2 { rows.append(AlignedToken(disfluent: "", tag: nil, generated: g[k])) }
            case .replace:
                // Disfluent tokens the output kept are matched by count; the rest were removed.
                var available: [String: Int] = [:]
                for token in g[op.j1..<op.j2] { available[token, default: 0] += 1 }
                for k in op.i1..<op.i2 {
                    let token = d[k]
                    if let count = available[token], count > 0 {
                        rows.append(AlignedToken(disfluent: token, tag: tags[k], generated: token))
                        available[token] = count - 1
                    } else {
                        rows.append(AlignedToken(disfluent: token, tag: tags[k], generated: ""))
                    }
                }
                // Python iterates a dict built from a set here; the order only moves "*" rows.
                for token in g[op.j1..<op.j2] {
                    guard let count = available[token], count > 0 else { continue }
                    rows.append(AlignedToken(disfluent: "", tag: nil, generated: token))
                    available[token] = count - 1
                }
            }
        }
        return rows
    }

    // MARK: Metrics (paper: `e_prf`, `z_eip`)

    static func counts(_ rows: [AlignedToken]) -> Counts {
        var counts = Counts()
        for row in rows {
            guard let tag = row.tag, let removed = row.removed else {
                counts.inserted += 1
                continue
            }
            switch (tag.isDisfluent, removed) {
            case (true, true): counts.tp += 1
            case (true, false): counts.fn += 1
            case (false, true): counts.fp += 1
            case (false, false): counts.tn += 1
            }
            if tag.isDisfluent {
                counts.classTotals[tag.rawValue, default: 0] += 1
                if removed { counts.classRemoved[tag.rawValue, default: 0] += 1 }
            }
        }
        return counts
    }

    static func scores(_ c: Counts) -> Scores {
        let p = c.tp + c.fp > 0 ? Double(c.tp) / Double(c.tp + c.fp) : .nan
        let r = c.tp + c.fn > 0 ? Double(c.tp) / Double(c.tp + c.fn) : .nan
        // Python: `2*p*r/(p+r) if p+r else nan` — NaN is truthy, so NaN propagates.
        let f = (p + r).isNaN || p + r == 0 ? .nan : 2 * p * r / (p + r)
        func z(_ tag: Tag) -> Double {
            let total = c.classTotals[tag.rawValue] ?? 0
            return total > 0 ? Double(c.classRemoved[tag.rawValue] ?? 0) / Double(total) : .nan
        }
        return Scores(precision: p, recall: r, f1: f, zEdited: z(.edited), zIntj: z(.intj), zPrn: z(.prn))
    }

    // MARK: Aggregation

    /// The paper's aggregate: each metric is the mean of the per-row values, skipping NaN rows
    /// (pandas `mean`), reported ×100. DRES rows are whole Switchboard conversations.
    struct Aggregate: Sendable {
        let precision: Double, recall: Double, f1: Double
        let zEdited: Double, zIntj: Double, zPrn: Double

        init(rows: [Scores]) {
            func mean(_ values: [Double]) -> Double {
                let finite = values.filter { !$0.isNaN }
                return finite.isEmpty ? .nan : 100 * finite.reduce(0, +) / Double(finite.count)
            }
            precision = mean(rows.map(\.precision))
            recall = mean(rows.map(\.recall))
            f1 = mean(rows.map(\.f1))
            zEdited = mean(rows.map(\.zEdited))
            zIntj = mean(rows.map(\.zIntj))
            zPrn = mean(rows.map(\.zPrn))
        }

        /// Pooled ("micro") view: one P/R/F over all tokens, ×100 — steadier than the per-row mean
        /// when rows are single utterances rather than conversations.
        init(pooled counts: Counts) {
            let s = DRESScorer.scores(counts)
            precision = 100 * s.precision; recall = 100 * s.recall; f1 = 100 * s.f1
            zEdited = 100 * s.zEdited; zIntj = 100 * s.zIntj; zPrn = 100 * s.zPrn
        }
    }
}
