import Foundation

/// The evidence rule: a term is learned when the counts of times the person changed it and left it
/// alone (`EvidenceCell`, per app, decayed) make it likely they want the swap, and it applies at the
/// widest level the counts support (`LearnedScope`: everywhere, the kind of app, or the app).
extension Learner {
    /// Cells at `now`, each decayed. An item written before the counts existed has none, so its
    /// `observedAt` times stand in: one cell with an edit for each, faded by its age.
    static func decayedCells(of item: LearnedItem, now: Date, policy: LearningPolicy) -> [EvidenceCell] {
        let cells = item.evidence.isEmpty ? legacyEvidence(of: item, halfLife: policy.termHalfLife) : item.evidence
        return cells.map { $0.decayed(to: now, halfLife: policy.termHalfLife) }
    }

    /// The counts an item without any would have had: its observation times as edits, in one cell
    /// stamped with the newest of them (an observation can only be older than that).
    static func legacyEvidence(of item: LearnedItem, halfLife: TimeInterval) -> [EvidenceCell] {
        guard let newest = item.observedAt.max() else { return [] }
        let edits = item.observedAt.reduce(0.0) { $0 + EvidenceMath.weight(afterSeconds: newest.timeIntervalSince($1), halfLife: halfLife) }
        return [EvidenceCell(app: item.appBundleID ?? "", edits: edits, kept: 0, updatedAt: newest)]
    }

    /// `cells` with `edits` and `kept` added to the one for `app` (made if there is none). At most
    /// `maxCells` cells are kept: the ones with the least evidence go first.
    static func recording(
        edits: Double, kept: Double, app: String, in cells: [EvidenceCell], at now: Date, halfLife: TimeInterval
    ) -> [EvidenceCell] {
        var result = cells
        if let index = result.firstIndex(where: { $0.app == app }) {
            result[index] = result[index].adding(edits: edits, kept: kept, at: now, halfLife: halfLife)
        } else {
            result.append(EvidenceCell(app: app, edits: edits, kept: kept, updatedAt: now))
        }
        guard result.count > maxCells else { return result }
        return result
            .sorted { ($0.edits + $0.kept) > ($1.edits + $1.kept) }
            .prefix(maxCells).map { $0 }
    }

    /// The most apps one item keeps counts for.
    static let maxCells = 12

    /// The widest scope the evidence supports for a change just made in `app`, or nil when it supports none.
    /// Everywhere when all the counts together support the swap and no app says no; else the kind of app `app` is, when
    /// the counts of that kind support it and no app of that kind says no; else `app` alone. An app says no when its own
    /// counts make it unlikely the person wants the swap there (`contradicts`): a name fixed in Mail and left alone in
    /// Slack is not made global by the fixes alone. Counts from apps with no known id (`""`) belong to "everywhere" and
    /// say nothing against it.
    static func supportedScope(_ cells: [EvidenceCell], app: String?, needed: Int, policy: LearningPolicy) -> LearnedScope? {
        let required = policy.promoteProbability(needed: needed)
        func total(_ pool: [EvidenceCell]) -> (edits: Double, kept: Double) {
            (pool.reduce(0) { $0 + $1.edits }, pool.reduce(0) { $0 + $1.kept })
        }
        func supports(_ pool: [EvidenceCell]) -> Bool {
            let (edits, kept) = total(pool)
            return edits > 0 && EvidenceMath.probabilityAboveHalf(edits: edits, kept: kept) >= required - 1e-9
        }
        func contradicts(_ pool: [EvidenceCell]) -> Bool {
            let (edits, kept) = total(pool)
            return edits + kept > 0 && EvidenceMath.probabilityAboveHalf(edits: edits, kept: kept) < contradictionLimit
        }
        let known = cells.filter { !$0.app.isEmpty }
        if supports(cells), !known.contains(where: { contradicts([$0]) }) { return .global }
        guard let app, !app.isEmpty else { return nil }
        let category = AppCategory.classify(bundleID: app)
        if category != .other {
            let ofKind = known.filter { AppCategory.classify(bundleID: $0.app) == category }
            if supports(ofKind), !ofKind.contains(where: { contradicts([$0]) }) { return .category(category) }
        }
        return supports(known.filter { $0.app == app }) ? .app(app) : nil
    }

    /// A pool whose counts leave less than this chance that the person wants the swap says no to it: two times left alone
    /// and none changed (P = 0.125) does, one left alone (0.25) does not.
    static let contradictionLimit = 0.2

    static func evaluateEvidence(_ item: LearnedItem, now: Date, policy: LearningPolicy, app: String?, oneEditSpelling: Bool) -> LearnedItem {
        var copy = item
        let needed = oneEditSpelling ? 1 : policy.termPromoteAfter
        let cells = decayedCells(of: item, now: now, policy: policy)
        let chosen = supportedScope(cells, app: app, needed: needed, policy: policy)
        // How far along it is, as the count of fixes over the fixes needed (the figure the progress line shows); 1 only when promoted.
        let fixes = cells.reduce(0) { $0 + $1.edits }
        copy.confidence = item.confirmed || chosen != nil ? 1 : min(0.99, fixes / Double(max(1, needed)))
        let mayAutoActivate = policy.autoActivateTerms
        if copy.status == .candidate, item.confirmed || (mayAutoActivate && chosen != nil) {
            copy.status = .active
            copy.activatedAt = now
            copy.announced = false
            if item.appBundleID == nil { copy.scope = item.confirmed ? .global : chosen ?? .global }
        } else if copy.status == .active, item.appBundleID == nil {
            // Evidence only ever widens an active term: what was learned never silently shrinks or lapses.
            let wanted: LearnedScope? = item.confirmed ? .global : chosen
            if let wanted, wanted.rank > item.scope.rank { copy.scope = wanted }
        }
        return copy
    }

    /// One dictation in `app` where Hushy wrote the heard word, the person left it and the term was not
    /// applied there. Adds a "left alone" to that app's count and judges the term again.
    public static func expose(_ item: LearnedItem, app: String, now: Date, policy: LearningPolicy = .standard) -> LearnedItem {
        guard policy.useEvidence, item.kind == .term, item.status != .forgotten else { return item }
        var copy = item
        let base = item.evidence.isEmpty ? legacyEvidence(of: item, halfLife: policy.termHalfLife) : item.evidence
        copy.evidence = recording(edits: 0, kept: 1, app: app, in: base, at: now, halfLife: policy.termHalfLife)
        return evaluate(copy, now: now, policy: policy, app: app)
    }
}
