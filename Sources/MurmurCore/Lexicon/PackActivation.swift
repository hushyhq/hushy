import Foundation

/// The person's say over one pack. `automatic` follows the evidence; `off` keeps it off whatever the evidence says
/// (and stops new evidence being kept); `on` keeps it on.
public enum PackChoice: String, Codable, Sendable, CaseIterable {
    case automatic, on, off
}

/// Which names of one pack the person met on which day. Indices into `DomainPack.terms`, nothing else: no text,
/// no app, no time of day. Days are local calendar days ("2026-11-07").
public struct PackEvidence: Codable, Sendable, Equatable {
    public var days: [String: Set<Int>]

    public init(days: [String: Set<Int>] = [:]) { self.days = days }

    public var isEmpty: Bool { days.values.allSatisfy(\.isEmpty) }

    public mutating func record(_ hits: Set<Int>, on day: String) {
        guard !hits.isEmpty else { return }
        days[day, default: []].formUnion(hits)
        // A size bound, not a time limit: the newest days are kept.
        if days.count > Self.maxDays {
            for old in days.keys.sorted().prefix(days.count - Self.maxDays) { days[old] = nil }
        }
    }

    public func merging(_ other: PackEvidence) -> PackEvidence {
        var merged = self
        for (day, hits) in other.days { merged.days[day, default: []].formUnion(hits) }
        return merged
    }

    static let maxDays = 400

    public static func dayKey(_ date: Date, calendar: Calendar = .current) -> String {
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
    }
}

/// Whether a pack is in use for this person, and why. Visible as is in the UI.
public struct PackActivation: Sendable, Equatable {
    public let packID: String
    /// Distinct pack names met inside the window.
    public let evidenceHits: Int
    /// Distinct days with at least one hit inside the window.
    public let distinctDays: Int
    public let choice: PackChoice
    public let active: Bool
    /// The pack names met inside the window, for the boost ranking (the person's own players come first).
    public let hitTerms: Set<Int>

    /// Several different names, on more than one day: one article read once does not switch a pack on.
    public static let minDistinctHits = 3
    public static let minDistinctDays = 2
    /// Evidence older than this does not count towards switching on (it is kept, and counts again if the person
    /// comes back to the field). A pack nobody's screen or history mentions for this long goes quiet by itself.
    public static let windowDays = 60

    public static func evaluate(
        packID: String, evidence: PackEvidence, choice: PackChoice, now: Date, calendar: Calendar = .current
    ) -> PackActivation {
        let start = calendar.date(byAdding: .day, value: -(windowDays - 1), to: calendar.startOfDay(for: now)) ?? now
        let first = PackEvidence.dayKey(start, calendar: calendar)
        let last = PackEvidence.dayKey(now, calendar: calendar)
        let recent = evidence.days.filter { $0.key >= first && $0.key <= last && !$0.value.isEmpty }
        let hits = recent.values.reduce(into: Set<Int>()) { $0.formUnion($1) }
        let earned = hits.count >= minDistinctHits && recent.count >= minDistinctDays
        let active: Bool
        switch choice {
        case .automatic: active = earned
        case .on: active = true
        case .off: active = false
        }
        return PackActivation(packID: packID, evidenceHits: hits.count, distinctDays: recent.count,
                              choice: choice, active: active, hitTerms: hits)
    }
}
