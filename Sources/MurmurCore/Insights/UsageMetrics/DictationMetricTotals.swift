import Foundation

/// Everything a day says about dictations that used one cleanup profile: counts per fixed
/// vocabulary and fixed-bucket histograms. No individual dictation can be recovered from it.
///
/// Invariants (mirroring the hosted table's checks, plus the ones that follow from them):
/// kept + edited + unknown = the sum of every delivery outcome; kept + edited <= succeeded;
/// fallbacks <= dictations; delivered-timing samples <= succeeded.
public struct DictationMetricTotals: Codable, Sendable, Equatable {
    public private(set) var delivery = MetricsCountTable<DictationFeedback.Delivery>()
    public private(set) var editObservation = MetricsCountTable<DictationFeedback.EditObservation>()
    public private(set) var editCoverage = MetricsCountTable<DictationFeedback.EditCoverage>()
    public private(set) var fallbackReason = MetricsCountTable<DictationFeedback.FallbackReason>()
    public private(set) var cleanupLevel = MetricsCountTable<CleanupLevel>()
    public private(set) var modeKind = MetricsCountTable<MetricsModeKind>()
    public private(set) var modelState = MetricsCountTable<MetricsModelState>()
    public private(set) var words = MetricsHistogram(spec: .words)
    public private(set) var audioMilliseconds = MetricsHistogram(spec: .audioMilliseconds)
    public private(set) var speechMilliseconds = MetricsHistogram(spec: .speechMilliseconds)
    public private(set) var cleanupMilliseconds = MetricsHistogram(spec: .cleanupMilliseconds)
    public private(set) var releaseToDeliveryMilliseconds = MetricsHistogram(spec: .releaseToDeliveryMilliseconds)

    public init() {}

    /// Dictations in this total (every delivery outcome).
    public var count: Int { delivery.total }

    public mutating func record(_ event: DictationMetricEvent) {
        let feedback = event.feedback
        delivery.increment(feedback.delivery)
        editObservation.increment(feedback.editObservation)
        editCoverage.increment(feedback.editCoverage)
        if let reason = feedback.fallbackReason { fallbackReason.increment(reason) }
        cleanupLevel.increment(event.cleanupLevel)
        modeKind.increment(event.modeKind)
        if let state = event.modelState { modelState.increment(state) }
        words.record(event.wordCount)
        audioMilliseconds.record(event.audioMilliseconds)
        if let value = event.speechMilliseconds { speechMilliseconds.record(value) }
        if let value = event.cleanupMilliseconds { cleanupMilliseconds.record(value) }
        if let value = feedback.releaseToDeliveryMilliseconds { releaseToDeliveryMilliseconds.record(value) }
    }

    public func merged(with other: DictationMetricTotals) -> DictationMetricTotals {
        var result = self
        result.delivery = delivery.merged(with: other.delivery)
        result.editObservation = editObservation.merged(with: other.editObservation)
        result.editCoverage = editCoverage.merged(with: other.editCoverage)
        result.fallbackReason = fallbackReason.merged(with: other.fallbackReason)
        result.cleanupLevel = cleanupLevel.merged(with: other.cleanupLevel)
        result.modeKind = modeKind.merged(with: other.modeKind)
        result.modelState = modelState.merged(with: other.modelState)
        result.words = words.merged(with: other.words)
        result.audioMilliseconds = audioMilliseconds.merged(with: other.audioMilliseconds)
        result.speechMilliseconds = speechMilliseconds.merged(with: other.speechMilliseconds)
        result.cleanupMilliseconds = cleanupMilliseconds.merged(with: other.cleanupMilliseconds)
        result.releaseToDeliveryMilliseconds = releaseToDeliveryMilliseconds.merged(with: other.releaseToDeliveryMilliseconds)
        return result
    }

