import Foundation

/// When an observation becomes something Hushy uses.
public struct LearningPolicy: Sendable, Equatable {
    /// A term is used after this many edits (in distinct dictations) inside `termWindow`…
    public var termPromoteAfter: Int
    public var termWindow: TimeInterval
    /// …a style signal is offered after this many inside `styleWindow`; only confirmation activates it.
    public var stylePromoteAfter: Int
    public var styleWindow: TimeInterval
    /// Misrecognitions remembered per term.
    public var maxHeardAs: Int
    /// When true (the default: nothing that improves the app waits for an opt-in), a term that meets `termPromoteAfter`
    /// activates by itself and is announced with Undo ("Learned from your edits"); Forget stops it. When false, it stays a
    /// suggestion — "ready" (`LearnedItem.isReadySuggestion`) — and only the user's confirm activates it; that is for tests,
    /// the eval arms, and the `FeatureFlags.autoActivateLearnedTerms` kill switch. Style signals always await explicit confirmation.
    public var autoActivateTerms: Bool
    /// When true (the default), a term is judged on evidence: decayed counts of the times the person changed it and the
    /// times they left it as heard (`EvidenceCell`), so a word they usually leave alone is not learned from a couple of
    /// fixes. When false, the earlier rule applies: `termPromoteAfter` edits inside `termWindow`, nothing about words left alone.
    public var useEvidence: Bool
    /// How fast the counts fade. 8 days makes two fixes a day apart as strong as two fixes on one day, and two fixes
    /// `termWindow` apart exactly as strong as the earlier rule needed (see `promoteProbability`).
    public var termHalfLife: TimeInterval

    public init(
        termPromoteAfter: Int = 2, termWindow: TimeInterval = 14 * 86_400,
        stylePromoteAfter: Int = 3, styleWindow: TimeInterval = 30 * 86_400, maxHeardAs: Int = 5,
        autoActivateTerms: Bool = true, useEvidence: Bool = true, termHalfLife: TimeInterval = 8 * 86_400) {
        self.useEvidence = useEvidence
        self.termHalfLife = termHalfLife
        self.autoActivateTerms = autoActivateTerms
        self.termPromoteAfter = termPromoteAfter
        self.termWindow = termWindow
        self.stylePromoteAfter = stylePromoteAfter
        self.styleWindow = styleWindow
        self.maxHeardAs = maxHeardAs
    }

    public static let standard = LearningPolicy()

    /// The earlier rule: edits counted inside a window, nothing about words left alone.
    public static let editsOnly = LearningPolicy(useEvidence: false)

    /// How sure the evidence must be that the person wants the swap (P(θ > 0.5), `EvidenceMath`). It is the sureness
    /// the earlier rule had at its edge: `needed` fixes with the oldest exactly `termWindow` old. With nothing left alone
    /// that rule and this one promote on the same cases; a word the person also leaves alone needs more fixes. One fix
    /// is enough only for the narrow one-letter spelling repair (`needed` 1), which is judged on the fix just made.
    public func promoteProbability(needed: Int) -> Double {
        guard needed >= 2 else { return EvidenceMath.probabilityAboveHalf(edits: 1, kept: 0) }
        let edge = EvidenceMath.weight(afterSeconds: termWindow, halfLife: termHalfLife)
        return EvidenceMath.probabilityAboveHalf(edits: Double(needed - 1) + edge, kept: 0)
    }

    /// How far back left-alone evidence is looked up when a word becomes a candidate (History, counts only).
    public var backfillWindow: TimeInterval { 4 * termHalfLife }

    /// The policy the app uses right now (reads `FeatureFlags.autoActivateLearnedTerms`).
    public static var current: LearningPolicy {
        LearningPolicy(autoActivateTerms: FeatureFlags.autoActivateLearnedTerms, useEvidence: FeatureFlags.evidenceLearning)
    }
}

/// Pure, deterministic learning: folds correction captures into learned items. No I/O; the
/// `Store` wraps it in a transaction. Every function returns new values; inputs are untouched.
public enum Learner {
    /// One observation extracted from a capture, before merging.
    struct Observation: Equatable {
        let kind: LearnedItem.Kind
        let key: String
        let value: String
        let heardAs: String?
        let appBundleID: String?
    }

