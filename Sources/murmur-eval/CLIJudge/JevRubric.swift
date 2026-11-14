import CryptoKit
import Foundation

/// Rubric v2 for TypeSafe's Jev: one request per (spoken, output) pair carrying narrow, typed
/// judgments grounded in the cleanup level's promise (Verbatim / Clean / Polished, see
/// `docs/guide/HUSHY_GUIDE.md` §2.3). Code, not the model, turns those judgments into a verdict
/// (`JevJudgment.verdict`), following TypeSafe's guidance: one atomic question per condition,
/// fault questions phrased so a high value means "yes, the fault is present", an explicit
/// "any serious violation" rule in code, and numbers/negations double-checked by deterministic
/// checks rather than trusted to the model (Jev 1.13 jaggedness: numeric precision, literal
/// reading). Calibration: `murmur-eval judge calibrate`, results in `Evals/JUDGES.md`.
enum JevRubric {
    static let version = "v2"
    /// Pinned model id, not the alias, so calibrated thresholds don't drift when `jev-latest`
    /// moves (TypeSafe models page: "pin that version's ID instead of the alias").
    static let model = "jev-1.13.0"

    /// What each level promises the user — the yardstick for `over_edited` and for how much
    /// clean-up is expected. Wording follows the product guide, not any golden case.
    static func promise(for level: String) -> String {
        switch level.lowercased() {
        case "verbatim":
            "Verbatim: only spoken commands such as 'new line' or 'press enter' are executed. Every other word, "
                + "including fillers and repeats, stays exactly as spoken."
        case "polished":
            "Polished: everything Clean does, plus fixing grammar and smoothing awkward phrasing into natural "
                + "typed prose. It keeps every fact, name, number and negation, keeps the speaker's voice, and "
                + "never adds content, summarizes, or changes tone."
        default:
            "Clean: removes filler words, stutters, aborted fragments and abandoned restarts; resolves the "
                + "speaker's self-corrections to the final version; fixes punctuation and capitalization; turns "
                + "a dictated list into a list; writes spoken numbers as digits; may fix clearly broken grammar "
                + "(for example 'the tests was failing' becomes 'the tests were failing'). It keeps the speaker's "
                + "own words otherwise: no synonyms, no rephrasing for style, no reordering, no more formal tone."
        }
    }

    static func displayLevel(_ level: String) -> String {
        switch level.lowercased() {
        case "verbatim": "Verbatim"
        case "polished": "Polished"
        default: "Clean"
        }
    }

    typealias JSON = TypeSafeClient.AnyJSON

    /// State: only what the questions need (context rot is a documented Jev failure mode).
    /// `reference` is optional: with it, Jev also sees one acceptable cleanup (wording may differ).
    static func state(level: String, spoken: String, output: String, reference: String?) -> JSON {
        var fields: [String: JSON] = [
            "level": .string(displayLevel(level)),
            "level_rules": .string(promise(for: level)),
            "spoken": .string(spoken),
            "output": .string(output),
        ]
        if let reference { fields["reference"] = .string(reference) }
        return .object(fields)
    }

    static let faultKeys = ["dropped_content", "changed_fact", "disfluency_left", "correction_left", "over_edited"]
    static let listOptions = ["layout_ok", "list_missing", "list_unwanted", "list_items_wrong"]

