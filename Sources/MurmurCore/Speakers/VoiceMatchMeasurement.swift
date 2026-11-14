import Foundation

/// A stretch of audio tagged with who is speaking in it (a true speaker id, or a diarizer cluster label).
public struct LabeledRange: Sendable, Equatable, Codable {
    public let label: String
    public let start: Double
    public let end: Double
    public var duration: Double { max(0, end - start) }

    public init(label: String, start: Double, end: Double) {
        self.label = label
        self.start = start
        self.end = end
    }
}

/// Pure helpers behind `murmur-eval voice-match`: how a recording is cut into meeting-length excerpts, how a
/// diarizer cluster is tied to the real speaker it mostly holds, and the summary numbers (quantiles, gate
/// error rates, speaker-count outcome). No audio, no model, so all of it is tested with invented numbers.
public enum VoiceMatchMeasurement {
    /// Back-to-back windows of `length` seconds from the start; a last window is kept when it is at least `minimumTail` long.
    public static func windows(duration: Double, length: Double, minimumTail: Double) -> [SpeechRange] {
        guard duration > 0, length > 0 else { return [] }
        var result: [SpeechRange] = []
        var start = 0.0
        while start + length <= duration + 1e-9 {
            result.append(SpeechRange(start: start, end: start + length))
            start += length
        }
        if duration - start >= minimumTail { result.append(SpeechRange(start: start, end: duration)) }
        return result
    }

    /// `ranges` cut to `window` and shifted so the window starts at 0; ranges outside it are dropped.
    public static func clipped(_ ranges: [LabeledRange], to window: SpeechRange) -> [LabeledRange] {
        ranges.compactMap { range in
            let start = max(range.start, window.start)
            let end = min(range.end, window.end)
            return end > start
                ? LabeledRange(label: range.label, start: start - window.start, end: end - window.start) : nil
        }
    }

    /// Seconds of speech per label, counting stretches where one label overlaps itself once.
    public static func speechSeconds(_ ranges: [LabeledRange]) -> [String: Double] {
        Dictionary(grouping: ranges, by: \.label).mapValues { union($0).reduce(0) { $0 + $1.duration } }
    }

    /// Where a diarizer cluster's speech mostly comes from.
    public struct ClusterOrigin: Sendable, Equatable, Codable {
        public let cluster: String
        public let seconds: Double
        /// The true speaker with the most speech under this cluster, or `nil` when none overlaps it at all.
        public let trueSpeaker: String?
        /// Share of the cluster's seconds that overlap `trueSpeaker`, 0...1.
        public let purity: Double
    }

    /// Ties each cluster to the true speaker it overlaps most.
    public static func origins(clusters: [LabeledRange], reference: [LabeledRange]) -> [ClusterOrigin] {
        let referenceBySpeaker = Dictionary(grouping: reference, by: \.label).mapValues(union)
        return Dictionary(grouping: clusters, by: \.label).map { cluster, turns in
            let own = union(turns)
            let seconds = own.reduce(0) { $0 + $1.duration }
            let overlaps = referenceBySpeaker.mapValues { overlap(own, $0) }
            let best = overlaps.max { $0.value != $1.value ? $0.value < $1.value : $0.key > $1.key }
            let hasOverlap = (best?.value ?? 0) > 0
            return ClusterOrigin(
                cluster: cluster, seconds: seconds, trueSpeaker: hasOverlap ? best?.key : nil,
                purity: seconds > 0 && hasOverlap ? (best?.value ?? 0) / seconds : 0)
        }.sorted { $0.cluster < $1.cluster }
    }

    // MARK: Summary numbers

    public struct Quantiles: Sendable, Equatable {
        public let count: Int
        public let min, p10, median, p90, max: Double
    }

    /// Minimum, 10th percentile, median, 90th percentile and maximum (linear interpolation), or `nil` for no values.
    public static func quantiles(_ values: [Double]) -> Quantiles? {
        guard !values.isEmpty else { return nil }
        let sorted = values.sorted()
        func at(_ p: Double) -> Double {
            let position = p * Double(sorted.count - 1)
            let low = Int(position.rounded(.down)), high = Int(position.rounded(.up))
            return sorted[low] + (sorted[high] - sorted[low]) * (position - Double(low))
        }
        return Quantiles(count: sorted.count, min: sorted[0], p10: at(0.1), median: at(0.5), p90: at(0.9), max: sorted[sorted.count - 1])
    }

    /// Share of same-speaker scores that fall below `gate` (a missed match), or `nil` for none.
    public static func missedRate(sameScores: [Double], gate: Double) -> Double? {
        sameScores.isEmpty ? nil : Double(sameScores.filter { $0 < gate }.count) / Double(sameScores.count)
    }

    /// Share of different-speaker scores at or above `gate` (the wrong person suggested), or `nil` for none.
    public static func falseMatchRate(differentScores: [Double], gate: Double) -> Double? {
        differentScores.isEmpty ? nil : Double(differentScores.filter { $0 >= gate }.count) / Double(differentScores.count)
    }

    public enum CountOutcome: Sendable, Equatable {
        case exact
        case over(by: Int)
        case under(by: Int)

        public init(detected: Int, truth: Int) {
            self = detected == truth ? .exact : detected > truth ? .over(by: detected - truth) : .under(by: truth - detected)
        }
    }

    // MARK: Interval arithmetic

    private static func union(_ ranges: [LabeledRange]) -> [LabeledRange] {
        var result: [LabeledRange] = []
        for range in ranges.sorted(by: { $0.start < $1.start }) where range.end > range.start {
            if let last = result.last, range.start <= last.end {
                result[result.count - 1] = LabeledRange(label: last.label, start: last.start, end: max(last.end, range.end))
            } else {
                result.append(range)
            }
        }
        return result
    }

    private static func overlap(_ a: [LabeledRange], _ b: [LabeledRange]) -> Double {
        var total = 0.0
        for x in a {
            for y in b where y.end > x.start && y.start < x.end { total += min(x.end, y.end) - max(x.start, y.start) }
        }
        return total
    }
}
