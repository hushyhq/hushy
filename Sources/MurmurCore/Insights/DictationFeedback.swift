import Foundation

/// A content-free, single-dictation record suitable for opt-in aggregate feedback.
/// It deliberately has no text, audio, app, account, user, or session fields.
public struct DictationFeedback: Codable, Sendable, Equatable {
    public enum Delivery: String, Codable, Sendable, CaseIterable {
        /// Pasted into the focused field.
        case succeeded
        /// Text was made but not delivered (a paste that could not be sent and was not copied,
        /// a transcription or cleanup that produced nothing).
        case failed
        case cancelled
        /// Put on the clipboard instead of pasted (focus moved, the paste could not be sent).
        case copied
        /// Not pasted because a secure (password) field had focus: a refusal, not a failure.
        case heldSecure
        /// No text field was focused: shown in the pill with an offer to copy, or copied.
        case noField
    }

    /// Allowlisted cleanup provenance; this intentionally does not claim a model version.
    public enum CleanupModelProfile: String, Codable, Sendable, CaseIterable {
        case rules
        case appleSystem
        case localFineTuned
        case localUntuned
        case unavailable
    }

    public enum FallbackReason: String, Codable, Sendable, CaseIterable {
        case disabled
        case emptyInput
        case modelUnavailable
        case modelRejected
        case modelTimedOut
        case systemBusy
        case thermalPressure
        case other
    }

    public enum EditObservation: String, Codable, Sendable, CaseIterable {
        case kept
        case edited
        case unknown
    }

    /// Describes why a post-delivery edit could or could not be observed.
    public enum EditCoverage: String, Codable, Sendable, CaseIterable {
        case observed
        case secure
        case unknownSecurity
        case fieldUnreadable
        case fieldCleared
        case insufficientSignal
        case notAttempted
    }

    public enum ValidationError: Error, Sendable, Equatable {
        case inconsistentEditCoverage
        case timingWithoutDelivery
    }

    public static let maximumReleaseToDeliveryMilliseconds = 600_000

    public let delivery: Delivery
    public let cleanupModelProfile: CleanupModelProfile
    public let fallbackReason: FallbackReason?
    public let editObservation: EditObservation
    public let editCoverage: EditCoverage
    /// Release-to-delivery elapsed time in milliseconds, capped at ten minutes.
    /// Nil means timing was unavailable; it must not be interpreted as a zero-duration sample.
    public let releaseToDeliveryMilliseconds: Int?

    public init(
        delivery: Delivery,
        cleanupModelProfile: CleanupModelProfile,
        fallbackReason: FallbackReason?,
        editObservation: EditObservation,
        editCoverage: EditCoverage,
        releaseToDeliveryMilliseconds: Int?
    ) throws {
        let isObserved = editCoverage == .observed
        guard isObserved == (editObservation != .unknown) else {
            throw ValidationError.inconsistentEditCoverage
        }
        guard delivery == .succeeded || !isObserved else {
            throw ValidationError.inconsistentEditCoverage
        }
        guard delivery == .succeeded || releaseToDeliveryMilliseconds == nil else {
            throw ValidationError.timingWithoutDelivery
        }
        self.delivery = delivery
        self.cleanupModelProfile = cleanupModelProfile
        self.fallbackReason = fallbackReason
        self.editObservation = editObservation
        self.editCoverage = editCoverage
        self.releaseToDeliveryMilliseconds = releaseToDeliveryMilliseconds.map {
            min(max($0, 0), Self.maximumReleaseToDeliveryMilliseconds)
        }
    }

    private enum CodingKeys: String, CodingKey {
        case delivery, cleanupModelProfile, fallbackReason, editObservation, editCoverage, releaseToDeliveryMilliseconds
    }

    private struct AnyCodingKey: CodingKey {
        let stringValue: String
        let intValue: Int? = nil
        init?(stringValue: String) { self.stringValue = stringValue }
        init?(intValue: Int) { return nil }
    }

