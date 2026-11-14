import Foundation

/// One immutable day of content-free aggregates for one app build. This is the only thing that
/// is ever stored in the upload queue or sent: counts, sums and fixed-bucket histograms.
///
/// What is deliberately not here: any install, device or user identifier (`batchID` is a random
/// UUID created once when the day is closed, and identifies the batch only), any app name, and
/// any timestamp finer than the calendar day. An install identifier can be added later as a new
/// optional field under a new `schemaVersion`; nothing in this type's shape depends on its absence.
/// The one thing said about apps is `editRate`'s `appKind`, a value from a closed list of seven kinds
/// (email, code, documents...), never a name.
///
/// Schema versions: 1 is the original shape. 2 adds `retention` (two coarse local numbers, no
/// identifier). Version 1 batches still decode (with `retention == nil`) and encode to exactly the
/// bytes they had, so a batch queued by an older build is uploaded unchanged. 3 adds `tones` (how
/// many dictations ran with each tone: counts only, no app, no text). Version 2 batches decode with
/// `tones == nil` and re-encode to exactly the bytes they had. 4 adds `editRate` (how many pasted
/// dictations were kept as typed, edited and by how much, or not checked, per tone and kind of app:
/// counts only). Version 3 batches decode with `editRate == nil` and re-encode to exactly the bytes
/// they had. Every batch built now is version 4.
public struct DailyMetricsBatch: Codable, Sendable, Equatable {
    public static let currentSchemaVersion = 4
    public static let supportedSchemaVersions: ClosedRange<Int> = 1...4

    public let schemaVersion: Int
    public let batchID: UUID
    public let day: MetricsDay
    public let appBuild: Int
    public let environment: MetricsEnvironment
    /// Dictation totals per cleanup profile; a profile with no dictations has no entry.
    public let dictationsByProfile: [DictationFeedback.CleanupModelProfile: DictationMetricTotals]
    public let voiceActions: VoiceActionTotals
    public let meetings: MeetingTotals
    public let funnel: MetricsCountTable<FunnelStep>
    /// Nil only for a version 1 batch decoded from an older queue file.
    public let retention: MetricsRetention?
    /// Dictations per tone they ran with. Nil only for a version 1 or 2 batch decoded from an older queue
    /// file. Each dictation counts at most once, so its total never exceeds the number of dictations.
    public let tones: MetricsCountTable<MetricsTone>?
    /// Pasted dictations by tone, kind of app, verdict and edit size. Nil only for a version 1 to 3 batch decoded
    /// from an older queue file. Each dictation counts at most once.
    public let editRate: MetricsEditRateTable?

    public init(
        batchID: UUID, day: MetricsDay, appBuild: Int, environment: MetricsEnvironment,
        dictationsByProfile: [DictationFeedback.CleanupModelProfile: DictationMetricTotals],
        voiceActions: VoiceActionTotals, meetings: MeetingTotals, funnel: MetricsCountTable<FunnelStep>,
        retention: MetricsRetention, tones: MetricsCountTable<MetricsTone>,
        editRate: MetricsEditRateTable = MetricsEditRateTable()
    ) throws {
        self.schemaVersion = Self.currentSchemaVersion
        self.batchID = batchID
        self.day = day
        self.appBuild = appBuild
        self.environment = environment
        self.dictationsByProfile = dictationsByProfile
        self.voiceActions = voiceActions
        self.meetings = meetings
        self.funnel = funnel
        self.retention = retention
        self.tones = tones
        self.editRate = editRate
        try validate()
    }

    /// All dictation totals added together across profiles.
    public var combinedDictations: DictationMetricTotals {
        dictationsByProfile.values.reduce(DictationMetricTotals()) { $0.merged(with: $1) }
    }

    /// Events folded into this batch.
    public var eventCount: Int {
        [combinedDictations.count, voiceActions.attempted, meetings.outcome.total, funnel.total].reduce(0, MetricsMath.add)
    }

