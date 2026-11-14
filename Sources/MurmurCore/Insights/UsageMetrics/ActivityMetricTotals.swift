import Foundation

/// Voice-action outcomes for a day. "Attempted" is derived (the sum of the three terminal
/// outcomes), so it can never disagree with them.
public struct VoiceActionTotals: Codable, Sendable, Equatable {
    public private(set) var outcome = MetricsCountTable<VoiceActionOutcome>()
    /// Failure categories; their total always equals the number of failed actions.
    public private(set) var failure = MetricsCountTable<VoiceActionFailureCategory>()

    public init() {}

    public var attempted: Int { outcome.total }

    public mutating func record(_ event: VoiceActionMetricEvent) {
        outcome.increment(event.outcome)
        if let category = event.failure { failure.increment(category) }
    }

    func validate() throws {
        try outcome.validate()
        try failure.validate()
        guard failure.total == outcome[.failed] else { throw MetricsValidationError.inconsistentVoiceActions }
    }

    private enum CodingKeys: String, CodingKey { case outcome, failure }

    public init(from decoder: Decoder) throws {
        try decoder.requireOnlyKeys(["outcome", "failure"])
        let values = try decoder.container(keyedBy: CodingKeys.self)
        outcome = try values.decode(MetricsCountTable.self, forKey: .outcome)
        failure = try values.decode(MetricsCountTable.self, forKey: .failure)
        do { try validate() } catch let error as MetricsValidationError { throw metricsDecodingFailure(decoder, error) }
    }

    public func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(outcome, forKey: .outcome)
        try values.encode(failure, forKey: .failure)
    }
}

/// Meeting counts and total whole minutes recorded (completed and discarded meetings).
public struct MeetingTotals: Codable, Sendable, Equatable {
    public private(set) var outcome = MetricsCountTable<MeetingOutcome>()
    public private(set) var minutesRecorded = 0

    public init() {}

    public mutating func record(_ event: MeetingMetricEvent) {
        outcome.increment(event.outcome)
        if let minutes = event.minutesRecorded { minutesRecorded = MetricsMath.add(minutesRecorded, minutes) }
    }

    func validate() throws {
        try outcome.validate()
        let ended = MetricsMath.add(outcome[.completed], outcome[.discarded])
        let ceiling = MetricsMath.multiply(ended, MetricsLimits.maximumMeetingMinutes)
        guard minutesRecorded >= 0, minutesRecorded <= ceiling else { throw MetricsValidationError.inconsistentMeetings }
    }

    private enum CodingKeys: String, CodingKey { case outcome, minutesRecorded }

    public init(from decoder: Decoder) throws {
        try decoder.requireOnlyKeys(["outcome", "minutesRecorded"])
        let values = try decoder.container(keyedBy: CodingKeys.self)
        outcome = try values.decode(MetricsCountTable.self, forKey: .outcome)
        minutesRecorded = try values.decode(Int.self, forKey: .minutesRecorded)
        do { try validate() } catch let error as MetricsValidationError { throw metricsDecodingFailure(decoder, error) }
    }

    public func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(outcome, forKey: .outcome)
        try values.encode(minutesRecorded, forKey: .minutesRecorded)
    }
}
