import Foundation
import Testing
@testable import MurmurCore

@Suite("Content-free dictation feedback")
struct DictationFeedbackTests {
    @Test("negative decoded timings are rejected rather than counted as zero")
    func negativeDecodedTiming() throws {
        let value = try record(edit: .unknown, coverage: .notAttempted, duration: 1)
        let encoded = try JSONEncoder().encode(value)
        var object = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        object["releaseToDeliveryMilliseconds"] = -1
        let malformed = try JSONSerialization.data(withJSONObject: object)
        #expect(throws: DecodingError.self) { try JSONDecoder().decode(DictationFeedback.self, from: malformed) }
    }

    @Test("unknown observations are covered but never counted as kept")
    func unknownIsNotKept() throws {
        var aggregate = DictationFeedbackAggregate()
        aggregate.record(try record(edit: .unknown, coverage: .fieldCleared))
        aggregate.record(try record(edit: .kept, coverage: .observed))

        #expect(aggregate.kept == 1)
        #expect(aggregate.unknown == 1)
        #expect(aggregate.editCoverageUnavailable == 1)
        #expect(aggregate.editCoverageCounts[.fieldCleared] == 1)
        #expect(aggregate.editCoverageCounts[.observed] == 1)
        #expect(aggregate.editFreeRate == 1)
    }

    @Test("edit rate uses observed kept and edited outcomes as its denominator")
    func coverageDenominator() throws {
        var aggregate = DictationFeedbackAggregate()
        aggregate.record(try record(edit: .kept, coverage: .observed))
        aggregate.record(try record(edit: .edited, coverage: .observed))
        aggregate.record(try record(edit: .unknown, coverage: .fieldUnreadable))
        aggregate.record(try record(edit: .unknown, coverage: .notAttempted))

        #expect(aggregate.editObservationCount == 2)
        #expect(aggregate.editCoverageObserved == 2)
        #expect(aggregate.editCoverageUnavailable == 2)
        #expect(aggregate.editFreeRate == 0.5)
    }

    @Test("closed dimensions aggregate outcomes, fallback, provenance and bounded timing")
    func aggregationAndBounds() throws {
        var aggregate = DictationFeedbackAggregate()
        aggregate.record(try record(
            delivery: .failed, model: .localFineTuned, fallback: .modelTimedOut,
            edit: .unknown, coverage: .notAttempted, duration: nil
        ))
        aggregate.record(try record(
            delivery: .cancelled, model: .rules, fallback: nil,
            edit: .unknown, coverage: .notAttempted, duration: nil
        ))
        aggregate.record(try record(
            delivery: .succeeded, model: .localUntuned, fallback: nil,
            edit: .unknown, coverage: .notAttempted, duration: 900_000
        ))

        #expect(aggregate.deliveryCount == 3)
        #expect(aggregate.failed == 1)
        #expect(aggregate.cancelled == 1)
        #expect(aggregate.releaseToDeliveryMillisecondsTotal == DictationFeedback.maximumReleaseToDeliveryMilliseconds)
        #expect(aggregate.timingSampleCount == 1)
        #expect(aggregate.fallbackCounts[.modelTimedOut] == 1)
        #expect(aggregate.cleanupModelCounts[.localFineTuned] == 1)
        #expect(aggregate.cleanupModelCounts[.rules] == 1)
    }

    @Test("missing timing is excluded from timing totals and sample count")
    func missingTiming() throws {
        var aggregate = DictationFeedbackAggregate()
        aggregate.record(try record(edit: .unknown, coverage: .notAttempted, duration: nil))
        #expect(aggregate.releaseToDeliveryMillisecondsTotal == 0)
        #expect(aggregate.timingSampleCount == 0)
    }

    @Test("serialized contract contains only closed categories and numeric timing")
    func contentFreeSerialization() throws {
        let value = try record(edit: .kept, coverage: .observed)
        let data = try JSONEncoder().encode(value)
        let json = String(decoding: data, as: UTF8.self)
        let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])

        #expect(Set(object.keys) == [
            "delivery", "cleanupModelProfile", "editObservation", "editCoverage", "releaseToDeliveryMilliseconds",
        ])
        #expect(json.contains("\"releaseToDeliveryMilliseconds\":1234"))
        #expect(!json.contains("text"))
        #expect(!json.contains("audio"))
        #expect(!json.contains("session"))
        #expect(try JSONDecoder().decode(DictationFeedback.self, from: data) == value)
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(DictationFeedback.self, from: Data(#"{"delivery":"succeeded","cleanupModelProfile":"rules","editObservation":"unknown","editCoverage":"notAttempted","text":"private"}"#.utf8))
        }
    }

    @Test("edit state and coverage must agree")
    func validatesCoverage() {
        #expect(throws: DictationFeedback.ValidationError.inconsistentEditCoverage) {
            try record(edit: .kept, coverage: .fieldUnreadable)
        }
        #expect(throws: DictationFeedback.ValidationError.inconsistentEditCoverage) {
            try record(edit: .unknown, coverage: .observed)
        }
        #expect(throws: DictationFeedback.ValidationError.inconsistentEditCoverage) {
            try record(delivery: .failed, edit: .kept, coverage: .observed, duration: nil)
        }
        #expect(throws: DictationFeedback.ValidationError.timingWithoutDelivery) {
            try record(delivery: .cancelled, edit: .unknown, coverage: .notAttempted, duration: 200)
        }
    }

    private func record(
        delivery: DictationFeedback.Delivery = .succeeded,
        model: DictationFeedback.CleanupModelProfile = .appleSystem,
        fallback: DictationFeedback.FallbackReason? = nil,
        edit: DictationFeedback.EditObservation,
        coverage: DictationFeedback.EditCoverage,
        duration: Int? = 1_234
    ) throws -> DictationFeedback {
        try DictationFeedback(
            delivery: delivery,
            cleanupModelProfile: model,
            fallbackReason: fallback,
            editObservation: edit,
            editCoverage: coverage,
            releaseToDeliveryMilliseconds: duration
        )
    }
}
