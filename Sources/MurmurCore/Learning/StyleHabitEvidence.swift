import Foundation

/// When a writing habit is worth offering in one app: Beta counts of the person's edits there against History rows they
/// left alone, faded by age, with a small prior from the same habit in other apps (app → kind of app → everywhere).
public enum StyleHabitEvidence {
    /// Weight of one observation from another app of the same kind, and of an edit from an app of another kind.
    static let sameKindWeight = 0.5
    static let otherKindWeight = 0.05
    /// The most the other apps together can add, in observations.
    static let priorCap = 1.0
    /// A habit the person turned down in another app counts there as this many times left alone.
    static let dismissedKept = 1.0
    /// History rows read per capture, newest first.
    static let historyLimit = 2_000

    /// Whether Hushy's `text` has what the habit edits away, so leaving it alone is a "no" to the habit.
    public static func shows(_ key: String, in text: String) -> Bool {
        guard key.hasPrefix("format:"), let signal = FormattingSignal(rawValue: String(key.dropFirst("format:".count))) else { return false }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let tokens = CorrectionAlignment.tokens(trimmed)
        switch signal {
        case .lowercased: return trimmed.first(where: \.isLetter)?.isUppercase == true
        case .droppedTerminalPeriod: return trimmed.hasSuffix(".") && !trimmed.hasSuffix("..")
        case .noGreeting: return tokens.first.map { ["hi", "hey", "hello", "dear"].contains(CorrectionAlignment.key($0)) } ?? false
        case .noExclamation: return trimmed.contains("!")
        case .signOffComma: return tokens.contains { CorrectionAlignment.key($0) == "thanks" && $0.hasSuffix("!") }
        }
    }

    /// Decayed "left alone" counts per app for `key`, from History rows the edit check saw kept.
    public static func keptCells(
        for key: String, rows: [(text: String, app: String, at: Date)], now: Date, halfLife: TimeInterval
    ) -> [EvidenceCell] {
        var byApp: [String: EvidenceCell] = [:]
        for row in rows where !row.app.isEmpty && row.at <= now && shows(key, in: row.text) {
            var cell = byApp[row.app] ?? EvidenceCell(app: row.app, updatedAt: now)
            cell.kept += EvidenceMath.weight(afterSeconds: now.timeIntervalSince(row.at), halfLife: halfLife)
            byApp[row.app] = cell
        }
        return byApp.values.sorted { $0.app < $1.app }
    }

    /// P(the person wants the habit in `app`). Apps of another kind lend only their edits: what they leave alone
    /// says nothing about this app.
    public static func probability(app: String, cells: [EvidenceCell]) -> Double {
        let kind = AppCategory.classify(bundleID: app)
        var own = (edits: 0.0, kept: 0.0), prior = (edits: 0.0, kept: 0.0)
        for cell in cells {
            if cell.app == app {
                own.edits += cell.edits
                own.kept += cell.kept
                continue
            }
            if kind != .other && AppCategory.classify(bundleID: cell.app) == kind {
                prior.edits += sameKindWeight * cell.edits
                prior.kept += sameKindWeight * cell.kept
            } else {
                prior.edits += otherKindWeight * cell.edits
            }
        }
        let mass = prior.edits + prior.kept
        if mass > priorCap {
            prior = (prior.edits * priorCap / mass, prior.kept * priorCap / mass)
        }
        return EvidenceMath.probabilityAboveHalf(edits: own.edits + prior.edits, kept: own.kept + prior.kept)
    }
}

extension LearningPolicy {
    /// How fast a habit's counts fade.
    public var styleHalfLife: TimeInterval { styleWindow }

    /// How far back History is read for a habit's left-alone counts: a row that old counts a sixteenth.
    public var styleLookback: TimeInterval { 4 * styleHalfLife }

    /// The sureness of `stylePromoteAfter` edits spread evenly across `styleWindow`, none left alone.
    public var styleOfferProbability: Double {
        let edits = (0..<max(1, stylePromoteAfter)).reduce(0.0) { total, index in
            let age = stylePromoteAfter > 1 ? styleWindow * Double(index) / Double(stylePromoteAfter - 1) : 0
            return total + EvidenceMath.weight(afterSeconds: age, halfLife: styleHalfLife)
        }
        return EvidenceMath.probabilityAboveHalf(edits: edits, kept: 0)
    }
}

extension Learner {
    /// Every app's counts for the habit `key`: decayed edits from each app's item, a dismissal as times left alone.
    static func styleCells(key: String, items: [LearnedItem], kept: [EvidenceCell], now: Date, halfLife: TimeInterval) -> [EvidenceCell] {
        var byApp = Dictionary(kept.map { ($0.app, $0) }, uniquingKeysWith: { first, _ in first })
        for item in items where item.kind == .styleSignal && item.key == key {
            guard let app = item.appBundleID else { continue }
            var cell = byApp[app] ?? EvidenceCell(app: app, updatedAt: now)
            if item.status == .forgotten {
                cell.kept += StyleHabitEvidence.dismissedKept
            } else {
                cell.edits += item.observedAt.reduce(0) { $0 + EvidenceMath.weight(afterSeconds: now.timeIntervalSince($1), halfLife: halfLife) }
            }
            byApp[app] = cell
        }
        return byApp.values.sorted { $0.app < $1.app }
    }

    /// Ready to offer when the evidence reaches `styleOfferProbability`. A new edit is a yes, so it never withdraws an
    /// offer that was already ready.
    static func evaluateStyle(_ item: LearnedItem, cells: [EvidenceCell], wasReady: Bool, policy: LearningPolicy) -> LearnedItem {
        guard item.kind == .styleSignal, let app = item.appBundleID, !item.confirmed, item.status == .candidate else { return item }
        var copy = item
        let probability = StyleHabitEvidence.probability(app: app, cells: cells)
        let required = policy.styleOfferProbability
        copy.confidence = wasReady || probability >= required - 1e-9 ? 1 : min(0.99, max(0, (probability - 0.5) / (required - 0.5)))
        return copy
    }
}