    /// The exact bytes to upload: sorted keys, no whitespace. The same batch always produces the
    /// same bytes, so a retried upload is byte-identical.
    public func encodedBody() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(self)
    }

    private func validate() throws {
        guard Self.supportedSchemaVersions.contains(schemaVersion) else { throw MetricsValidationError.invalidSchemaVersion }
        guard (retention != nil) == (schemaVersion >= 2) else { throw MetricsValidationError.invalidSchemaVersion }
        guard (tones != nil) == (schemaVersion >= 3) else { throw MetricsValidationError.invalidSchemaVersion }
        guard (editRate != nil) == (schemaVersion >= 4) else { throw MetricsValidationError.invalidSchemaVersion }
        guard (1...Int(Int32.max)).contains(appBuild) else { throw MetricsValidationError.invalidBuild }
        try dictationsByProfile.values.forEach { try $0.validate() }
        try voiceActions.validate()
        try meetings.validate()
        try funnel.validate()
        try tones?.validate()
        guard (tones?.total ?? 0) <= combinedDictations.count else { throw MetricsValidationError.inconsistentTones }
        try editRate?.validate()
        try validateEditRateAgainstDictations()
        guard eventCount > 0 else { throw MetricsValidationError.emptyBatch }
        guard eventCount <= MetricsLimits.maximumEventsPerBatch else { throw MetricsValidationError.tooManyEvents }
    }

    /// The edit-rate cells are a subset of the dictations counted elsewhere in the batch: no more pasted
    /// dictations than were pasted, no more kept or edited than the edit watcher found, no more cleared
    /// fields than were seen empty, and no more in a tone than ran with it.
    private func validateEditRateAgainstDictations() throws {
        guard let editRate else { return }
        let dictations = combinedDictations
        let consistent = editRate.total <= dictations.delivery[.succeeded]
            && editRate.total(verdict: .kept) <= dictations.editObservation[.kept]
            && editRate.total(verdict: .edited) <= dictations.editObservation[.edited]
            && editRate.total(verdict: .fieldCleared) <= dictations.editCoverage[.fieldCleared]
            && MetricsTone.allCases.allSatisfy { editRate.total(tone: $0) <= (tones?[$0] ?? 0) }
        guard consistent else { throw MetricsValidationError.inconsistentEditRate }
    }

    private static let fieldNames: Set<String> = [
        "schemaVersion", "batchID", "day", "appBuild", "environment", "dictations", "voiceActions", "meetings", "funnel",
        "retention", "tones", "editRate",
    ]

    private enum CodingKeys: String, CodingKey {
        case schemaVersion, batchID, day, appBuild, environment, dictations, voiceActions, meetings, funnel, retention, tones, editRate
    }

    public init(from decoder: Decoder) throws {
        try decoder.requireOnlyKeys(Self.fieldNames)
        let values = try decoder.container(keyedBy: CodingKeys.self)
        let version = try values.decode(Int.self, forKey: .schemaVersion)
        guard Self.supportedSchemaVersions.contains(version) else {
            throw metricsDecodingFailure(decoder, .invalidSchemaVersion)
        }
        schemaVersion = version
        batchID = try values.decode(UUID.self, forKey: .batchID)
        day = try values.decode(MetricsDay.self, forKey: .day)
        appBuild = try values.decode(Int.self, forKey: .appBuild)
        environment = try values.decode(MetricsEnvironment.self, forKey: .environment)
        dictationsByProfile = try Self.decodeProfiles(values, forKey: .dictations)
        voiceActions = try values.decode(VoiceActionTotals.self, forKey: .voiceActions)
        meetings = try values.decode(MeetingTotals.self, forKey: .meetings)
        funnel = try values.decode(MetricsCountTable.self, forKey: .funnel)
        retention = try values.decodeIfPresent(MetricsRetention.self, forKey: .retention)
        tones = try values.decodeIfPresent(MetricsCountTable<MetricsTone>.self, forKey: .tones)
        editRate = try values.decodeIfPresent(MetricsEditRateTable.self, forKey: .editRate)
        do { try validate() } catch let error as MetricsValidationError { throw metricsDecodingFailure(decoder, error) }
    }

    private static func decodeProfiles(
        _ values: KeyedDecodingContainer<CodingKeys>, forKey key: CodingKeys
    ) throws -> [DictationFeedback.CleanupModelProfile: DictationMetricTotals] {
        let nested = try values.nestedContainer(keyedBy: MetricsCodingKey.self, forKey: key)
        var result: [DictationFeedback.CleanupModelProfile: DictationMetricTotals] = [:]
        for codingKey in nested.allKeys {
            guard let profile = DictationFeedback.CleanupModelProfile(rawValue: codingKey.stringValue) else {
                throw DecodingError.dataCorruptedError(forKey: key, in: values, debugDescription: "Unexpected cleanup profile")
            }
            result[profile] = try nested.decode(DictationMetricTotals.self, forKey: codingKey)
        }
        return result
    }

    public func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(schemaVersion, forKey: .schemaVersion)
        try values.encode(batchID, forKey: .batchID)
        try values.encode(day, forKey: .day)
        try values.encode(appBuild, forKey: .appBuild)
        try values.encode(environment, forKey: .environment)
        var profiles = values.nestedContainer(keyedBy: MetricsCodingKey.self, forKey: .dictations)
        for (profile, totals) in dictationsByProfile {
            try profiles.encode(totals, forKey: MetricsCodingKey(profile.rawValue))
        }
        try values.encode(voiceActions, forKey: .voiceActions)
        try values.encode(meetings, forKey: .meetings)
        try values.encode(funnel, forKey: .funnel)
        try values.encodeIfPresent(retention, forKey: .retention)
        try values.encodeIfPresent(tones, forKey: .tones)
        try values.encodeIfPresent(editRate, forKey: .editRate)
    }
}
