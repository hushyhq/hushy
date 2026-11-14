import Foundation
import Testing
@testable import MurmurCore

@Suite("Onboarding funnel")
struct OnboardingFunnelTests {
    private let t0 = Date(timeIntervalSince1970: 1_700_000_000)

    @Test("records events in order and derives time to first dictation")
    func timeToFirstDictation() {
        let funnel = OnboardingFunnel.empty
            .marking(.onboardingStarted, at: t0)
            .marking(.microphoneGranted, at: t0.addingTimeInterval(8))
            .marking(.accessibilityGranted, at: t0.addingTimeInterval(20))
            .marking(.modelReady, at: t0.addingTimeInterval(45))
            .marking(.firstDictation, at: t0.addingTimeInterval(62.5))

        #expect(funnel.timeToFirstDictation == 62.5)
        #expect(funnel.secondsToEvent(.modelReady) == 45)
        #expect(funnel.secondsToEvent(.onboardingCompleted) == nil)
    }

    @Test("the first occurrence of an event wins")
    func firstOccurrenceWins() {
        let funnel = OnboardingFunnel.empty
            .marking(.onboardingStarted, at: t0)
            .marking(.firstDictation, at: t0.addingTimeInterval(30))
            .marking(.firstDictation, at: t0.addingTimeInterval(300))
        #expect(funnel.timeToFirstDictation == 30)
    }

    @Test("events before onboarding starts are ignored")
    func ignoresEventsBeforeStart() {
        let funnel = OnboardingFunnel.empty.marking(.microphoneGranted, at: t0)
        #expect(funnel[.microphoneGranted] == nil)
        #expect(!funnel.hasStarted)
        let started = funnel.marking(.onboardingStarted, at: t0.addingTimeInterval(1))
            .marking(.microphoneGranted, at: t0.addingTimeInterval(4))
        #expect(started.secondsToEvent(.microphoneGranted) == 3)
    }

    @Test("marking never mutates the original")
    func isImmutable() {
        let original = OnboardingFunnel.empty.marking(.onboardingStarted, at: t0)
        _ = original.marking(.modelReady, at: t0.addingTimeInterval(5))
        #expect(original[.modelReady] == nil)
    }

    @Test("rows list every event in funnel order with offsets")
    func rows() {
        let funnel = OnboardingFunnel.empty
            .marking(.onboardingStarted, at: t0)
            .marking(.modelReady, at: t0.addingTimeInterval(12))
        let rows = funnel.rows
        #expect(rows.map(\.event) == OnboardingFunnel.Event.allCases)
        #expect(rows[0].offsetSeconds == 0)
        #expect(rows.first { $0.event == .modelReady }?.offsetSeconds == 12)
        #expect(rows.first { $0.event == .firstDictation }?.timestamp == nil)
    }

    @Test("round-trips through JSON")
    func codable() throws {
        let funnel = OnboardingFunnel.empty
            .marking(.onboardingStarted, at: t0)
            .marking(.firstDictation, at: t0.addingTimeInterval(70))
        let data = try JSONEncoder().encode(funnel)
        let decoded = try JSONDecoder().decode(OnboardingFunnel.self, from: data)
        #expect(decoded == funnel)
    }

    @Test("formats seconds compactly")
    func formatting() {
        #expect(OnboardingFunnel.formatSeconds(12.34) == "12.3 s")
        #expect(OnboardingFunnel.formatSeconds(65) == "1 min 5 s")
    }

    @Test("download events, speed bucket, pace and optional steps are recorded once, after start")
    func downloadFields() {
        let before = OnboardingFunnel.empty.recordingSpeed(.slow).recordingOptionalStep(.dictionary, skipped: true)
        #expect(before.speedBucket == nil)
        #expect(before.optionalStepsShown.isEmpty)

        let funnel = OnboardingFunnel.empty
            .marking(.onboardingStarted, at: t0)
            .marking(.speechDownloadStarted, at: t0.addingTimeInterval(1))
            .recordingSpeed(.slow)
            .recordingSpeed(.fast)
            .recordingPace(.slow)
            .recordingPace(.onTime)
            .recordingOptionalStep(.micCheck, skipped: false)
            .recordingOptionalStep(.dictionary, skipped: true)
            .recordingOptionalStep(.dictionary, skipped: true)
            .recordingOptionalStep(.tryIt, skipped: true)
            .marking(.speechDownloadFinished, at: t0.addingTimeInterval(95))
        #expect(funnel.speedBucket == .slow)
        #expect(funnel.pace == .slow)
        #expect(funnel.optionalStepsShown == [.micCheck, .dictionary])
        #expect(funnel.optionalStepsSkipped == [.dictionary])
        #expect(funnel.secondsToEvent(.speechDownloadFinished) == 95)
    }

    @Test("a funnel saved before the download fields existed still decodes")
    func legacyDecoding() throws {
        let legacy = try JSONEncoder().encode(OnboardingFunnel.empty.marking(.onboardingStarted, at: t0))
        var object = try #require(try JSONSerialization.jsonObject(with: legacy) as? [String: Any])
        object = object.filter { $0.key == "timestamps" }
        let decoded = try JSONDecoder().decode(OnboardingFunnel.self, from: try JSONSerialization.data(withJSONObject: object))
        #expect(decoded.hasStarted)
        #expect(decoded.optionalStepsShown.isEmpty)
        #expect(decoded.speedBucket == nil)

        let full = OnboardingFunnel.empty.marking(.onboardingStarted, at: t0).recordingSpeed(.moderate)
            .recordingOptionalStep(.privacy, skipped: true).recordingPace(.verySlow)
        #expect(try JSONDecoder().decode(OnboardingFunnel.self, from: JSONEncoder().encode(full)) == full)
    }
}
