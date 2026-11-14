import Foundation

/// How long, and how regularly, this Mac has used Hushy, in two coarse numbers computed on the
/// Mac from the calendar days it was used. There is no identifier of any kind here: the same
/// numbers describe many Macs, and nothing links a batch to the one before it.
///
/// Added in schema version 2. Version 1 batches have none.
public struct MetricsRetention: Codable, Sendable, Equatable {
    /// Days from the first run to the batch's day, in bands too coarse to single out an install.
    public enum FirstRunBand: String, MetricsKey {
        case day0
        case days1to6
        case days7to29
        case days30to89
        case days90plus

        public init(daysSinceFirstRun days: Int) {
            switch days {
            case ...0: self = .day0
            case 1...6: self = .days1to6
            case 7...29: self = .days7to29
            case 30...89: self = .days30to89
            default: self = .days90plus
            }
        }
    }

    /// The window `activeDaysLast7` counts over: the batch's day and the six before it.
    public static let activeDayWindow = 7

    public let daysSinceFirstRun: FirstRunBand
    /// Distinct calendar days with at least one recorded event, in the seven days ending on the
    /// batch's day. Always 1 or more for a real batch (the batch's own day counts).
    public let activeDaysLast7: Int

    public init(daysSinceFirstRun: FirstRunBand, activeDaysLast7: Int) throws {
        guard (0...Self.activeDayWindow).contains(activeDaysLast7) else { throw MetricsValidationError.countOutOfRange }
        self.daysSinceFirstRun = daysSinceFirstRun
        self.activeDaysLast7 = activeDaysLast7
    }

    /// Computes both numbers for a batch on `day`. A missing first-run day, or one after `day`,
    /// counts as `day` itself; days after `day` never count as active.
    public static func compute(on day: MetricsDay, firstRunDay: MetricsDay?, activeDays: Set<MetricsDay>) -> MetricsRetention {
        let first = min(firstRunDay ?? day, day)
        let active = activeDays.union([day]).filter { (0..<activeDayWindow).contains(day.days(since: $0)) }
        return MetricsRetention(
            band: FirstRunBand(daysSinceFirstRun: day.days(since: first)), active: min(active.count, activeDayWindow))
    }

    private init(band: FirstRunBand, active: Int) {
        daysSinceFirstRun = band
        activeDaysLast7 = active
    }

    private enum CodingKeys: String, CodingKey { case daysSinceFirstRun, activeDaysLast7 }

    public init(from decoder: Decoder) throws {
        try decoder.requireOnlyKeys(["daysSinceFirstRun", "activeDaysLast7"])
        let values = try decoder.container(keyedBy: CodingKeys.self)
        do {
            try self.init(
                daysSinceFirstRun: values.decode(FirstRunBand.self, forKey: .daysSinceFirstRun),
                activeDaysLast7: values.decode(Int.self, forKey: .activeDaysLast7))
        } catch let error as MetricsValidationError { throw metricsDecodingFailure(decoder, error) }
    }
}

/// What the builder needs to compute retention for each batch it closes.
public struct MetricsRetentionInput: Sendable, Equatable {
    public let firstRunDay: MetricsDay?
    /// Days with at least one recorded event, kept locally (pruned to what the window needs).
    public let activeDays: Set<MetricsDay>

    public init(firstRunDay: MetricsDay? = nil, activeDays: Set<MetricsDay> = []) {
        self.firstRunDay = firstRunDay
        self.activeDays = activeDays
    }
}