    /// Items that changed (updated or new) after folding `capture` into `existing`.
    /// `knownTerms` are the user's own Dictionary terms (lowercased). A correction *to* one of
    /// them is still learned as a taught "heard X, meant Y" pair — unless the user's own entry
    /// already lists that hearing (`knownHearings`: term → its lowercased "sounds like" phrases),
    /// in which case there is nothing new to learn. `styleKept` gives a habit's left-alone counts per app.
    public static func observe(
        _ capture: CorrectionCapture, existing: [LearnedItem], knownTerms: Set<String>,
        knownHearings: [String: Set<String>] = [:], policy: LearningPolicy = .standard,
        backfill: ((LearnedItem) -> [EvidenceCell])? = nil, styleKept: ((String) -> [EvidenceCell])? = nil
    ) -> [LearnedItem] {
        let byIdentity = Dictionary(existing.map { ($0.identity, $0) }, uniquingKeysWith: { first, _ in first })
        var changed: [String: LearnedItem] = [:]
        var order: [String] = []
        for observation in observations(from: capture) {
            if observation.kind == .term, knownTerms.contains(observation.key),
               isCovered(observation.heardAs, by: knownHearings[observation.key]) { continue }
            let identity = LearnedItem.identity(kind: observation.kind, key: observation.key, appBundleID: observation.appBundleID)
            let base = changed[identity] ?? byIdentity[identity]
            if base?.status == .forgotten { continue }
            var updated = merge(observation, into: base, capture: capture, policy: policy, backfill: backfill)
            if policy.useEvidence, updated.kind == .styleSignal {
                let others = existing.filter { $0.kind == .styleSignal && $0.key == updated.key && $0.identity != identity }
                let cells = styleCells(key: updated.key, items: others + [updated], kept: styleKept?(updated.key) ?? [],
                                       now: capture.capturedAt, halfLife: policy.styleHalfLife)
                updated = evaluateStyle(updated, cells: cells, wasReady: base?.isReadySuggestion == true, policy: policy)
            }
            if changed[identity] == nil { order.append(identity) }
            changed[identity] = updated
        }
        return order.compactMap { changed[$0] }
    }

    /// A known term is skipped only for a bare term (no hearing) or a hearing the user's entry
    /// already lists.
    private static func isCovered(_ heard: String?, by listed: Set<String>?) -> Bool {
        guard let heard else { return true }
        return listed?.contains(listedKey(heard)) == true
    }

