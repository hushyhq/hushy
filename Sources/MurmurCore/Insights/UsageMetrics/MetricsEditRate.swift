import Foundation

// The edit rate after paste: of the dictations Hushy pasted, how many did the person then change, and by
// how much, per tone and per kind of app. Everything here is a closed vocabulary and a count. The field's
// text is read on this Mac by the edit watcher, reduced to one of these words, and dropped.

/// The kind of app a dictation was pasted into: the same closed list Insights and tones use, never an
/// app name, a bundle ID, a window title or a web address.
///
/// Its own type (not `AppCategory` itself) so a change to the app's categories cannot silently change
/// what the server is sent: adding a case there will not compile here until a case is chosen.
public enum MetricsAppKind: String, MetricsKey {
    case aiPrompts, email, workMessages, personalMessages, documents, code, other

    public init(_ category: AppCategory) {
        switch category {
        case .aiPrompts: self = .aiPrompts
        case .email: self = .email
        case .workMessages: self = .workMessages
        case .personalMessages: self = .personalMessages
        case .documents: self = .documents
        case .code: self = .code
        case .other: self = .other
        }
    }
}

/// What the edit watcher found in the field after a paste.
public enum MetricsEditVerdict: String, MetricsKey {
    /// The text was still there exactly as pasted.
    case kept
    /// Most of the text was still there, but changed.
    case edited
    /// Hushy could not tell: an unreadable or secure field, no clear signal, or the check never ran.
    case unknown
    /// The field was empty when it was read (a message was sent, or everything was deleted).
    case fieldCleared

    public init(observation: DictationFeedback.EditObservation, coverage: DictationFeedback.EditCoverage) {
        switch observation {
        case .kept: self = .kept
        case .edited: self = .edited
        case .unknown: self = coverage == .fieldCleared ? .fieldCleared : .unknown
        }
    }
}

/// How much of an edited dictation the person changed, in words. `none` is the size of every dictation
/// that was not edited, so a size other than `none` always goes with the verdict `edited`.
///
/// A word counts as changed when it was replaced, removed or added, or when only its capitals or its
/// punctuation changed. An edited dictation is always at least one word.
public enum MetricsEditSize: String, MetricsKey {
    case none
    case words1to2
    case words3to10
    case wordsMore

    /// The bucket for an edited dictation in which `wordsChanged` words changed (never `none`).
    public static func forEdit(wordsChanged: Int) -> MetricsEditSize {
        switch wordsChanged {
        case ...2: .words1to2
        case 3...10: .words3to10
        default: .wordsMore
        }
    }
}

/// One cell of the edit-rate table: how the dictations of one tone, pasted into one kind of app, fared.
public struct MetricsEditRateKey: Hashable, Sendable {
    public let tone: MetricsTone
    public let appKind: MetricsAppKind
    public let verdict: MetricsEditVerdict
    public let size: MetricsEditSize

    /// Throws when the size does not fit the verdict (only an edited dictation has a size).
    public init(tone: MetricsTone, appKind: MetricsAppKind, verdict: MetricsEditVerdict, size: MetricsEditSize) throws {
        guard (size != .none) == (verdict == .edited) else { throw MetricsValidationError.inconsistentEditRate }
        self.tone = tone
        self.appKind = appKind
        self.verdict = verdict
        self.size = size
    }
}

/// Counts per tone, kind of app, verdict and edit size. Sparse on the wire: one row per non-zero cell,
/// sorted, so the same table always gives the same bytes.
///
///     [{"appKind":"email","count":4,"size":"words1to2","tone":"professional","verdict":"edited"}, ...]
public struct MetricsEditRateTable: Codable, Sendable, Equatable {
    /// The most cells there can be: every tone with every kind of app, verdict and size that fits.
    public static var maximumRows: Int {
        MetricsTone.allCases.count * MetricsAppKind.allCases.count * (MetricsEditVerdict.allCases.count - 1 + (MetricsEditSize.allCases.count - 1))
    }

    public private(set) var counts: [MetricsEditRateKey: Int]

    public init() { counts = [:] }

    public subscript(key: MetricsEditRateKey) -> Int { counts[key, default: 0] }

    public var total: Int { counts.values.reduce(0, MetricsMath.add) }

