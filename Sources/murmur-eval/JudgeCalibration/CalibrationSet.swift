import CryptoKit
import Foundation
import MurmurCore

/// The frozen, labeled reference set a judge is calibrated against (`Evals/judge-calibration.json`).
/// Built from the DEV golden sets only (dictation, overdeletion, reformat dev, user-dictation):
/// never `heldout-v2*`, never Voice Lab. Three kinds of item:
/// - `correct`: the golden reference itself (label good);
/// - seeded perturbations of the reference with one known fault (`JudgePerturbations`, label bad);
/// - `real_rules`: the current rules-only cleanup output where it differs from the reference,
///   provisionally labeled by the deterministic checks and then hand-reviewed (`labelSource`).
/// The file is committed so calibration is reproducible even after the golden sets or rules change;
/// `murmur-eval judge calibrate --build-set` regenerates it (re-review `real_rules` labels after).
struct CalibrationItem: Codable, Equatable, Sendable {
    let id: String
    let source: String
    let caseID: String
    let level: String
    let kind: String
    let spoken: String
    let reference: String
    let output: String
    /// "good" or "bad" at `level`.
    var label: String
    /// Fault dimensions a judge may name for a bad item (any one counts as a correct catch).
    var faults: [String]
    /// "construction" (perturbation/golden), "checks" (provisional), or "human" (hand-reviewed).
    var labelSource: String
    /// What the deterministic checks say for this output (exact match for golden sets, property
    /// checks for reformat-format sets), frozen at build time.
    let checksPassed: Bool
    var note: String?

    var isBad: Bool { label == "bad" }
}

/// Hand-review verdicts for `real_rules` items (`Evals/judge-calibration-labels.json`), applied
/// by the builder so `--build-set` is reproducible. `label: "exclude"` drops an ambiguous item.
struct CalibrationLabelOverride: Codable {
    let label: String
    let faults: [String]
    let note: String
}

struct CalibrationSetFile: Codable {
    let schemaVersion: Int
    let generatedAt: String
    let seed: Int
    let items: [CalibrationItem]
}

enum CalibrationSetBuilder {
    /// Per-kind caps for the sampled set (≈150 items, so v2 + ablations + repeats + pairwise fit
    /// the 300-call Jev budget).
    static let caps: [String: Int] = [
        "correct": 40, "alternative": 8, "dropped_number": 10, "negation_flip": 12, "kept_filler": 12, "over_edit": 10,
        "meaning_change": 12, "dropped_clause": 10, "raw_spoken": 10, "list_flattened": 5,
        "over_clean_negative": 8, "real_rules": 20,
    ]

    static let kindFaults: [String: [String]] = [
        "dropped_number": ["dropped_content", "changed_fact", "meaning_broken"],
        "negation_flip": ["changed_fact", "meaning_broken"],
        "kept_filler": ["disfluency_left"],
        "over_edit": ["over_edited"],
        "meaning_change": ["changed_fact", "meaning_broken"],
        "dropped_clause": ["dropped_content", "meaning_broken"],
        "raw_spoken": ["disfluency_left", "correction_left", "reads_unclean"],
        "list_flattened": ["layout_wrong"],
        "over_clean_negative": ["over_edited", "dropped_content", "changed_fact", "meaning_broken"],
    ]

    /// One golden case reduced to what the builder needs, from either golden format.
    struct Source {
        let source: String
        let caseID: String
        let level: String
        let spoken: String
        let reference: String
        let isNegative: Bool
        var alternatives: [String] = []
        let checks: (String) -> Bool
    }

    static func loadSources(evals: URL) throws -> [Source] {
        var sources: [Source] = []
        for (file, name) in [("dictation-golden.json", "dictation"), ("overdeletion-golden.json", "overdeletion")] {
            let cases = try JSONDecoder().decode([Runners.GoldenCase].self, from: Data(contentsOf: evals.appendingPathComponent(file)))
            for item in cases where item.expectedPressEnter != true {
                let accepted = item.accepted
                sources.append(Source(
                    source: name, caseID: item.id, level: "clean", spoken: item.spoken, reference: item.expected,
                    isNegative: false, alternatives: item.alternatives ?? [],
                    checks: { out in accepted.contains { EvalMetrics.layoutMatches($0, out) } }))
            }
        }
        for (file, name) in [("reformat-golden.json", "reformat"), ("user-dictation-golden.json", "user-dictation")] {
            let cases = try JSONDecoder().decode([ReformatChecks.Case].self, from: Data(contentsOf: evals.appendingPathComponent(file)))
            for item in cases {
                for level in ["clean", "polished"] {
                    guard let expectation = item.levels[level] else { continue }
                    // Polished only for the correct-reference items (see `build`); keep both here.
                    sources.append(Source(
                        source: name, caseID: item.id, level: level, spoken: item.input, reference: expectation.reference,
                        isNegative: item.isNegative,
                        checks: { out in ReformatChecks.evaluate(item, expectation: expectation, output: out).passed }))
                }
            }
        }
        return sources
    }

