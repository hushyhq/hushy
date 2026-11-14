import Foundation
import Testing
@testable import MurmurCore

@Suite("Usage metrics: what-is-sent disclosure")
struct MetricsDisclosureTests {
    typealias F = UsageMetricsFixtures

    private func batch() throws -> DailyMetricsBatch {
        var records: [MetricEventRecord] = []
        for _ in 0..<30 { records.append(F.record(.dictation(F.dictation(F.feedback(edit: .kept))))) }
        for _ in 0..<6 { records.append(F.record(.dictation(F.dictation(F.feedback(edit: .edited))))) }
        for _ in 0..<4 { records.append(F.record(.dictation(F.dictation(F.feedback(edit: .unknown, coverage: .secure))))) }
        records.append(F.record(.dictation(F.dictation(F.feedback(delivery: .failed, edit: .unknown, releaseToDelivery: nil)))))
        records.append(F.record(.dictation(F.dictation(F.feedback(delivery: .cancelled, edit: .unknown, releaseToDelivery: nil)))))
        records.append(F.record(.voiceAction(VoiceActionMetricEvent(outcome: .failed, failure: .permissionDenied))))
        records.append(F.record(.voiceAction(VoiceActionMetricEvent(outcome: .succeeded, failure: nil))))
        records.append(F.record(.meeting(MeetingMetricEvent(outcome: .completed, minutesRecorded: 45))))
        records.append(F.record(.funnel(.firstDictation)))
        return try #require(F.builder().close(records: records, environment: F.environment, now: F.noonOct5).closedBatches.first)
    }

    @Test("the headline lines say plainly what a person would want to check")
    func headlineLines() throws {
        let lines = MetricsDisclosure.lines(for: try batch())
        #expect(lines.contains("Day: 2026-10-03"))
        #expect(lines.contains("App build: 412"))
        #expect(lines.contains("Dictations: 42 in all"))
        #expect(lines.contains("Kept without edits: 30 of 36 checked"))
        #expect(lines.contains("Edited after pasting: 6 of 36 checked"))
        #expect(lines.contains("Not checked: 6"))
        #expect(lines.contains("Voice actions: 2 attempted, 1 succeeded, 1 failed, 0 cancelled"))
        #expect(lines.contains("Meetings: 0 started, 1 completed, 0 discarded, 45 minutes recorded"))
        #expect(lines.contains(where: { $0.hasPrefix("Your Mac: ") && $0.contains("macOS 27") }))
    }

    @Test("it states what is never included")
    func statesExclusions() throws {
        let text = MetricsDisclosure.lines(for: try batch()).joined(separator: "\n").lowercased()
        for word in ["transcript", "audio", "app", "window", "file"] { #expect(text.contains(word)) }
        #expect(text.contains("never sent"))
    }

    @Test("timings are shown as ranges with counts, and there is no empty dictation section")
    func timingsAndEmpty() throws {
        let lines = MetricsDisclosure.lines(for: try batch())
        #expect(lines.contains(where: { $0.hasPrefix("Time to paste:") && $0.contains("750–999 ms") }))
        let funnelOnly = try #require(F.builder().close(
            records: [F.record(.funnel(.firstDictation))], environment: F.environment, now: F.noonOct5).closedBatches.first)
        let sparse = MetricsDisclosure.lines(for: funnelOnly)
        #expect(!sparse.contains(where: { $0.hasPrefix("Dictations") }))
        #expect(!sparse.contains(where: { $0.hasPrefix("Kept without edits") }))
        #expect(sparse.contains(where: { $0.contains("First dictation") }))
    }

    @Test("rendering is pure: same batch, same lines")
    func pure() throws {
        let value = try batch()
        #expect(MetricsDisclosure.lines(for: value) == MetricsDisclosure.lines(for: value))
    }

    @Test("every histogram bucket has a readable label")
    func bucketLabels() {
        for spec in MetricsHistogramSpec.allCases {
            let labels = (0..<spec.bucketCount).map { MetricsDisclosure.label(for: spec, bucket: $0) }
            #expect(Set(labels).count == spec.bucketCount)
            #expect(labels.allSatisfy { !$0.isEmpty })
        }
        #expect(MetricsDisclosure.label(for: .words, bucket: 0) == "0 words")
        #expect(MetricsDisclosure.label(for: .words, bucket: 2) == "3–5 words")
        #expect(MetricsDisclosure.label(for: .releaseToDeliveryMilliseconds, bucket: 0) == "under 250 ms")
    }
}