    public func total(verdict: MetricsEditVerdict) -> Int {
        counts.filter { $0.key.verdict == verdict }.values.reduce(0, MetricsMath.add)
    }

    public func total(tone: MetricsTone) -> Int {
        counts.filter { $0.key.tone == tone }.values.reduce(0, MetricsMath.add)
    }

    public func total(tone: MetricsTone, appKind: MetricsAppKind) -> Int {
        counts.filter { $0.key.tone == tone && $0.key.appKind == appKind }.values.reduce(0, MetricsMath.add)
    }

    public mutating func increment(_ key: MetricsEditRateKey) {
        counts[key] = MetricsMath.increment(self[key])
    }

    /// Records one dictation. A size is needed only for an edited one; an edited dictation whose size was
    /// not measured is left out rather than guessed. Returns whether it was counted.
    @discardableResult
    public mutating func record(
        tone: MetricsTone, appKind: MetricsAppKind, observation: DictationFeedback.EditObservation,
        coverage: DictationFeedback.EditCoverage, size: MetricsEditSize?
    ) -> Bool {
        let verdict = MetricsEditVerdict(observation: observation, coverage: coverage)
        let sized = verdict == .edited ? size : MetricsEditSize.none
        guard let sized, let key = try? MetricsEditRateKey(tone: tone, appKind: appKind, verdict: verdict, size: sized) else { return false }
        increment(key)
        return true
    }

    public func merged(with other: MetricsEditRateTable) -> MetricsEditRateTable {
        var result = self
        for (key, value) in other.counts { result.counts[key] = MetricsMath.add(result[key], value) }
        return result
    }

    func validate() throws {
        guard counts.count <= Self.maximumRows, counts.values.allSatisfy({ (1...MetricsLimits.maximumCount).contains($0) }) else {
            throw MetricsValidationError.countOutOfRange
        }
    }

    // MARK: - Wire format

    private struct Row: Codable {
        let tone: MetricsTone
        let appKind: MetricsAppKind
        let verdict: MetricsEditVerdict
        let size: MetricsEditSize
        let count: Int

        init(key: MetricsEditRateKey, count: Int) {
            tone = key.tone
            appKind = key.appKind
            verdict = key.verdict
            size = key.size
            self.count = count
        }

        init(from decoder: Decoder) throws {
            try decoder.requireOnlyKeys(["tone", "appKind", "verdict", "size", "count"])
            let values = try decoder.container(keyedBy: CodingKeys.self)
            tone = try values.decode(MetricsTone.self, forKey: .tone)
            appKind = try values.decode(MetricsAppKind.self, forKey: .appKind)
            verdict = try values.decode(MetricsEditVerdict.self, forKey: .verdict)
            size = try values.decode(MetricsEditSize.self, forKey: .size)
            count = try values.decode(Int.self, forKey: .count)
            guard (1...MetricsLimits.maximumCount).contains(count) else {
                throw DecodingError.dataCorruptedError(forKey: .count, in: values, debugDescription: "Count out of range")
            }
            guard (size != .none) == (verdict == .edited) else {
                throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Size does not fit the verdict"))
            }
        }

        var key: MetricsEditRateKey? { try? MetricsEditRateKey(tone: tone, appKind: appKind, verdict: verdict, size: size) }

        private enum CodingKeys: String, CodingKey { case tone, appKind, verdict, size, count }
    }

    public init(from decoder: Decoder) throws {
        var rows = try decoder.unkeyedContainer()
        var parsed: [MetricsEditRateKey: Int] = [:]
        while !rows.isAtEnd {
            let row = try rows.decode(Row.self)
            guard let key = row.key, parsed[key] == nil, parsed.count < Self.maximumRows else {
                throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Duplicate or surplus edit-rate row"))
            }
            parsed[key] = row.count
        }
        counts = parsed
    }

    public func encode(to encoder: Encoder) throws {
        var rows = encoder.unkeyedContainer()
        let ordered = counts.sorted { Self.order($0.key).lexicographicallyPrecedes(Self.order($1.key)) }
        for (key, count) in ordered { try rows.encode(Row(key: key, count: count)) }
    }

    private static func order(_ key: MetricsEditRateKey) -> [String] {
        [key.tone.rawValue, key.appKind.rawValue, key.verdict.rawValue, key.size.rawValue]
    }
}