    /// Every candidate item before sampling. `rulesOutputs` maps "source/caseID/level" to the
    /// rules-only cleanup output.
    static func candidates(_ sources: [Source], rulesOutputs: [String: String]) -> [CalibrationItem] {
        var items: [CalibrationItem] = []
        func add(_ s: Source, kind: String, output: String?, label: String, faults: [String], note: String? = nil) {
            guard let output, !EvalMetrics.layoutMatches(output, s.reference) || kind == "correct" else { return }
            items.append(CalibrationItem(
                id: "\(kind):\(s.source):\(s.caseID):\(s.level)", source: s.source, caseID: s.caseID, level: s.level,
                kind: kind, spoken: s.spoken, reference: s.reference, output: output, label: label,
                faults: faults, labelSource: "construction", checksPassed: s.checks(output), note: note))
        }
        for s in sources {
            let seed = stableHash(s.caseID)
            add(s, kind: "correct", output: s.reference, label: "good", faults: [])
            for alternative in s.alternatives.prefix(1) {
                add(s, kind: "alternative", output: alternative, label: "good", faults: [],
                    note: "golden set lists this as an accepted alternative")
            }
            guard s.level == "clean" else { continue }
            if s.isNegative {
                add(s, kind: "over_clean_negative", output: JudgePerturbations.overClean(s.reference), label: "bad",
                    faults: kindFaults["over_clean_negative"]!)
                continue
            }
            let perturbations: [(String, String?)] = [
                ("dropped_number", JudgePerturbations.dropNumber(s.reference)),
                ("negation_flip", JudgePerturbations.flipNegation(s.reference)),
                ("kept_filler", JudgePerturbations.insertFiller(s.reference, seed: seed)),
                ("over_edit", JudgePerturbations.overEdit(s.reference)),
                ("meaning_change", JudgePerturbations.changeFact(s.reference)),
                ("dropped_clause", JudgePerturbations.dropClause(s.reference)),
                ("list_flattened", JudgePerturbations.flattenList(s.reference)),
            ]
            for (kind, output) in perturbations {
                add(s, kind: kind, output: output, label: "bad", faults: kindFaults[kind]!)
            }
            if hasDisfluency(s.spoken) {
                add(s, kind: "raw_spoken", output: s.spoken, label: "bad", faults: kindFaults["raw_spoken"]!)
            }
            if let rules = rulesOutputs["\(s.source)/\(s.caseID)/\(s.level)"] {
                let passed = s.checks(rules)
                add(s, kind: "real_rules", output: rules, label: passed ? "good" : "bad",
                    faults: [], note: passed ? "checks pass" : "checks fail")
                if let last = items.last, last.kind == "real_rules" { items[items.count - 1].labelSource = "checks" }
            }
        }
        return items
    }

    /// Applies hand-review overrides by item id; "exclude" removes the item.
    static func applyOverrides(_ items: [CalibrationItem], _ overrides: [String: CalibrationLabelOverride]) -> [CalibrationItem] {
        items.compactMap { item in
            guard let override = overrides[item.id] else { return item }
            if override.label == "exclude" { return nil }
            var updated = item
            updated.label = override.label
            updated.faults = override.faults
            updated.note = override.note
            updated.labelSource = "human"
            return updated
        }
    }

    /// Deterministic stratified sample: within each kind, order by hash(seed, id) and take the cap.
    /// For `correct`, a quarter of the slots go to Polished references.
    static func sample(_ items: [CalibrationItem], seed: Int) -> [CalibrationItem] {
        var chosen: [CalibrationItem] = []
        let byKind = Dictionary(grouping: items, by: \.kind)
        for kind in byKind.keys.sorted() {
            let cap = caps[kind] ?? 0
            let ordered = byKind[kind, default: []].sorted { stableHash("\(seed)|\($0.id)") < stableHash("\(seed)|\($1.id)") }
            if kind == "correct" {
                let polished = ordered.filter { $0.level == "polished" }.prefix(cap / 4)
                let clean = ordered.filter { $0.level == "clean" }.prefix(cap - polished.count)
                chosen += clean + polished
            } else {
                chosen += ordered.prefix(cap)
            }
        }
        return chosen
    }

    private static let disfluencyCues = [
        " um", " uh", "um ", "uh ", " like ", "you know", "basically", " no wait", "no, wait", "i mean",
        "scratch that", "sorry", " actually", ", no,",
    ]

    static func hasDisfluency(_ spoken: String) -> Bool {
        let lower = " " + spoken.lowercased() + " "
        return disfluencyCues.contains { lower.contains($0) }
    }

    static func stableHash(_ text: String) -> Int {
        let digest = SHA256.hash(data: Data(text.utf8))
        return digest.prefix(4).reduce(0) { ($0 << 8) | Int($1) }
    }
}