    /// The eight typed questions, all answered in parallel over the same state.
    static func questions(hasReference: Bool) -> [String: TypeSafeClient.Question] {
        let refNote = hasReference
            ? " `reference` is one acceptable cleanup; different wording or punctuation in `output` is fine." : ""
        return [
            "meaning": .init(
                type: .score,
                instructions: .string(
                    "How much of what the speaker still meant in `spoken` (after applying their own self-corrections) "
                        + "does `output` keep? Content the speaker retracted ('no wait', 'scratch that', 'actually "
                        + "forget X') should be gone. Ignore wording, punctuation and layout." + refNote),
                criteria: .array([
                    .string("`output` contradicts the speaker or changes a key fact: a different name, number, date, time, amount, negation, or who does what."),
                    .string("`output` leaves out an important request, fact, item or clause the speaker still meant."),
                    .string("`output` loses or blurs one minor detail, but every name, number, negation and request is intact."),
                    .string("`output` keeps every fact, request, item, name, number and negation the speaker still meant, and adds nothing."),
                ])),
            "dropped_content": .init(
                type: .noul,
                instructions: .string(
                    "Does `output` leave out any fact, list item, name, number, time, reason or request that the speaker "
                        + "still meant in `spoken`? Words the speaker retracted or corrected away, and pure fillers, "
                        + "do not count as dropped."),
                criteria: .strings([
                    "true": "Something the speaker still meant is missing from `output`.",
                    "false": "Everything the speaker still meant is present in `output`.",
                ])),
            "changed_fact": .init(
                type: .noul,
                instructions: .string(
                    "Does `output` state a name, number, date, time, amount or place differently from the speaker's "
                        + "final words in `spoken`, flip a negation (adds or removes 'not', 'never', 'don't', 'can't'), "
                        + "or add a claim the speaker never made?"),
                criteria: .strings([
                    "true": "At least one name, number, date, negation or claim in `output` differs from what the speaker finally said.",
                    "false": "Every name, number, date, negation and claim in `output` matches the speaker's final words.",
                ])),
            "disfluency_left": .init(
                type: .noul,
                instructions: .string(
                    "Does `output` still contain a speech disfluency: a filler (um, uh, er, like, you know, basically, "
                        + "sort of, I mean used as filler), a stuttered or accidentally repeated word, an aborted word "
                        + "fragment, or an abandoned false start? Deliberate repeats such as 'had had' or 'very very', "
                        + "and meaningful words such as a contrastive 'actually', are not disfluencies."),
                criteria: .strings([
                    "true": "`output` still has at least one filler, stutter, fragment or false start.",
                    "false": "`output` reads without any filler, stutter, fragment or false start.",
                ])),
            "correction_left": .init(
                type: .noul,
                instructions: .string(
                    "The speaker corrects themselves in `spoken` (for example 'at 10, no, 9', 'Tuesday, I mean "
                        + "Wednesday', 'scratch that'), and `output` still contains the retracted earlier version or the "
                        + "correction cue itself."),
                criteria: .strings([
                    "true": "`output` keeps a version the speaker took back, or the cue words of the correction.",
                    "false": "`spoken` has no self-correction, or `output` keeps only the speaker's final version.",
                ])),
            "over_edited": .init(
                type: .noul,
                instructions: .object([
                    "question": .string(
                        "Does `output` change the speaker's wording more than `level_rules` allows for `level`? "
                            + "Count synonyms swapped in, rephrased or reordered clauses, a more formal or different "
                            + "tone, summarizing, and added words. Removing disfluencies, resolving corrections, "
                            + "punctuation, capitalization, list layout and digits for spoken numbers are allowed "
                            + "at every level except Verbatim."),
                ]),
                criteria: .strings([
                    "true": "`output` rewrites the speaker's words beyond what `level` allows.",
                    "false": "Every change in `output` is one `level` allows.",
                ])),
            "reads_clean": .init(
                type: .noul,
                instructions: .string(
                    "Does `output` read as clean text someone typed: complete, correctly punctuated sentences or a "
                        + "tidy list, with questions ending in a question mark?"),
                criteria: .strings([
                    "true": "`output` reads as clean typed text.",
                    "false": "`output` still reads like a raw transcript or has broken punctuation.",
                ])),
            "list_layout": .init(
                type: .choice,
                instructions: .string(
                    "Is the layout of `output` right? A dictated list (the speaker enumerates items with 'first, "
                        + "second', 'bullet', 'number one', or asks for a list) should become a list; ordinary sentences, "
                        + "including a short 'X, Y and Z' series inside a sentence, should stay prose."
                        + (hasReference ? " `reference` shows the intended layout." : "")),
                criteria: .strings([
                    "layout_ok": "`output` is a list exactly when the speaker dictated one, with each item on its own line, or is prose when no list was dictated.",
                    "list_missing": "The speaker dictated a list but `output` runs the items together as prose.",
                    "list_unwanted": "`output` turns ordinary sentences into a list the speaker never dictated.",
                    "list_items_wrong": "`output` is a list, but items are merged, split, missing or out of order.",
                ])),
        ]
    }

    /// The request body key for caching: model + rubric version + full encoded request.
    static func cacheKey(state: JSON, questions: [String: TypeSafeClient.Question]) -> String {
        let request = TypeSafeClient.Request(state: state, model: model, questions: questions)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let body = (try? encoder.encode(request)) ?? Data()
        let hex = SHA256.hash(data: body).map { String(format: "%02x", $0) }.joined()
        return "jev__\(model)__\(version)__\(hex)"
    }
}

