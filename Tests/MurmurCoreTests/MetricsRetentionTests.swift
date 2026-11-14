import Foundation
import Testing
@testable import MurmurCore

@Suite("Usage metrics: retention numbers and schema version 2")
struct MetricsRetentionTests {
    typealias F = UsageMetricsFixtures

    private func day(_ y: Int, _ m: Int, _ d: Int) throws -> MetricsDay { try MetricsDay(year: y, month: m, day: d) }

    @Test("days since first run fall into the five bands at their exact edges")
    func bandEdges() {
        let expected: [(Int, MetricsRetention.FirstRunBand)] = [
            (-3, .day0), (0, .day0), (1, .days1to6), (6, .days1to6), (7, .days7to29), (29, .days7to29),
            (30, .days30to89), (89, .days30to89), (90, .days90plus), (400, .days90plus),
        ]
        for (days, band) in expected { #expect(MetricsRetention.FirstRunBand(daysSinceFirstRun: days) == band, "days=\(days)") }
    }

    @Test("band is computed from the first-run day to the batch day")
    func bandFromDays() throws {
        let first = try day(2026, 1, 1)
        for (offset, band) in [(0, MetricsRetention.FirstRunBand.day0), (6, .days1to6), (7, .days7to29), (29, .days7to29),
                               (30, .days30to89), (89, .days30to89), (90, .days90plus)] {
            let batchDay = try first.adding(days: offset)
            #expect(MetricsRetention.compute(on: batchDay, firstRunDay: first, activeDays: []).daysSinceFirstRun == band, "offset=\(offset)")
        }
    }

    @Test("a missing first-run day, or one after the batch day, reads as the batch day itself")
    func missingFirstRun() throws {
        let batchDay = try day(2026, 10, 3)
        #expect(MetricsRetention.compute(on: batchDay, firstRunDay: nil, activeDays: []).daysSinceFirstRun == .day0)
        #expect(MetricsRetention.compute(on: batchDay, firstRunDay: try day(2026, 11, 1), activeDays: []).daysSinceFirstRun == .day0)
    }

    @Test("active days in the last 7 counts the batch day and the six before it, and nothing else")
    func activeWindowEdges() throws {
        let batchDay = try day(2026, 10, 10)
        func count(_ offsets: [Int]) throws -> Int {
            let days = try Set(offsets.map { try batchDay.adding(days: $0) })
            return MetricsRetention.compute(on: batchDay, firstRunDay: nil, activeDays: days).activeDaysLast7
        }
        #expect(try count([]) == 1)                                // the batch day itself is always active
        #expect(try count([0]) == 1)
        #expect(try count([-6, 0]) == 2)                           // six days back: inside
        #expect(try count([-7, 0]) == 1)                           // seven days back: outside
        #expect(try count([1, 2, 0]) == 1)                         // later days never count
        #expect(try count([0, -1, -2, -3, -4, -5, -6]) == 7)       // the maximum
        #expect(try count([0, -1, -2, -3, -4, -5, -6, -7, -8]) == 7)
    }

    @Test("day arithmetic crosses months, years and leap days correctly and round-trips")
    func dayArithmetic() throws {
        #expect(try day(2026, 10, 3).adding(days: 29) == day(2026, 11, 1))
        #expect(try day(2026, 12, 31).adding(days: 1) == day(2027, 1, 1))
        #expect(try day(2028, 2, 28).adding(days: 1) == day(2028, 2, 29))
        #expect(try day(2028, 3, 1).adding(days: -1) == day(2028, 2, 29))
        #expect(try day(2026, 3, 1).adding(days: -1) == day(2026, 2, 28))
        #expect(try day(2026, 10, 3).days(since: day(2026, 1, 1)) == 275)
        #expect(throws: MetricsValidationError.invalidDay) { try day(2026, 6, 15).adding(days: Int.max) }
        #expect(throws: MetricsValidationError.invalidDay) { try day(2026, 6, 15).adding(days: Int.min) }
        for offset in stride(from: -800, through: 800, by: 37) {
            let start = try day(2026, 6, 15)
            #expect(try start.adding(days: offset).days(since: start) == offset)
        }
    }

    @Test("the builder gives every closed batch the numbers for its own day")
    func builderComputesPerBatchDay() throws {
        let first = try MetricsDay(year: 2026, month: 9, day: 20)
        let input = MetricsRetentionInput(
            firstRunDay: first,
            activeDays: [try day(2026, 9, 30), try day(2026, 10, 1), try day(2026, 10, 2)])
        let records = [F.record(.funnel(.firstDictation), at: F.noonOct3), F.record(.funnel(.modelReady), at: F.noonOct4)]
        let result = try F.builder().close(records: records, environment: F.environment, now: F.noonOct5, retention: input)
        let october3 = try #require(result.closedBatches.first)
        let october4 = try #require(result.closedBatches.last)
        // Oct 3: first run 13 days ago; active Sep 30, Oct 1, Oct 2 and Oct 3 itself.
        #expect(october3.retention == (try MetricsRetention(daysSinceFirstRun: .days7to29, activeDaysLast7: 4)))
        // Oct 4: adds Oct 4 itself (from its own records) to the same set.
        #expect(october4.retention == (try MetricsRetention(daysSinceFirstRun: .days7to29, activeDaysLast7: 5)))
    }

    @Test("a new batch is schema version 4 and encodes retention, tones and the edit rate and nothing else new")
    func newBatchShape() throws {
        let batch = try F.simpleBatch()
        #expect(batch.schemaVersion == 4 && DailyMetricsBatch.currentSchemaVersion == 4)
        let object = try #require(JSONSerialization.jsonObject(with: batch.encodedBody()) as? [String: Any])
        #expect(Set(object.keys) == ["schemaVersion", "batchID", "day", "appBuild", "environment", "dictations",
                                      "voiceActions", "meetings", "funnel", "retention", "tones", "editRate"])
        let retention = try #require(object["retention"] as? [String: Any])
        #expect(Set(retention.keys) == ["daysSinceFirstRun", "activeDaysLast7"])
        #expect(retention["daysSinceFirstRun"] as? String == "day0")
        #expect(retention["activeDaysLast7"] as? Int == 1)
    }

    @Test("a version 1 batch from an older queue file still decodes and re-encodes to the same bytes")
    func versionOneStillWorks() throws {
        var object = try #require(JSONSerialization.jsonObject(with: F.simpleBatch().encodedBody()) as? [String: Any])
        object["schemaVersion"] = 1
        object["retention"] = nil
        object["tones"] = nil
        object["editRate"] = nil
        let oldBytes = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes])
        let decoded = try JSONDecoder().decode(DailyMetricsBatch.self, from: oldBytes)
        #expect(decoded.schemaVersion == 1)
        #expect(decoded.retention == nil)
        #expect(try decoded.encodedBody() == oldBytes)
    }

    @Test("version and retention must agree: v1 with retention, v2 without, and bad values are rejected")
    func versionAndRetentionAgree() throws {
        let base = try #require(JSONSerialization.jsonObject(with: F.simpleBatch().encodedBody()) as? [String: Any])
        func rejected(_ mutate: (inout [String: Any]) -> Void) -> Bool {
            var object = base
            mutate(&object)
            guard let data = try? JSONSerialization.data(withJSONObject: object) else { return false }
            return (try? JSONDecoder().decode(DailyMetricsBatch.self, from: data)) == nil
        }
        #expect(rejected { $0["schemaVersion"] = 1 })                                   // v1 must not carry retention (or tones)
        #expect(rejected { $0["retention"] = nil })                                     // v2 must carry it
        #expect(rejected { $0["retention"] = ["daysSinceFirstRun": "day0", "activeDaysLast7": 8] })
        #expect(rejected { $0["retention"] = ["daysSinceFirstRun": "day0", "activeDaysLast7": -1] })
        #expect(rejected { $0["retention"] = ["daysSinceFirstRun": "someday", "activeDaysLast7": 1] })
        #expect(rejected { $0["retention"] = ["daysSinceFirstRun": "day0", "activeDaysLast7": 1, "installID": "x"] })
    }

    @Test("the disclosure shows both new numbers in plain words")
    func disclosureShowsRetention() throws {
        let lines = MetricsDisclosure.lines(for: try F.simpleBatch())
        #expect(lines.contains("Time since you started using Hushy: the same day"))
        #expect(lines.contains("Days you used Hushy in the last week: 1 of 7"))
    }
}
