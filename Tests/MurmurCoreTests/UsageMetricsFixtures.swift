import Foundation
@testable import MurmurCore

/// Shared builders for the usage-metrics tests. Deterministic: fixed calendar, fixed IDs.
enum UsageMetricsFixtures {
    static let utc: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC") ?? .gmt
        return calendar
    }()

    /// 2026-10-03 12:00:00 UTC.
    static let noonOct3 = Date(timeIntervalSince1970: 1_791_028_800)
    static let noonOct4 = noonOct3.addingTimeInterval(86_400)
    static let noonOct5 = noonOct3.addingTimeInterval(2 * 86_400)

    static let environment: MetricsEnvironment = {
        do { return try MetricsEnvironment(chipClass: .appleM3, memoryBand: .upTo16GB, macOSMajor: 27) }
        catch { fatalError("fixture environment invalid: \(error)") }
    }()

    static func sequentialIDs() -> @Sendable () -> UUID {
        let counter = Counter()
        return { counter.next() }
    }

    final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var value = 0
        func next() -> UUID {
            lock.lock(); defer { lock.unlock() }
            value += 1
            return UUID(uuidString: String(format: "00000000-0000-4000-8000-%012d", value)) ?? UUID()
        }
    }

    static func builder() -> DailyMetricsBuilder {
        DailyMetricsBuilder(calendar: utc, makeBatchID: sequentialIDs())
    }

    static func feedback(
        delivery: DictationFeedback.Delivery = .succeeded,
        profile: DictationFeedback.CleanupModelProfile = .localFineTuned,
        fallback: DictationFeedback.FallbackReason? = nil,
        edit: DictationFeedback.EditObservation = .kept,
        coverage: DictationFeedback.EditCoverage? = nil,
        releaseToDelivery: Int? = 900
    ) -> DictationFeedback {
        let resolved = coverage ?? (edit == .unknown ? .notAttempted : .observed)
        do {
            return try DictationFeedback(
                delivery: delivery, cleanupModelProfile: profile, fallbackReason: fallback,
                editObservation: edit, editCoverage: resolved, releaseToDeliveryMilliseconds: releaseToDelivery)
        } catch { fatalError("fixture feedback invalid: \(error)") }
    }

    static func dictation(
        _ feedback: DictationFeedback? = nil,
        level: CleanupLevel = .clean,
        mode: MetricsModeKind = .standard,
        words: Int = 25,
        audioMs: Int = 9_000,
        speechMs: Int? = 300,
        cleanupMs: Int? = 700,
        model: MetricsModelState? = .warm,
        tone: MetricsTone? = nil,
        appKind: MetricsAppKind? = nil,
        editSize: MetricsEditSize? = nil
    ) -> DictationMetricEvent {
        DictationMetricEvent(
            feedback: feedback ?? self.feedback(), cleanupLevel: level, modeKind: mode, wordCount: words,
            audioMilliseconds: audioMs, speechMilliseconds: speechMs, cleanupMilliseconds: cleanupMs, modelState: model, tone: tone,
            appKind: appKind, editSize: editSize)
    }

    static func record(_ event: MetricEvent, at date: Date = noonOct3, build: Int = 412) -> MetricEventRecord {
        do { return try MetricEventRecord(occurredAt: date, calendar: utc, appBuild: build, event: event) }
        catch { fatalError("fixture record invalid: \(error)") }
    }

    /// A batch in which every enum case of every table is non-zero.
    static func fullyPopulatedBatch() throws -> DailyMetricsBatch {
        var records: [MetricEventRecord] = []
        for profile in DictationFeedback.CleanupModelProfile.allCases {
            records.append(record(.dictation(dictation(feedback(profile: profile)))))
        }
        for delivery in DictationFeedback.Delivery.allCases where delivery != .succeeded {
            records.append(record(.dictation(dictation(feedback(delivery: delivery, edit: .unknown, releaseToDelivery: nil)))))
        }
        for coverage in DictationFeedback.EditCoverage.allCases where coverage != .observed {
            records.append(record(.dictation(dictation(feedback(edit: .unknown, coverage: coverage)))))
        }
        records.append(record(.dictation(dictation(feedback(edit: .edited)))))
        for reason in DictationFeedback.FallbackReason.allCases {
            records.append(record(.dictation(dictation(feedback(fallback: reason)))))
        }
        for level in CleanupLevel.allCases { records.append(record(.dictation(dictation(level: level)))) }
        for mode in MetricsModeKind.allCases { records.append(record(.dictation(dictation(mode: mode)))) }
        for model in MetricsModelState.allCases { records.append(record(.dictation(dictation(model: model)))) }
        for tone in MetricsTone.allCases { records.append(record(.dictation(dictation(tone: tone)))) }
        // The edit rate: every kind of app kept as typed, every edit size, a cleared field and a dictation not checked.
        for (index, kind) in MetricsAppKind.allCases.enumerated() {
            let tone = MetricsTone.allCases[index % MetricsTone.allCases.count]
            records.append(record(.dictation(dictation(tone: tone, appKind: kind))))
        }
        for size in [MetricsEditSize.words1to2, .words3to10, .wordsMore] {
            records.append(record(.dictation(dictation(feedback(edit: .edited), tone: .casual, appKind: .email, editSize: size))))
        }
        records.append(record(.dictation(dictation(feedback(edit: .unknown, coverage: .fieldCleared), tone: .refined, appKind: .code))))
        records.append(record(.dictation(dictation(feedback(edit: .unknown, coverage: .notAttempted), tone: .refined, appKind: .code))))
        for outcome in VoiceActionOutcome.allCases {
            records.append(record(.voiceAction(VoiceActionMetricEvent(outcome: outcome, failure: nil))))
        }
        for failure in VoiceActionFailureCategory.allCases {
            records.append(record(.voiceAction(VoiceActionMetricEvent(outcome: .failed, failure: failure))))
        }
        for outcome in MeetingOutcome.allCases {
            records.append(record(.meeting(MeetingMetricEvent(outcome: outcome, minutesRecorded: outcome == .started ? nil : 42))))
        }
        for step in FunnelStep.allCases { records.append(record(.funnel(step))) }
        let result = try builder().close(records: records, environment: environment, now: noonOct4)
        guard let batch = result.closedBatches.first, result.closedBatches.count == 1 else {
            fatalError("expected exactly one batch, got \(result.closedBatches.count)")
        }
        return batch
    }

    static func tempDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("hushy-metrics-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    static func simpleBatch(id: UUID = UUID(), dayOffset: Int = 0, words: Int = 25) throws -> DailyMetricsBatch {
        let date = noonOct3.addingTimeInterval(Double(dayOffset) * 86_400)
        let ids: @Sendable () -> UUID = { id }
        let result = try DailyMetricsBuilder(calendar: utc, makeBatchID: ids).close(
            records: [record(.dictation(dictation(words: words)), at: date)],
            environment: environment, now: date.addingTimeInterval(2 * 86_400))
        guard let batch = result.closedBatches.first else { fatalError("no batch") }
        return batch
    }
}