    /// Checks the totals of one non-empty, uploadable profile row.
    func validate() throws {
        try delivery.validate(); try editObservation.validate(); try editCoverage.validate()
        try fallbackReason.validate(); try cleanupLevel.validate(); try modeKind.validate(); try modelState.validate()
        for histogram in [words, audioMilliseconds, speechMilliseconds, cleanupMilliseconds, releaseToDeliveryMilliseconds] {
            try histogram.validate()
        }
        let total = count
        guard (1...MetricsLimits.maximumCount).contains(total) else { throw MetricsValidationError.countOutOfRange }
        let succeeded = delivery[.succeeded]
        let checked = MetricsMath.add(editObservation[.kept], editObservation[.edited])
        let consistent = editObservation.total == total && editCoverage.total == total
            && cleanupLevel.total == total && modeKind.total == total
            && checked <= succeeded && editCoverage[.observed] == checked
            && fallbackReason.total <= total && modelState.total <= total
            && words.sampleCount == total && audioMilliseconds.sampleCount == total
            && speechMilliseconds.sampleCount <= total && cleanupMilliseconds.sampleCount <= total
            && releaseToDeliveryMilliseconds.sampleCount <= succeeded
        guard consistent else { throw MetricsValidationError.inconsistentDictationCounts }
    }

    private static let fieldNames: Set<String> = [
        "delivery", "editObservation", "editCoverage", "fallbackReason", "cleanupLevel", "modeKind", "modelState",
        "words", "audioMilliseconds", "speechMilliseconds", "cleanupMilliseconds", "releaseToDeliveryMilliseconds",
    ]

    private enum CodingKeys: String, CodingKey {
        case delivery, editObservation, editCoverage, fallbackReason, cleanupLevel, modeKind, modelState
        case words, audioMilliseconds, speechMilliseconds, cleanupMilliseconds, releaseToDeliveryMilliseconds
    }

    public init(from decoder: Decoder) throws {
        try decoder.requireOnlyKeys(Self.fieldNames)
        let values = try decoder.container(keyedBy: CodingKeys.self)
        delivery = try values.decode(MetricsCountTable.self, forKey: .delivery)
        editObservation = try values.decode(MetricsCountTable.self, forKey: .editObservation)
        editCoverage = try values.decode(MetricsCountTable.self, forKey: .editCoverage)
        fallbackReason = try values.decode(MetricsCountTable.self, forKey: .fallbackReason)
        cleanupLevel = try values.decode(MetricsCountTable.self, forKey: .cleanupLevel)
        modeKind = try values.decode(MetricsCountTable.self, forKey: .modeKind)
        modelState = try values.decode(MetricsCountTable.self, forKey: .modelState)
        words = try MetricsHistogram.decode(.words, from: values, forKey: .words)
        audioMilliseconds = try MetricsHistogram.decode(.audioMilliseconds, from: values, forKey: .audioMilliseconds)
        speechMilliseconds = try MetricsHistogram.decode(.speechMilliseconds, from: values, forKey: .speechMilliseconds)
        cleanupMilliseconds = try MetricsHistogram.decode(.cleanupMilliseconds, from: values, forKey: .cleanupMilliseconds)
        releaseToDeliveryMilliseconds = try MetricsHistogram.decode(
            .releaseToDeliveryMilliseconds, from: values, forKey: .releaseToDeliveryMilliseconds)
        do { try validate() } catch let error as MetricsValidationError { throw metricsDecodingFailure(decoder, error) }
    }

    public func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(delivery, forKey: .delivery)
        try values.encode(editObservation, forKey: .editObservation)
        try values.encode(editCoverage, forKey: .editCoverage)
        try values.encode(fallbackReason, forKey: .fallbackReason)
        try values.encode(cleanupLevel, forKey: .cleanupLevel)
        try values.encode(modeKind, forKey: .modeKind)
        try values.encode(modelState, forKey: .modelState)
        try values.encode(words, forKey: .words)
        try values.encode(audioMilliseconds, forKey: .audioMilliseconds)
        try values.encode(speechMilliseconds, forKey: .speechMilliseconds)
        try values.encode(cleanupMilliseconds, forKey: .cleanupMilliseconds)
        try values.encode(releaseToDeliveryMilliseconds, forKey: .releaseToDeliveryMilliseconds)
    }
}