    public init(from decoder: Decoder) throws {
        let rawValues = try decoder.container(keyedBy: AnyCodingKey.self)
        let allowedKeys: Set<String> = [
            "delivery", "cleanupModelProfile", "fallbackReason", "editObservation", "editCoverage",
            "releaseToDeliveryMilliseconds",
        ]
        guard Set(rawValues.allKeys.map(\.stringValue)).isSubset(of: allowedKeys) else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Unexpected feedback field"))
        }
        let values = try decoder.container(keyedBy: CodingKeys.self)
        let duration = try values.decodeIfPresent(Int.self, forKey: .releaseToDeliveryMilliseconds)
        if let duration, duration < 0 {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Negative feedback timing"))
        }
        do {
            try self.init(
                delivery: values.decode(Delivery.self, forKey: .delivery),
                cleanupModelProfile: values.decode(CleanupModelProfile.self, forKey: .cleanupModelProfile),
                fallbackReason: values.decodeIfPresent(FallbackReason.self, forKey: .fallbackReason),
                editObservation: values.decode(EditObservation.self, forKey: .editObservation),
                editCoverage: values.decode(EditCoverage.self, forKey: .editCoverage),
                releaseToDeliveryMilliseconds: duration
            )
        } catch let error as ValidationError {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Invalid feedback record: \(error)"))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(delivery, forKey: .delivery)
        try values.encode(cleanupModelProfile, forKey: .cleanupModelProfile)
        try values.encodeIfPresent(fallbackReason, forKey: .fallbackReason)
        try values.encode(editObservation, forKey: .editObservation)
        try values.encode(editCoverage, forKey: .editCoverage)
        try values.encodeIfPresent(releaseToDeliveryMilliseconds, forKey: .releaseToDeliveryMilliseconds)
    }
}

/// Bounded, content-free counters derived from feedback records.
public struct DictationFeedbackAggregate: Encodable, Sendable, Equatable {
    public private(set) var succeeded = 0
    public private(set) var failed = 0
    public private(set) var cancelled = 0
    public private(set) var kept = 0
    public private(set) var edited = 0
    public private(set) var unknown = 0
    public private(set) var editCoverageObserved = 0
    public private(set) var editCoverageUnavailable = 0
    public private(set) var editCoverageCounts: [DictationFeedback.EditCoverage: Int] = [:]
    public private(set) var releaseToDeliveryMillisecondsTotal = 0
    public private(set) var timingSampleCount = 0
    public private(set) var fallbackCounts: [DictationFeedback.FallbackReason: Int] = [:]
    public private(set) var cleanupModelCounts: [DictationFeedback.CleanupModelProfile: Int] = [:]

    public init() {}

    public var deliveryCount: Int { Self.add(Self.add(succeeded, failed), cancelled) }
    public var editObservationCount: Int { Self.add(kept, edited) }
    public var editFreeRate: Double? {
        guard editObservationCount > 0 else { return nil }
        return Double(kept) / Double(editObservationCount)
    }

    public mutating func record(_ value: DictationFeedback) {
        switch value.delivery {
        case .succeeded: succeeded = Self.increment(succeeded)
        // Copied, held-for-secure-field and no-field dictations were not pasted: this older local
        // aggregate keeps counting them as failed deliveries, as it always has.
        case .failed, .copied, .heldSecure, .noField: failed = Self.increment(failed)
        case .cancelled: cancelled = Self.increment(cancelled)
        }
        switch value.editObservation {
        case .kept: kept = Self.increment(kept)
        case .edited: edited = Self.increment(edited)
        case .unknown: unknown = Self.increment(unknown)
        }
        if value.editCoverage == .observed {
            editCoverageObserved = Self.increment(editCoverageObserved)
        } else {
            editCoverageUnavailable = Self.increment(editCoverageUnavailable)
        }
        editCoverageCounts[value.editCoverage] = Self.increment(editCoverageCounts[value.editCoverage, default: 0])
        if let duration = value.releaseToDeliveryMilliseconds {
            releaseToDeliveryMillisecondsTotal = Self.add(releaseToDeliveryMillisecondsTotal, duration)
            timingSampleCount = Self.increment(timingSampleCount)
        }
        cleanupModelCounts[value.cleanupModelProfile] = Self.increment(cleanupModelCounts[value.cleanupModelProfile, default: 0])
        if let reason = value.fallbackReason {
            fallbackCounts[reason] = Self.increment(fallbackCounts[reason, default: 0])
        }
    }

    private static func increment(_ value: Int) -> Int { value == Int.max ? Int.max : value + 1 }
    private static func add(_ lhs: Int, _ rhs: Int) -> Int {
        lhs > Int.max - rhs ? Int.max : lhs + rhs
    }
}
