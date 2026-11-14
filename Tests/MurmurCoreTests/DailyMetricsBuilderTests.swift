import Foundation
import Testing
@testable import MurmurCore

@Suite("Usage metrics: daily builder")
struct DailyMetricsBuilderTests {
    typealias F = UsageMetricsFixtures

    @Test("only fully elapsed days are closed; today's events stay open")
    func closesOnlyPastDays() throws {
        let records = [
            F.record(.funnel(.firstDictation), at: F.noonOct3),
            F.record(.funnel(.microphoneGranted), at: F.noonOct4),
        ]
        let result = try F.builder().close(records: records, environment: F.environment, now: F.noonOct4)
        #expect(result.closedBatches.count == 1)
        #expect(result.closedBatches.first?.day.isoString == "2026-10-03")
        #expect(result.openRecords == [records[1]])
    }

    @Test("closing is deterministic in injected time: just before and after midnight")
    func midnightBoundary() throws {
        let midnight = F.noonOct4.addingTimeInterval(-12 * 3_600)
        let late = F.record(.funnel(.modelReady), at: midnight.addingTimeInterval(-1))
        let before = try F.builder().close(records: [late], environment: F.environment, now: midnight.addingTimeInterval(-1))
        #expect(before.closedBatches.isEmpty)
        let after = try F.builder().close(records: [late], environment: F.environment, now: midnight)
        #expect(after.closedBatches.count == 1)
    }

    @Test("a record's day is the one it was stamped with, in the time zone it was stamped in")
    func timeZoneDecidesDay() throws {
        var tokyo = Calendar(identifier: .gregorian)
        tokyo.timeZone = TimeZone(identifier: "Asia/Tokyo") ?? .gmt
        // 20:00 UTC on Oct 3 is 05:00 on Oct 4 in Tokyo.
        let evening = F.noonOct3.addingTimeInterval(8 * 3_600)
        let record = try MetricEventRecord(occurredAt: evening, calendar: tokyo, appBuild: 412, event: .funnel(.modelReady))
        #expect(record.day.isoString == "2026-10-04")
        // The builder's own time zone no longer moves it; only "today" is read in the builder's zone.
        let builder = DailyMetricsBuilder(calendar: F.utc, makeBatchID: F.sequentialIDs())
        let result = try builder.close(records: [record], environment: F.environment, now: F.noonOct5)
        #expect(result.closedBatches.first?.day.isoString == "2026-10-04")
    }

    @Test("a non-Gregorian calendar still yields Gregorian ISO days")
    func nonGregorianCalendar() throws {
        var buddhist = Calendar(identifier: .buddhist)
        buddhist.timeZone = TimeZone(identifier: "UTC") ?? .gmt
        let builder = DailyMetricsBuilder(calendar: buddhist, makeBatchID: F.sequentialIDs())
        let result = try builder.close(
            records: [F.record(.funnel(.modelReady))], environment: F.environment, now: F.noonOct5)
        #expect(result.closedBatches.first?.day.isoString == "2026-10-03")
    }

    @Test("builds are separate batches within one day, ordered by day then build")
    func splitsByBuild() throws {
        let records = [
            F.record(.funnel(.firstDictation), at: F.noonOct4, build: 413),
            F.record(.funnel(.firstDictation), at: F.noonOct3, build: 413),
            F.record(.funnel(.firstDictation), at: F.noonOct3, build: 412),
        ]
        let result = try F.builder().close(records: records, environment: F.environment, now: F.noonOct5)
        #expect(result.closedBatches.map(\.appBuild) == [412, 413, 413])
        #expect(result.closedBatches.map(\.day.isoString) == ["2026-10-03", "2026-10-03", "2026-10-04"])
        #expect(Set(result.closedBatches.map(\.batchID)).count == 3)
    }

