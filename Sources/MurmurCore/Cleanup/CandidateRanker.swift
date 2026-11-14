import Foundation

/// Chooses between the rules' output and the model's refinement (both already passed their
/// guards). The model wins by default — it understands meaning — unless its version leaves
/// more unresolved correction words ("no", "actually", "forget") than the rules' version, or
/// it simply undid the rules' fixes and returned the raw words.
enum CandidateRanker {
    /// True when the cheap residue heuristic alone can't decide between `rules` and `model` —
    /// both leave the same amount of correction residue (commonly both zero) but the texts still
    /// differ, so there's an actual disagreement to resolve rather than an easy call. Exposed so
    /// `SmartCleaner` can decide whether the on-device rerank call (a real, separate model
    /// invocation, unlike everything else in this file) is worth making at all.
    static func isTie(raw: String, rules: String, model: String) -> Bool {
        rules != model && residue(model) == residue(rules)
    }

    static func prefersModel(
        raw: String, rules: String, model: String, assessment: SmartCleaner.Assessment? = nil
    ) -> Bool {
        let modelResidue = residue(model)
        let rulesResidue = residue(rules)
        // Cheap heuristic decides confidently on its own most of the time; only on a tie (see
        // `isTie`) does the on-device rerank signal (if one was fetched) get consulted below.
        if modelResidue != rulesResidue {
            return modelResidue < rulesResidue
        }
        let rawWords = EvalMetrics.normalizedWords(raw)
        let rulesChanged = EvalMetrics.normalizedWords(rules) != rawWords
        if rulesChanged, EvalMetrics.normalizedWords(model) == rawWords { return false }
        // Tie-break: a separate, budget-capped rerank call's structured answer (`isTie` above
        // gates when `SmartCleaner` even bothers making it). `.rules`/`.neither` override the
        // default (prefer the model) ONLY when the rerank also flagged real dropped information —
        // `droppedInformation == false` alongside a `.rules`/`.neither` preference means the
        // rerank had a stylistic preference for the rules' wording without pointing to anything
        // actually missing (observed on grammar-repair cases where the model correctly resolved a
        // stutter/restart but the rerank still leaned toward the untouched rules draft out of
        // caution), which is not the failure mode this tie-break exists to catch. `.model`/`.both`
        // and a missing assessment (call skipped, timed out, or model unavailable) leave the
        // original default (prefer the model) in place.
        if let assessment, assessment.droppedInformation, assessment.prefers == .rules || assessment.prefers == .neither {
            return false
        }
        return true
    }

    /// Correction cues still present in a candidate (an opening "No, …" answer doesn't count).
    static func residue(_ text: String) -> Int {
        let body = text.lowercased().replacingOccurrences(
            of: "^\\s*(?:no|nope|sorry|actually|wait|oops)\\b[,.!]?", with: "", options: .regularExpression)
        let padded = " " + body + " "
        return ModelHints.correctionCues.reduce(0) { count, cue in
            let pattern = "[\\s,.]\(NSRegularExpression.escapedPattern(for: cue))[\\s,.]"
            return count + (padded.range(of: pattern, options: .regularExpression) != nil ? 1 : 0)
        }
    }
}
