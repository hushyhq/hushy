import Foundation

// Shared building blocks for the content-free usage metrics: the key protocol, hard limits,
// validation errors, saturating arithmetic, strict-decoding helpers, and the count table.
// Nothing here knows about dictation, meetings or the network.

/// A fixed, finite vocabulary that may appear in an upload. Conformers are enums with string raw
/// values; the raw value is the only text that ever reaches the JSON for that field.
public protocol MetricsKey: RawRepresentable, CaseIterable, Hashable, Sendable, Codable where RawValue == String {}

extension DictationFeedback.Delivery: MetricsKey {}
extension DictationFeedback.CleanupModelProfile: MetricsKey {}
extension DictationFeedback.FallbackReason: MetricsKey {}
extension DictationFeedback.EditObservation: MetricsKey {}
extension DictationFeedback.EditCoverage: MetricsKey {}
extension CleanupLevel: MetricsKey {}

public enum MetricsLimits {
    /// Per-counter ceiling; matches the hosted table's `between 0 and 10000` checks.
    public static let maximumCount = 10_000
    /// Events folded into one batch. A busier day is split into several batches, never truncated.
    public static let maximumEventsPerBatch = 10_000
    /// The planned ingest ceiling (64 KiB per request).
    public static let maximumEncodedBatchBytes = 64 * 1024
    /// A meeting minutes value above a day is a clock error, not a meeting.
    public static let maximumMeetingMinutes = 24 * 60
}

public enum MetricsValidationError: Error, Sendable, Equatable {
    case countOutOfRange
    case inconsistentDictationCounts
    case inconsistentHistogram
    case inconsistentVoiceActions
    case inconsistentMeetings
    case inconsistentTones
    case inconsistentEditRate
    case invalidDay
    case invalidBuild
    case invalidSchemaVersion
    case invalidEnvironment
    case emptyBatch
    case tooManyEvents
}

enum MetricsMath {
    static func add(_ lhs: Int, _ rhs: Int) -> Int { lhs > Int.max - rhs ? Int.max : lhs + rhs }
    static func multiply(_ lhs: Int, _ rhs: Int) -> Int {
        let (product, overflow) = lhs.multipliedReportingOverflow(by: rhs)
        return overflow ? Int.max : product
    }
    static func increment(_ value: Int) -> Int { add(value, 1) }
    static func clamp(_ value: Int, to range: ClosedRange<Int>) -> Int { min(max(value, range.lowerBound), range.upperBound) }
}

/// A coding key for objects whose keys are checked by hand (strict decoding).
struct MetricsCodingKey: CodingKey {
    let stringValue: String
    let intValue: Int? = nil
    init?(stringValue: String) { self.stringValue = stringValue }
    init?(intValue: Int) { nil }
    init(_ name: String) { stringValue = name }
}

extension Decoder {
    /// Throws unless the current object exists and has no key outside `allowed`.
    func requireOnlyKeys(_ allowed: Set<String>) throws {
        let raw = try container(keyedBy: MetricsCodingKey.self)
        guard Set(raw.allKeys.map(\.stringValue)).isSubset(of: allowed) else {
            throw DecodingError.dataCorrupted(.init(codingPath: codingPath, debugDescription: "Unexpected metrics field"))
        }
    }
}

/// Re-throws a validation failure as a decoding failure, the way `DictationFeedback` does.
func metricsDecodingFailure(_ decoder: Decoder, _ error: MetricsValidationError) -> DecodingError {
    DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Invalid metrics record: \(error)"))
}

/// Counts per member of a fixed vocabulary. Encodes every member (zeros included) so the JSON
/// shape is constant; decoding rejects unknown members, negatives and oversized counts.
public struct MetricsCountTable<Key: MetricsKey>: Codable, Sendable, Equatable {
    public private(set) var counts: [Key: Int]

    public init() { counts = [:] }

    public subscript(key: Key) -> Int { counts[key, default: 0] }

    /// Saturating sum of all counts.
    public var total: Int { counts.values.reduce(0, MetricsMath.add) }

    public mutating func increment(_ key: Key) {
        counts[key] = MetricsMath.increment(self[key])
    }

    public func merged(with other: Self) -> Self {
        var result = self
        for (key, value) in other.counts { result.counts[key] = MetricsMath.add(result[key], value) }
        return result
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: MetricsCodingKey.self)
        var parsed: [Key: Int] = [:]
        for codingKey in container.allKeys {
            guard let key = Key(rawValue: codingKey.stringValue) else {
                throw DecodingError.dataCorruptedError(forKey: codingKey, in: container, debugDescription: "Unexpected metrics key")
            }
            let value = try container.decode(Int.self, forKey: codingKey)
            guard (0...MetricsLimits.maximumCount).contains(value) else {
                throw DecodingError.dataCorruptedError(forKey: codingKey, in: container, debugDescription: "Count out of range")
            }
            if value > 0 { parsed[key] = value }
        }
        counts = parsed
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: MetricsCodingKey.self)
        for key in Key.allCases { try container.encode(self[key], forKey: MetricsCodingKey(key.rawValue)) }
    }

    func validate() throws {
        guard counts.values.allSatisfy({ (1...MetricsLimits.maximumCount).contains($0) }) else {
            throw MetricsValidationError.countOutOfRange
        }
    }
}
