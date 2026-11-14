import Foundation

/// Two small counts about one learned word in one app: how often the person changed what Hushy wrote
/// (`edits`) and how often they left it alone (`kept`). Nothing else is kept: no text, only the word
/// pair the learned item already stores. Both counts fade with time (`decayed`), so old evidence
/// counts for less without ever being cut off at a hard edge.
///
/// `app` is the bundle id the evidence came from, or "" when it is not known (evidence written before
/// the counts existed, or a capture with no app).
public struct EvidenceCell: Codable, Sendable, Equatable, Hashable {
    public var app: String
    public var edits: Double
    public var kept: Double
    public var updatedAt: Date

    public init(app: String, edits: Double = 0, kept: Double = 0, updatedAt: Date) {
        self.app = app
        self.edits = edits
        self.kept = kept
        self.updatedAt = updatedAt
    }

    /// The counts as they stand at `now`: each halves every `halfLife` seconds. A `now` before
    /// `updatedAt` leaves them unchanged.
    public func decayed(to now: Date, halfLife: TimeInterval) -> EvidenceCell {
        let age = now.timeIntervalSince(updatedAt)
        guard age > 0, halfLife > 0 else { return self }
        let weight = pow(0.5, age / halfLife)
        return EvidenceCell(app: app, edits: edits * weight, kept: kept * weight, updatedAt: now)
    }

    public func adding(edits more: Double = 0, kept moreKept: Double = 0, at now: Date, halfLife: TimeInterval) -> EvidenceCell {
        var cell = decayed(to: now, halfLife: halfLife)
        cell.edits += more
        cell.kept += moreKept
        cell.updatedAt = max(cell.updatedAt, now)
        return cell
    }
}

/// The arithmetic behind "is there enough evidence for this swap".
public enum EvidenceMath {
    /// How likely it is that the person's true rate of changing the word is above one half, given
    /// `edits` changes and `kept` times left alone, from a flat prior: P(θ > 0.5) under Beta(1 + edits, 1 + kept).
    /// With nothing left alone it is 1 - 0.5^(1 + edits): 0.75 for one change, 0.875 for two.
    public static func probabilityAboveHalf(edits: Double, kept: Double) -> Double {
        let a = 1 + max(0, edits), b = 1 + max(0, kept)
        return 1 - regularizedIncompleteBeta(0.5, a, b)
    }

    /// The share of one change that is left after `age` seconds.
    public static func weight(afterSeconds age: TimeInterval, halfLife: TimeInterval) -> Double {
        guard halfLife > 0, age > 0 else { return 1 }
        return pow(0.5, age / halfLife)
    }

    /// I_x(a, b) by the continued fraction of Numerical Recipes (`betacf`), for 0 < x < 1.
    static func regularizedIncompleteBeta(_ x: Double, _ a: Double, _ b: Double) -> Double {
        guard x > 0 else { return 0 }
        guard x < 1 else { return 1 }
        let front = exp(lgamma(a + b) - lgamma(a) - lgamma(b) + a * log(x) + b * log(1 - x))
        if x < (a + 1) / (a + b + 2) { return front * continuedFraction(x, a, b) / a }
        return 1 - front * continuedFraction(1 - x, b, a) / b
    }

    private static func continuedFraction(_ x: Double, _ a: Double, _ b: Double) -> Double {
        let tiny = 1e-30
        var c = 1.0
        var d = 1 - (a + b) * x / (a + 1)
        if abs(d) < tiny { d = tiny }
        d = 1 / d
        var h = d
        for m in 1...200 {
            let m = Double(m)
            let even = m * (b - m) * x / ((a + 2 * m - 1) * (a + 2 * m))
            d = 1 + even * d
            if abs(d) < tiny { d = tiny }
            c = 1 + even / c
            if abs(c) < tiny { c = tiny }
            d = 1 / d
            h *= d * c
            let odd = -(a + m) * (a + b + m) * x / ((a + 2 * m) * (a + 2 * m + 1))
            d = 1 + odd * d
            if abs(d) < tiny { d = tiny }
            c = 1 + odd / c
            if abs(c) < tiny { c = tiny }
            d = 1 / d
            let step = d * c
            h *= step
            if abs(step - 1) < 1e-12 { break }
        }
        return h
    }
}

/// Where a learned term applies. Evidence picks the widest level the counts support: a word that is
/// fixed the same way everywhere is global (what every learned term was before scopes existed), a
/// word the person leaves alone in some apps stays with the apps or the kind of app that fixed it.
public enum LearnedScope: Codable, Sendable, Equatable, Hashable {
    case global
    case category(AppCategory)
    case app(String)

    /// Wider scopes have a larger rank; evidence never moves an active item to a narrower one.
    var rank: Int {
        switch self {
        case .global: 2
        case .category: 1
        case .app: 0
        }
    }

    public func applies(inApp app: String?) -> Bool {
        switch self {
        case .global: true
        case .app(let id): app == id
        case .category(let category): app.map { AppCategory.classify(bundleID: $0) == category } ?? false
        }
    }

    /// Stored form: "global", "category:email", "app:com.apple.mail".
    public var stored: String {
        switch self {
        case .global: "global"
        case .category(let category): "category:\(category.rawValue)"
        case .app(let id): "app:\(id)"
        }
    }

    public init?(stored: String) {
        if stored == "global" { self = .global; return }
        if stored.hasPrefix("category:"), let category = AppCategory(rawValue: String(stored.dropFirst("category:".count))) {
            self = .category(category)
            return
        }
        if stored.hasPrefix("app:"), stored.count > 4 { self = .app(String(stored.dropFirst("app:".count))); return }
        return nil
    }
}