    @Test("counts, sums and histograms add up per profile")
    func aggregation() throws {
        let records = [
            F.record(.dictation(F.dictation(F.feedback(edit: .kept, releaseToDelivery: 400), words: 10, audioMs: 3_000, speechMs: 150, cleanupMs: 600))),
            F.record(.dictation(F.dictation(F.feedback(edit: .edited, releaseToDelivery: 1_200), words: 50, audioMs: 20_000, speechMs: 500, cleanupMs: 1_500))),
            F.record(.dictation(F.dictation(F.feedback(delivery: .failed, edit: .unknown, releaseToDelivery: nil), words: 0, audioMs: 500, speechMs: nil, cleanupMs: nil, model: nil))),
            F.record(.dictation(F.dictation(F.feedback(profile: .rules, edit: .unknown, coverage: .secure)))),
        ]
        let batch = try #require(F.builder().close(records: records, environment: F.environment, now: F.noonOct5).closedBatches.first)
        let tuned = try #require(batch.dictationsByProfile[.localFineTuned])
        #expect(tuned.count == 3)
        #expect(tuned.delivery[.succeeded] == 2)
        #expect(tuned.delivery[.failed] == 1)
        #expect(tuned.editObservation[.kept] == 1)
        #expect(tuned.editObservation[.edited] == 1)
        #expect(tuned.editObservation[.unknown] == 1)
        #expect(tuned.words.sum == 60)
        #expect(tuned.words.sampleCount == 3)
        #expect(tuned.audioMilliseconds.sum == 23_500)
        #expect(tuned.speechMilliseconds.sampleCount == 2)
        #expect(tuned.cleanupMilliseconds.sum == 2_100)
        #expect(tuned.releaseToDeliveryMilliseconds.sum == 1_600)
        #expect(tuned.modelState[.warm] == 2)
        #expect(batch.dictationsByProfile[.rules]?.editCoverage[.secure] == 1)
        #expect(batch.combinedDictations.count == 4)
    }

    @Test("voice actions, meetings and funnel steps are counted")
    func otherActivity() throws {
        let records = [
            F.record(.voiceAction(VoiceActionMetricEvent(outcome: .succeeded, failure: nil))),
            F.record(.voiceAction(VoiceActionMetricEvent(outcome: .failed, failure: .notFound))),
            F.record(.meeting(MeetingMetricEvent(outcome: .started, minutesRecorded: nil))),
            F.record(.meeting(MeetingMetricEvent(outcome: .completed, minutesRecorded: 30))),
            F.record(.meeting(MeetingMetricEvent(outcome: .discarded, minutesRecorded: 5))),
            F.record(.funnel(.firstDictation)),
        ]
        let batch = try #require(F.builder().close(records: records, environment: F.environment, now: F.noonOct5).closedBatches.first)
        #expect(batch.voiceActions.attempted == 2)
        #expect(batch.voiceActions.failure[.notFound] == 1)
        #expect(batch.meetings.outcome[.started] == 1)
        #expect(batch.meetings.minutesRecorded == 35)
        #expect(batch.funnel[.firstDictation] == 1)
        #expect(batch.dictationsByProfile.isEmpty)
    }

    @Test("a day with more than the per-batch event cap is split, not truncated")
    func splitsOverCap() throws {
        let cap = MetricsLimits.maximumEventsPerBatch
        let records = (0..<(cap + 5)).map { _ in F.record(.funnel(.modelReady)) }
        let result = try F.builder().close(records: records, environment: F.environment, now: F.noonOct5)
        #expect(result.closedBatches.count == 2)
        #expect(result.closedBatches.map { $0.funnel[.modelReady] } == [cap, 5])
    }

    @Test("invalid build numbers and future events are not silently counted")
    func skipsInvalid() throws {
        let future = F.record(.funnel(.modelReady), at: F.noonOct5)
        let badBuild = F.record(.funnel(.modelReady), at: F.noonOct3, build: 0)
        let result = try F.builder().close(records: [future, badBuild], environment: F.environment, now: F.noonOct4)
        #expect(result.closedBatches.isEmpty)
        #expect(result.skippedRecordCount == 1)
        #expect(result.openRecords == [future])
    }

    @Test("building twice from the same input gives the same content but a fresh batch ID only per build call")
    func idsComeFromTheInjectedSource() throws {
        let records = [F.record(.funnel(.modelReady))]
        let first = try F.builder().close(records: records, environment: F.environment, now: F.noonOct5)
        let second = try F.builder().close(records: records, environment: F.environment, now: F.noonOct5)
        #expect(first.closedBatches == second.closedBatches)
        let random = try DailyMetricsBuilder(calendar: F.utc).close(records: records, environment: F.environment, now: F.noonOct5)
        #expect(random.closedBatches.first?.batchID != first.closedBatches.first?.batchID)
    }
}
