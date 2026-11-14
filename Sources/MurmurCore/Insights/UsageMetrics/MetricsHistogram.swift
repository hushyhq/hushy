import Foundation

/// The five distributions a batch carries, each with fixed bucket edges. Buckets are
/// `[0, e0)`, `[e0, e1)`, ... and a final open bucket `[e_last, maximumValue]`.
/// Edges are constants of the schema: changing one requires a new schema version, because rows
/// with different edges cannot be added together.
public enum MetricsHistogramSpec: String, CaseIterable, Sendable {
    case words
    case audioMilliseconds
    case speechMilliseconds
    case cleanupMilliseconds
    case releaseToDeliveryMilliseconds

    /// Doubling steps from 100 ms (imperceptible) to 12 s (stalled). The streaming recognizer
    /// finishes most of its work before the key is released, so the interesting mass is low.
    public static let speechEdges = [100, 200, 400, 800, 1_500, 3_000, 6_000, 12_000]
    /// 0 ms (rules only) lands under 50 ms; local-model passes are typically a few hundred ms to
    /// a couple of seconds; the top edges bracket the cleanup deadline so timeouts stand out.
    public static let cleanupEdges = [50, 100, 250, 500, 1_000, 2_000, 4_000, 8_000]
    /// Finest around one second, where "instant" turns into "noticeable"; coarse tail to 20 s.
    public static let releaseToDeliveryEdges = [250, 500, 750, 1_000, 1_500, 2_500, 4_000, 8_000, 20_000]
    /// 0 | 1-2 | 3-5 | 6-10 | 11-20 | 21-40 | 41-80 | 81-160 | 161-320 | 321+ words:
    /// an interjection, a phrase, a sentence, a message, a paragraph, a long dictation.
    public static let wordEdges = [1, 3, 6, 11, 21, 41, 81, 161, 321]
    /// 1, 2, 4, 8, 15, 30 s, 1, 2, 5 min: from a tap to a monologue.
    public static let audioEdges = [1_000, 2_000, 4_000, 8_000, 15_000, 30_000, 60_000, 120_000, 300_000]

    /// Exclusive upper bound of every bucket except the last.
    public var upperEdges: [Int] {
        switch self {
        case .words: Self.wordEdges
        case .audioMilliseconds: Self.audioEdges
        case .speechMilliseconds: Self.speechEdges
        case .cleanupMilliseconds: Self.cleanupEdges
        case .releaseToDeliveryMilliseconds: Self.releaseToDeliveryEdges
        }
    }

    public var bucketCount: Int { upperEdges.count + 1 }

    /// Inputs are clamped to `0...maximumValue`, so a clock glitch cannot poison a sum.
    public var maximumValue: Int {
        switch self {
        case .words: 50_000
        case .audioMilliseconds: 3_600_000
        case .speechMilliseconds, .cleanupMilliseconds, .releaseToDeliveryMilliseconds:
            DictationFeedback.maximumReleaseToDeliveryMilliseconds
        }
    }

    public func bucketIndex(for value: Int) -> Int {
        upperEdges.firstIndex { value < $0 } ?? upperEdges.count
    }

    /// Smallest and largest value that can land in `bucket` (both inclusive).
    func bounds(ofBucket bucket: Int) -> (lower: Int, upper: Int) {
        let edges = upperEdges
        let lower = bucket == 0 ? 0 : edges[bucket - 1]
        let upper = bucket < edges.count ? edges[bucket] - 1 : maximumValue
        return (lower, upper)
    }
}

/// Bucket counts plus the exact sum of the values, so averages stay computable. Individual
/// values are never kept.
public struct MetricsHistogram: Sendable, Equatable {
    public let spec: MetricsHistogramSpec
    public private(set) var counts: [Int]
    public private(set) var sum: Int

    public init(spec: MetricsHistogramSpec) {
        self.spec = spec
        counts = Array(repeating: 0, count: spec.bucketCount)
        sum = 0
    }

    public init(spec: MetricsHistogramSpec, counts: [Int], sum: Int) throws {
        self.spec = spec
        self.counts = counts
        self.sum = sum
        try validate()
    }

    public var sampleCount: Int { counts.reduce(0, MetricsMath.add) }

    public mutating func record(_ value: Int) {
        let clamped = MetricsMath.clamp(value, to: 0...spec.maximumValue)
        let index = spec.bucketIndex(for: clamped)
        counts[index] = MetricsMath.increment(counts[index])
        sum = MetricsMath.add(sum, clamped)
    }

    public func merged(with other: MetricsHistogram) -> MetricsHistogram {
        var result = self
        for index in counts.indices where index < other.counts.count {
            result.counts[index] = MetricsMath.add(counts[index], other.counts[index])
        }
        result.sum = MetricsMath.add(sum, other.sum)
        return result
    }

    /// Whether the sum could have come from values in these buckets.
    public var isCoherent: Bool {
        guard counts.count == spec.bucketCount, counts.allSatisfy({ $0 >= 0 }) else { return false }
        var low = 0, high = 0
        for (index, count) in counts.enumerated() {
            let bounds = spec.bounds(ofBucket: index)
            low = MetricsMath.add(low, MetricsMath.multiply(count, bounds.lower))
            high = MetricsMath.add(high, MetricsMath.multiply(count, bounds.upper))
        }
        return sum >= low && sum <= high
    }

    func validate() throws {
        guard counts.count == spec.bucketCount else { throw MetricsValidationError.inconsistentHistogram }
        guard counts.allSatisfy({ (0...MetricsLimits.maximumCount).contains($0) }), sum >= 0 else {
            throw MetricsValidationError.countOutOfRange
        }
        guard sampleCount <= MetricsLimits.maximumCount, isCoherent else { throw MetricsValidationError.inconsistentHistogram }
    }
}

extension MetricsHistogram: Encodable {
    private enum CodingKeys: String, CodingKey { case counts, sum }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(counts, forKey: .counts)
        try container.encode(sum, forKey: .sum)
    }

    /// Decodes strictly: only `counts` and `sum`, with the length and sum checked against `spec`.
    static func decode<K: CodingKey>(_ spec: MetricsHistogramSpec, from parent: KeyedDecodingContainer<K>, forKey key: K) throws -> MetricsHistogram {
        let nested = try parent.nestedContainer(keyedBy: MetricsCodingKey.self, forKey: key)
        guard Set(nested.allKeys.map(\.stringValue)).isSubset(of: ["counts", "sum"]) else {
            throw DecodingError.dataCorruptedError(forKey: key, in: parent, debugDescription: "Unexpected histogram field")
        }
        let counts = try nested.decode([Int].self, forKey: MetricsCodingKey("counts"))
        let sum = try nested.decode(Int.self, forKey: MetricsCodingKey("sum"))
        do { return try MetricsHistogram(spec: spec, counts: counts, sum: sum) } catch let error as MetricsValidationError {
            throw DecodingError.dataCorruptedError(forKey: key, in: parent, debugDescription: "Invalid histogram: \(error)")
        }
    }
}
