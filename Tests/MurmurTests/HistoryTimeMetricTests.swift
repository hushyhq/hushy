import Foundation
import MurmurCore
import Testing
@testable import Murmur

/// History's "Typed in" figure is in seconds with one decimal, never milliseconds.
@Suite("History time figure", .timeLimit(.minutes(1)))
struct HistoryTimeMetricTests {
    private func dictation(latencyMs: Int, status: Dictation.Status = .inserted) -> Dictation {
        Dictation(rawText: "a", text: "A", durationSeconds: 2, latencyMs: latencyMs, status: status)
    }

    @MainActor
    @Test("Typed in shows seconds, not milliseconds")
    func typedInIsSeconds() throws {
        let metric = try #require(HistoryDetailPane.timeMetric(for: dictation(latencyMs: 5_700)))
        #expect(metric.label == "Typed in")
        #expect(metric.value == "5.7 s")
        #expect(!metric.value.contains("ms"))
        #expect(try #require(HistoryDetailPane.timeMetric(for: dictation(latencyMs: 400))).value == "0.4 s")
    }

    @MainActor
    @Test("a dictation that was not typed says Processed in, and one with no time shows none")
    func otherCases() {
        #expect(HistoryDetailPane.timeMetric(for: dictation(latencyMs: 900, status: .notInserted))?.label == "Processed in")
        #expect(HistoryDetailPane.timeMetric(for: dictation(latencyMs: 0)) == nil)
    }
}