/// Jev's typed answers for one output, decoded from a v2 response. Raw probabilities are kept so
/// thresholds can move in code without re-running inference.
struct JevJudgment: Codable, Equatable, Sendable {
    /// Probability per meaning level, index 0 = "contradicts" … 3 = "keeps everything".
    let meaningProbabilities: [Double]
    let meaningConfidence: Double
    let droppedContent: Double
    let changedFact: Double
    let disfluencyLeft: Double
    let correctionLeft: Double
    let overEdited: Double
    let readsClean: Double
    let listLayout: String
    let listProbabilities: [String: Double]
    let inputTokens: Int?
    let modelID: String?

    /// 1…4 (probability-weighted), 4 = fully preserved.
    var meaning: Double {
        meaningProbabilities.enumerated().reduce(0) { $0 + Double($1.offset + 1) * $1.element }
    }

    /// P(meaning is at level 1 or 2: a key fact changed or something important dropped).
    var meaningBroken: Double { meaningProbabilities.prefix(2).reduce(0, +) }

    /// P(layout is wrong in any way).
    var layoutWrong: Double { 1 - (listProbabilities["layout_ok"] ?? 1) }

    /// Fault probabilities used by the verdict, keyed for reports.
    var faults: [String: Double] {
        [
            "meaning_broken": meaningBroken, "dropped_content": droppedContent, "changed_fact": changedFact,
            "disfluency_left": disfluencyLeft, "correction_left": correctionLeft, "over_edited": overEdited,
            "layout_wrong": layoutWrong, "reads_unclean": 1 - readsClean,
        ]
    }

    /// The faults the verdict uses (all are reported). Chosen by the calibration in
    /// `Evals/JUDGES.md`.
    static let verdictFaults: Set<String> = [
        "meaning_broken", "dropped_content", "changed_fact", "disfluency_left", "correction_left", "over_edited",
        "layout_wrong", "reads_unclean",
    ]

    /// "Any serious violation": the highest verdict-fault probability. Not a calibrated joint
    /// probability — a ranking score for thresholding and reliability tables.
    var pBad: Double { faults.filter { Self.verdictFaults.contains($0.key) }.values.max() ?? 0 }

    /// Meaning-only fault score (dropped / changed / broken) — for "is the meaning safe?" uses
    /// such as the model-first A/B, where style is judged separately.
    var pMeaningBad: Double { max(meaningBroken, droppedContent, changedFact) }

    struct Thresholds: Sendable {
        var fault: Double = 0.5
        static let standard = Thresholds()
    }

    func passed(_ thresholds: Thresholds = .standard) -> Bool { pBad < thresholds.fault }

    /// Confidence-routed verdict (calibration, `Evals/JUDGES.md`): below 0.3 the observed bad rate
    /// was 3–22%, above 0.7 it was 88–100%; the band between is "unsure" and goes to a human.
    enum Band: String, Sendable { case pass, unsure, fail }
    static let passBelow = 0.3
    static let failAtOrAbove = 0.7

    var band: Band { pBad < Self.passBelow ? .pass : (pBad >= Self.failAtOrAbove ? .fail : .unsure) }

    /// The faults at or above threshold, for disagreement reports.
    func firedFaults(_ thresholds: Thresholds = .standard) -> [String] {
        faults.filter { Self.verdictFaults.contains($0.key) && $0.value >= thresholds.fault }.map(\.key).sorted()
    }

    static func decode(_ response: TypeSafeClient.Response) throws -> JevJudgment {
        let answers = response.answers
        guard let meaning = answers["meaning"], let meaningProbs = meaning.probabilities,
              let dropped = answers["dropped_content"]?.noul, let changed = answers["changed_fact"]?.noul,
              let disfluency = answers["disfluency_left"]?.noul, let correction = answers["correction_left"]?.noul,
              let overEdited = answers["over_edited"]?.noul, let readsClean = answers["reads_clean"]?.noul,
              let list = answers["list_layout"], let listChoice = list.choice
        else { throw TypeSafeClient.ClientError.decoding("Jev v2 response is missing one or more answers") }
        let levels = (0..<4).map { meaningProbs[String($0)] ?? 0 }
        return JevJudgment(
            meaningProbabilities: levels, meaningConfidence: meaning.confidence ?? 0,
            droppedContent: dropped, changedFact: changed, disfluencyLeft: disfluency,
            correctionLeft: correction, overEdited: overEdited, readsClean: readsClean,
            listLayout: listChoice, listProbabilities: list.probabilities ?? [:],
            inputTokens: response.usage?.inputTokens, modelID: response.model)
    }
}
