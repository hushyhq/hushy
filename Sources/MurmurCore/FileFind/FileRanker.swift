import Foundation

/// A candidate with the numbers that ranked it.
public struct RankedFile: Sendable, Equatable {
    public let candidate: FileCandidate
    public let score: Double
    /// Share of the query's name terms that appear in the name (1 when there are no terms).
    public let coverage: Double
    /// Whether the file's date matches a month or year hint; nil when the query names none.
    public let matchesTime: Bool?
}

/// Ranks in code, never by a model: exact name-term match first, then kind, recency (modified or
/// last used), then a shallower path. The margin that makes a winner is one named constant.
public enum FileRanker {
    /// A winner must lead the runner-up by at least this much of a score that tops out near 1.5.
    public static let clearMargin = 0.20
    /// A winner must contain at least this share of the name terms (two terms need both).
    public static let minimumCoverage = 0.75
    /// The list never shows more than this many files.
    public static let listLimit = 5

    static let recencyHalfLifeDays = 120.0
    static let recencyWeight = 0.30
    static let recentHintWeight = 0.45
    static let timeMatchBonus = 0.5
    static let exactNameBonus = 0.15
    static let depthPenaltyPerLevel = 0.02
    static let depthPenaltyCap = 0.2

    public static func rank(
        _ candidates: [FileCandidate], for query: FileQuery, now: Date, home: String, calendar: Calendar = .current
    ) -> [RankedFile] {
        let groups = query.terms.map(FileVocabulary.variants(of:))
        return candidates.map { candidate in
            score(candidate, groups: groups, query: query, now: now, home: home, calendar: calendar)
        }.sorted { lhs, rhs in
            if lhs.score != rhs.score { return lhs.score > rhs.score }
            if lhs.candidate.recency != rhs.candidate.recency {
                return (lhs.candidate.recency ?? .distantPast) > (rhs.candidate.recency ?? .distantPast)
            }
            return lhs.candidate.path < rhs.candidate.path
        }
    }

    static func score(
        _ candidate: FileCandidate, groups: [[String]], query: FileQuery, now: Date, home: String, calendar: Calendar
    ) -> RankedFile {
        let (nameScore, coverage, isTight) = nameMatch(candidate.displayName, groups: groups)
        var total = nameScore
        if isTight { total += exactNameBonus }
        if let date = candidate.recency {
            let days = max(0, now.timeIntervalSince(date)) / 86_400
            let weight = query.time == .recent ? recentHintWeight : recencyWeight
            total += weight * pow(0.5, days / recencyHalfLifeDays)
        }
        var matchesTime: Bool?
        if let hint = query.time, hint != .recent {
            let matches = candidate.modified.map { timeMatches(hint, date: $0, calendar: calendar) } ?? false
            matchesTime = matches
            if matches { total += timeMatchBonus }
        }
        total -= min(depthPenaltyCap, depthPenaltyPerLevel * Double(max(0, depth(of: candidate.path, home: home) - 1)))
        return RankedFile(candidate: candidate, score: total, coverage: coverage, matchesTime: matchesTime)
    }

    /// How well the name carries the terms: 1 for a whole word, 0.5 for part of one, per term.
    static func nameMatch(_ name: String, groups: [[String]]) -> (score: Double, coverage: Double, isTight: Bool) {
        guard !groups.isEmpty else { return (0.5, 1, false) }
        let stem = (name as NSString).deletingPathExtension.lowercased()
        let words = stem.split(whereSeparator: { !($0.isLetter || $0.isNumber) }).map(String.init)
        var total = 0.0
        var matched = 0
        var allWhole = true
        for group in groups {
            var best = 0.0
            for variant in group {
                let key = variant.lowercased()
                let spelled = key.split(separator: " ").map(String.init)
                if spelled.count > 1 {
                    if stem.contains(key) { best = max(best, 1) }
                } else if words.contains(key) {
                    best = max(best, 1)
                } else if key.count >= 3, words.contains(where: { $0.hasPrefix(key) }) || stem.contains(key) {
                    best = max(best, 0.5)
                }
            }
            if best > 0 { matched += 1 }
            if best < 1 { allWhole = false }
            total += best
        }
        let count = Double(groups.count)
        return (total / count, Double(matched) / count, allWhole && words.count <= groups.count + 1)
    }

    /// Folders below home on the path (0 for a file directly in home).
    static func depth(of path: String, home: String) -> Int {
        let prefix = home.hasSuffix("/") ? home : home + "/"
        guard path.hasPrefix(prefix) else { return 0 }
        return path.dropFirst(prefix.count).split(separator: "/").count
    }

    static func timeMatches(_ hint: FileTimeHint, date: Date, calendar: Calendar) -> Bool {
        let parts = calendar.dateComponents([.year, .month], from: date)
        switch hint {
        case .recent: return true
        case .month(let month): return parts.month == month
        case .year(let year): return parts.year == year
        case .monthOfYear(let month, let year): return parts.month == month && parts.year == year
        }
    }

    // MARK: - Deciding

    public enum Decision: Sendable, Equatable {
        case none
        case one(RankedFile)
        case several([RankedFile])
    }

    /// One clear winner, or a short list, or nothing; never a guess. A winner needs enough of the
    /// name terms, a date that fits any month or year asked for, and a margin over the next file.
    public static func decide(_ ranked: [RankedFile]) -> Decision {
        guard let top = ranked.first else { return .none }
        if top.matchesTime == false { return .several(Array(ranked.prefix(listLimit))) }
        if top.coverage < minimumCoverage { return .several(Array(ranked.prefix(listLimit))) }
        guard ranked.count > 1 else { return .one(top) }
        return top.score - ranked[1].score >= clearMargin ? .one(top) : .several(Array(ranked.prefix(listLimit)))
    }
}