    /// How a "sounds like" phrase is compared: trimmed and lowercased.
    public static func listedKey(_ phrase: String) -> String {
        phrase.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    /// The observations in a capture, one per distinct item.
    static func observations(from capture: CorrectionCapture) -> [Observation] {
        var seen: Set<String> = []
        var result: [Observation] = []
        for event in capture.events {
            guard let observation = observation(for: event, appBundleID: capture.appBundleID) else { continue }
            let identity = LearnedItem.identity(kind: observation.kind, key: observation.key, appBundleID: observation.appBundleID)
            if seen.insert(identity).inserted { result.append(observation) }
        }
        return result
    }

    static func observation(for event: CorrectionEvent, appBundleID: String?) -> Observation? {
        switch event.kind {
        case .asrTerm:
            let value = event.after.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !value.isEmpty else { return nil }
            // Casing has no safe global interpretation without an app.
            if event.before.lowercased() == value.lowercased(), appBundleID == nil { return nil }
            return Observation(kind: .term, key: value.lowercased(), value: value, heardAs: event.before, appBundleID: event.before.lowercased() == value.lowercased() ? appBundleID : nil)
        case .formatting:
            guard let appBundleID, let signal = CorrectionClassifier.formattingSignal(before: event.before, after: event.after)
            else { return nil }
            return style("format:\(signal.rawValue)", appBundleID)
        case .cleanupOverEdit:
            guard let appBundleID, !event.after.isEmpty else { return nil }
            return style("keep:\(event.after.lowercased())", appBundleID)
        case .cleanupUnderEdit:
            guard let appBundleID, !event.before.isEmpty else { return nil }
            return style("drop:\(event.before.lowercased())", appBundleID)
        case .rewrite:
            return nil
        }
    }

    private static func style(_ signal: String, _ appBundleID: String) -> Observation {
        Observation(kind: .styleSignal, key: signal, value: signal, heardAs: nil, appBundleID: appBundleID)
    }

    static func merge(
        _ observation: Observation, into base: LearnedItem?, capture: CorrectionCapture, policy: LearningPolicy,
        backfill: ((LearnedItem) -> [EvidenceCell])? = nil
    ) -> LearnedItem {
        let now = capture.capturedAt
        var item = base ?? LearnedItem(
            kind: observation.kind, key: observation.key, value: observation.value,
            appBundleID: observation.appBundleID, createdAt: now, lastSeenAt: now)
        let isNewDictation = !item.sourceDictationIDs.contains(capture.dictationID)
        if isNewDictation {
            item.observations += 1
            item.sourceDictationIDs = Array((item.sourceDictationIDs + [capture.dictationID]).suffix(LearnedItem.maxProvenance))
            item.observedAt = Array((item.observedAt + [now]).suffix(LearnedItem.maxProvenance))
        }
        if let heard = observation.heardAs, !heard.isEmpty, heard.lowercased() != item.key {
            let others = item.heardAs.filter { $0.lowercased() != heard.lowercased() }
            item.heardAs = Array((others + [heard]).suffix(policy.maxHeardAs))
        }
        // Prefer the user's capitalized spelling ("Priya" over "priya") once seen.
        if observation.value.contains(where: \.isUppercase) || !item.value.contains(where: \.isUppercase) {
            item.value = observation.value
        }
        if policy.useEvidence, item.kind == .term {
            if base == nil {
                // A new word: what History says about the times Hushy wrote it as heard and the person left it.
                item.evidence = backfill?(item) ?? []
            } else if item.evidence.isEmpty {
                // Written before the counts existed: its observation times stand in (`legacyEvidence`).
                item.evidence = legacyEvidence(of: base ?? item, halfLife: policy.termHalfLife)
            }
            if isNewDictation {
                item.evidence = recording(edits: 1, kept: 0, app: capture.appBundleID ?? "", in: item.evidence, at: now, halfLife: policy.termHalfLife)
            }
        }
        item.lastSeenAt = now
        return evaluate(item, now: now, policy: policy, app: capture.appBundleID,
                        oneEditSpelling: observation.heardAs?.lowercased() != observation.key && (capture.supportedKeys.contains(observation.key) || (capture.oneEditSpellingKeys.contains(observation.key)
                            && observation.heardAs.map { oneEditVariant($0, observation.value) } == true)))
    }

    /// A very narrow spelling repair: one inserted/deleted interior letter, with the same
    /// phonetic key. Substitutions and terminal silent letters can be different valid names.
    private static func oneEditVariant(_ heard: String, _ fixed: String) -> Bool {
        let before = heard.lowercased(), after = fixed.lowercased()
        guard before.count >= 4, after.count >= 4,
              before.allSatisfy(\.isLetter), after.allSatisfy(\.isLetter),
              !LearningLexicon.isCommonWord(before), !LearningLexicon.isCommonWord(after),
              abs(before.count - after.count) == 1,
              ContextSpellingFixer.levenshtein(before, after) == 1,
              ContextSpellingFixer.phoneticKey(before) == ContextSpellingFixer.phoneticKey(after)
        else { return false }
        let shorter = Array(before.count < after.count ? before : after)
        let longer = Array(before.count > after.count ? before : after)
        // The added letter must lie inside the word; Sara/Sarah is an alternate name.
        return (1..<(longer.count - 1)).contains { index in
            Array(longer[..<index]) + Array(longer[(index + 1)...]) == shorter
        }
    }

    /// Recomputes confidence and promotes a candidate that met its threshold.
    static func evaluate(_ item: LearnedItem, now: Date, policy: LearningPolicy, app: String? = nil, oneEditSpelling: Bool = false) -> LearnedItem {
        if policy.useEvidence, item.kind == .term { return evaluateEvidence(item, now: now, policy: policy, app: app, oneEditSpelling: oneEditSpelling) }
        var copy = item
        let (threshold, window) = item.kind == .term
            ? (oneEditSpelling ? 1 : policy.termPromoteAfter, policy.termWindow)
            : (policy.stylePromoteAfter, policy.styleWindow)
        let recent = item.observedAt.filter { now.timeIntervalSince($0) <= window }.count
        copy.confidence = item.confirmed ? 1 : min(1, Double(recent) / Double(max(1, threshold)))
        let mayAutoActivate = item.kind == .term && policy.autoActivateTerms
        if copy.status == .candidate, item.confirmed || (mayAutoActivate && recent >= threshold) {
            copy.status = .active
            copy.activatedAt = now
            copy.announced = false
        }
        return copy
    }

    /// How far a candidate is toward being used: the edits that count inside its window, and how
    /// many it takes (the ordinary threshold; the one-letter shortcut needs one).
    public static func progress(of item: LearnedItem, now: Date, policy: LearningPolicy) -> (seen: Int, needed: Int) {
        let (needed, window) = item.kind == .term
            ? (policy.termPromoteAfter, policy.termWindow) : (policy.stylePromoteAfter, policy.styleWindow)
        let seen = item.observedAt.filter { now.timeIntervalSince($0) <= window }.count
        guard item.kind == .styleSignal, item.status == .candidate else { return (seen, needed) }
        return item.isReadySuggestion ? (needed, needed) : (min(seen, needed - 1), needed)
    }

    /// The user accepted a suggestion: active immediately.
    public static func confirm(_ item: LearnedItem, now: Date = Date()) -> LearnedItem {
        var copy = item
        copy.confirmed = true
        if copy.status == .forgotten { copy.status = .candidate }
        let evaluated = evaluate(copy, now: now, policy: .standard)
        var result = evaluated
        // The user just said yes; there's nothing to announce.
        result.announced = true
        return result
    }

    /// Undo / Forget: stops using the item and drops its evidence, keeping only a tombstone
    /// (kind, key, value) so the same edits never re-teach it.
    public static func forget(_ item: LearnedItem) -> LearnedItem {
        var copy = item
        copy.status = .forgotten
        copy.confirmed = false
        copy.confidence = 0
        copy.heardAs = []
        copy.sourceDictationIDs = []
        copy.observedAt = []
        copy.evidence = []
        copy.announced = true
        return copy
    }
}
