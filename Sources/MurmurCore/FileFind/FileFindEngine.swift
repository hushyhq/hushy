import Foundation

/// The only thing a log line or a metric may carry about a file search. A payload-free enum:
/// there is nowhere to put a file name, a path or a query term. `FileFindOutcomeCodeTests`
/// fails if a case ever grows a payload or a raw value outside this list.
public enum FileFindOutcomeCode: String, Sendable, CaseIterable {
    case foundOne = "found-one"
    case foundSeveral = "found-several"
    case none
    case unavailable
    case cancelled

    /// The one line the app logs for a search.
    public var logLine: String { "file search: \(rawValue)" }
}

/// How a search ended. The found cases carry real files (they are what the card shows); the
/// rest carry nothing a log could leak.
public enum FileFindOutcome: Sendable, Equatable {
    /// Which pass found them. A content match is never revealed on its own.
    public enum MatchedBy: Sendable, Equatable { case name, content }

    case foundOne(FileCandidate, matchedBy: MatchedBy)
    case foundSeveral([FileCandidate], matchedBy: MatchedBy)
    case none
    case unavailable(FileSearchUnavailable)
    case cancelled

    public var code: FileFindOutcomeCode {
        switch self {
        case .foundOne: .foundOne
        case .foundSeveral: .foundSeveral
        case .none: .none
        case .unavailable: .unavailable
        case .cancelled: .cancelled
        }
    }
}

/// Runs the typed query: scope, passes, filtering, ranking, deciding. The model never gets
/// here; the finder is the Mac's index behind `FileFinding`.
public struct FileFindEngine: Sendable {
    public static let defaultPassTimeBox: Duration = .milliseconds(1500)
    public static let defaultTotalTimeBox: Duration = .milliseconds(2500)
    public static let defaultResultLimit = 200

    private let finder: any FileFinding
    private let home: URL
    private let now: @Sendable () -> Date
    private let calendar: Calendar
    private let passTimeBox: Duration
    private let totalTimeBox: Duration
    private let resultLimit: Int

    public init(
        finder: any FileFinding, home: URL, now: @escaping @Sendable () -> Date = { Date() },
        calendar: Calendar = .current,
        passTimeBox: Duration = FileFindEngine.defaultPassTimeBox,
        totalTimeBox: Duration = FileFindEngine.defaultTotalTimeBox,
        resultLimit: Int = FileFindEngine.defaultResultLimit
    ) {
        self.finder = finder
        self.home = home
        self.now = now
        self.calendar = calendar
        self.passTimeBox = passTimeBox
        self.totalTimeBox = totalTimeBox
        self.resultLimit = resultLimit
    }

    public func find(_ request: FileRequest) async -> FileFindOutcome {
        let query = request.query
        let roots = FileScope.roots(for: query.location, home: home)
        let groups = query.terms.map(FileVocabulary.variants(of:))
        let deadline = ContinuousClock.now.advanced(by: totalTimeBox)
        var found: (list: [FileCandidate], by: FileFindOutcome.MatchedBy)?
        for pass in Self.passes(termCount: groups.count) {
            if Task.isCancelled { return .cancelled }
            let remaining = min(passTimeBox, ContinuousClock.now.duration(to: deadline))
            guard remaining > .zero else { return .unavailable(.slow) }
            let spec = FileSearchSpec(
                pass: pass, termGroups: groups, kind: query.kind, roots: roots, limit: resultLimit, timeBox: remaining,
                homePath: home.path)
            guard let response = await Self.race(remaining, { await finder.search(spec) }) else {
                return Task.isCancelled ? .cancelled : .unavailable(.slow)
            }
            switch response {
            case .unavailable(let reason):
                return .unavailable(reason)
            case .results(let list):
                let usable = usableResults(list, kind: query.kind)
                if !usable.isEmpty {
                    found = (usable, pass == .content ? .content : .name)
                }
            }
            if found != nil { break }
        }
        if Task.isCancelled { return .cancelled }
        guard let found else {
            return await finder.isIndexAvailable() ? .none : .unavailable(.indexOff)
        }
        return decide(found.list, by: found.by, query: query)
    }

    private func decide(_ list: [FileCandidate], by matchedBy: FileFindOutcome.MatchedBy, query: FileQuery) -> FileFindOutcome {
        let ranked = FileRanker.rank(list, for: query, now: now(), home: home.path, calendar: calendar)
        switch FileRanker.decide(ranked) {
        case .none:
            return .none
        case .one(let winner):
            // A file that only mentions the words somewhere inside is shown, never taken.
            if matchedBy == .content { return .foundSeveral([winner.candidate], matchedBy: .content) }
            return .foundOne(winner.candidate, matchedBy: matchedBy)
        case .several(let top):
            return .foundSeveral(top.map(\.candidate), matchedBy: matchedBy)
        }
    }

    // MARK: - Passes and filtering

    static func passes(termCount: Int) -> [FileSearchSpec.Pass] {
        switch termCount {
        case 0: [.nameAll]
        case 1: [.nameAll, .content]
        default: [.nameAll, .nameAny, .content]
        }
    }

    /// What the finder returned, minus anything out of scope, of the wrong kind, or repeated.
    func usableResults(_ list: [FileCandidate], kind: FileKind) -> [FileCandidate] {
        var seen = Set<String>()
        return list.filter { candidate in
            guard !FileScope.isExcluded(path: candidate.path, home: home.path) else { return false }
            guard kindFits(candidate, kind: kind) else { return false }
            return seen.insert(candidate.path).inserted
        }
    }

    private func kindFits(_ candidate: FileCandidate, kind: FileKind) -> Bool {
        switch kind {
        case .folder: candidate.isFolder
        case .any: !candidate.isFolder
        default: !candidate.isFolder && candidate.kinds.contains(kind)
        }
    }

    /// The finder's answer, or nil if `box` passes first (the finder is then cancelled).
    static func race(
        _ box: Duration, _ work: @escaping @Sendable () async -> FileSearchResponse
    ) async -> FileSearchResponse? {
        await withTaskGroup(of: FileSearchResponse?.self) { group in
            group.addTask { await work() }
            group.addTask {
                try? await Task.sleep(for: box)
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }
    }
}
