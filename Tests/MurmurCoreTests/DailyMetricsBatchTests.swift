import Foundation
import Testing
@testable import MurmurCore

@Suite("Usage metrics: daily batch encoding and validation")
struct DailyMetricsBatchTests {
    private func json(of batch: DailyMetricsBatch) throws -> [String: Any] {
        let data = try batch.encodedBody()
        return try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    private func decode(_ object: [String: Any]) throws -> DailyMetricsBatch {
        try JSONDecoder().decode(DailyMetricsBatch.self, from: JSONSerialization.data(withJSONObject: object))
    }

    private func decodeFails(_ object: [String: Any]) -> Bool {
        do { _ = try decode(object); return false } catch { return true }
    }

    @Test("a batch round-trips through JSON unchanged and its body is byte-stable")
    func roundTrip() throws {
        let batch = try UsageMetricsFixtures.fullyPopulatedBatch()
        let data = try batch.encodedBody()
        let decoded = try JSONDecoder().decode(DailyMetricsBatch.self, from: data)
        #expect(decoded == batch)
        #expect(try decoded.encodedBody() == data)
    }

    @Test("an unknown top-level key is rejected")
    func unknownTopLevelKey() throws {
        var object = try json(of: try UsageMetricsFixtures.simpleBatch())
        object["note"] = "hello"
        #expect(decodeFails(object))
    }

    @Test("an unknown key inside any nested object is rejected")
    func unknownNestedKey() throws {
        let batch = try UsageMetricsFixtures.fullyPopulatedBatch()
        for path in [["environment"], ["voiceActions"], ["meetings"], ["funnel"], ["dictations", "rules"],
                     ["dictations", "rules", "words"], ["dictations", "rules", "delivery"]] {
            var object = try json(of: batch)
            object = try inserting(key: "extra", into: object, at: path)
            #expect(decodeFails(object), "nested key accepted at \(path)")
        }
    }

    private func inserting(key: String, into object: [String: Any], at path: [String]) throws -> [String: Any] {
        guard let head = path.first else { var copy = object; copy[key] = 1; return copy }
        var copy = object
        let child = try #require(copy[head] as? [String: Any], "missing \(head)")
        copy[head] = try inserting(key: key, into: child, at: Array(path.dropFirst()))
        return copy
    }

    @Test("negative numbers are rejected")
    func negativeNumbers() throws {
        var object = try json(of: try UsageMetricsFixtures.simpleBatch())
        var dictations = try #require(object["dictations"] as? [String: Any])
        var totals = try #require(dictations["localFineTuned"] as? [String: Any])
        var delivery = try #require(totals["delivery"] as? [String: Any])
        delivery["failed"] = -1
        totals["delivery"] = delivery
        dictations["localFineTuned"] = totals
        object["dictations"] = dictations
        #expect(decodeFails(object))
    }

    @Test("a broken kept + edited + unknown invariant is rejected")
    func brokenEditInvariant() throws {
        var object = try json(of: try UsageMetricsFixtures.simpleBatch())
        var dictations = try #require(object["dictations"] as? [String: Any])
        var totals = try #require(dictations["localFineTuned"] as? [String: Any])
        var observation = try #require(totals["editObservation"] as? [String: Any])
        observation["unknown"] = 3
        totals["editObservation"] = observation
        dictations["localFineTuned"] = totals
        object["dictations"] = dictations
        #expect(decodeFails(object))
    }

    @Test("bad day, build, schema version and enum keys are rejected")
    func badScalars() throws {
        let base = try json(of: try UsageMetricsFixtures.simpleBatch())
        for (key, value) in [("day", "2026-13-01" as Any), ("day", "2026-10-3"), ("day", "yesterday"), ("appBuild", 0),
                             ("appBuild", -3), ("schemaVersion", 5), ("schemaVersion", 0), ("batchID", "not-a-uuid")] {
            var object = base
            object[key] = value
            #expect(decodeFails(object), "\(key)=\(value) accepted")
        }
        var object = base
        object["dictations"] = ["My Custom Mode": [String: Any]()]
        #expect(decodeFails(object))
    }

    @Test("an empty batch cannot be constructed")
    func emptyBatch() throws {
        #expect(throws: MetricsValidationError.emptyBatch) {
            try DailyMetricsBatch(
                batchID: UUID(), day: MetricsDay(year: 2026, month: 10, day: 3), appBuild: 1,
                environment: UsageMetricsFixtures.environment, dictationsByProfile: [:],
                voiceActions: VoiceActionTotals(), meetings: MeetingTotals(), funnel: MetricsCountTable(),
                retention: MetricsRetention(daysSinceFirstRun: .day0, activeDaysLast7: 1), tones: MetricsCountTable())
        }
    }

    @Test("the histogram sum must fit its buckets when decoded")
    func histogramSumChecked() throws {
        var object = try json(of: try UsageMetricsFixtures.simpleBatch())
        var dictations = try #require(object["dictations"] as? [String: Any])
        var totals = try #require(dictations["localFineTuned"] as? [String: Any])
        var words = try #require(totals["words"] as? [String: Any])
        words["sum"] = 9_999
        totals["words"] = words
        dictations["localFineTuned"] = totals
        object["dictations"] = dictations
        #expect(decodeFails(object))
    }

    @Test("days validate as real calendar dates and round-trip as ISO strings")
    func days() throws {
        #expect(MetricsDay(isoString: "2026-02-29") == nil)
        #expect(MetricsDay(isoString: "2028-02-29")?.isoString == "2028-02-29")
        #expect(MetricsDay(isoString: "2026-10-03 ") == nil)
        #expect(try MetricsDay(year: 2026, month: 10, day: 3) < MetricsDay(year: 2026, month: 10, day: 4))
        #expect(throws: MetricsValidationError.invalidDay) { try MetricsDay(year: 2026, month: 4, day: 31) }
    }

    @Test("an encoded batch stays under the planned ingest size even when fully populated")
    func sizeBound() throws {
        let data = try UsageMetricsFixtures.fullyPopulatedBatch().encodedBody()
        #expect(data.count < MetricsLimits.maximumEncodedBatchBytes)
    }
}
