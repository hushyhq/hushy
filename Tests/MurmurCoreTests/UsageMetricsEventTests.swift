import Foundation
import Testing
@testable import MurmurCore

@Suite("Usage metrics: content-free event facts")
struct UsageMetricsEventTests {
    @Test("built-in modes map to their kind; custom and absent modes never carry a name")
    func modeKinds() {
        #expect(MetricsModeKind.kind(modeID: nil, isBuiltIn: false) == .none)
        #expect(MetricsModeKind.kind(modeID: Mode.BuiltInID.default, isBuiltIn: true) == .standard)
        #expect(MetricsModeKind.kind(modeID: Mode.BuiltInID.email, isBuiltIn: true) == .email)
        #expect(MetricsModeKind.kind(modeID: Mode.BuiltInID.message, isBuiltIn: true) == .message)
        #expect(MetricsModeKind.kind(modeID: Mode.BuiltInID.note, isBuiltIn: true) == .note)
        #expect(MetricsModeKind.kind(modeID: Mode.BuiltInID.bulletPoints, isBuiltIn: true) == .bulletPoints)
        #expect(MetricsModeKind.kind(modeID: UUID(), isBuiltIn: false) == .custom)
        // A user-made mode that reuses a built-in ID but is not flagged built-in is still custom.
        #expect(MetricsModeKind.kind(modeID: Mode.BuiltInID.email, isBuiltIn: false) == .custom)
    }

    @Test("every built-in mode is representable")
    func everyBuiltInIsCovered() {
        let kinds = Mode.builtIns(userName: "Someone").map { MetricsModeKind.kind(modeID: $0.id, isBuiltIn: $0.isBuiltIn) }
        #expect(!kinds.contains(.custom) && !kinds.contains(.none))
        #expect(Set(kinds).count == kinds.count)
    }

    @Test("every onboarding funnel event has a funnel step")
    func funnelMirrorsOnboarding() {
        let mapped = OnboardingFunnel.Event.allCases.map { FunnelStep($0).rawValue }
        #expect(mapped == OnboardingFunnel.Event.allCases.map(\.rawValue))
        #expect(FunnelStep.allCases.count == OnboardingFunnel.Event.allCases.count)
    }

    @Test("voice-action failure category only survives on a failed action")
    func voiceActionNormalisation() {
        #expect(VoiceActionMetricEvent(outcome: .succeeded, failure: .notFound).failure == nil)
        #expect(VoiceActionMetricEvent(outcome: .cancelled, failure: .timedOut).failure == nil)
        #expect(VoiceActionMetricEvent(outcome: .failed, failure: nil).failure == .other)
        #expect(VoiceActionMetricEvent(outcome: .failed, failure: .permissionDenied).failure == .permissionDenied)
    }

    @Test("action execution errors map to fixed categories without carrying their text")
    func executionErrorMapping() {
        #expect(VoiceActionFailureCategory(.permissionDenied("Calendar")) == .permissionDenied)
        #expect(VoiceActionFailureCategory(.notFound("secret name")) == .notFound)
        #expect(VoiceActionFailureCategory(.closestApps(heard: "x", apps: ["Y"])) == .ambiguousTarget)
        #expect(VoiceActionFailureCategory(.backendFailed("boom")) == .backendFailed)
        #expect(VoiceActionFailureCategory(.needsInput("when?")) == .needsInput)
    }

    @Test("meeting minutes exist only once a meeting has ended and are bounded")
    func meetingNormalisation() {
        #expect(MeetingMetricEvent(outcome: .started, minutesRecorded: 30).minutesRecorded == nil)
        #expect(MeetingMetricEvent(outcome: .completed, minutesRecorded: -4).minutesRecorded == 0)
        #expect(MeetingMetricEvent(outcome: .completed, minutesRecorded: 99_999).minutesRecorded == MetricsLimits.maximumMeetingMinutes)
        #expect(MeetingMetricEvent(outcome: .discarded, minutesRecorded: 12).minutesRecorded == 12)
    }

    @Test("dictation numbers are clamped, never negative")
    func dictationClamping() {
        let event = UsageMetricsFixtures.dictation(words: -5, audioMs: -1, speechMs: -9, cleanupMs: 99_999_999)
        #expect(event.wordCount == 0)
        #expect(event.audioMilliseconds == 0)
        #expect(event.speechMilliseconds == 0)
        #expect(event.cleanupMilliseconds == MetricsHistogramSpec.cleanupMilliseconds.maximumValue)
    }

    @Test("environment is classified from coarse inputs only")
    func environmentClassification() throws {
        let gib: UInt64 = 1 << 30
        let m3 = try MetricsEnvironment.classify(chipBrand: "Apple M3 Pro", physicalMemoryBytes: 18 * gib, macOSMajor: 27)
        #expect(m3.chipClass == .appleM3)
        #expect(m3.memoryBand == .upTo32GB)
        #expect(try MetricsEnvironment.classify(chipBrand: "Apple M1", physicalMemoryBytes: 8 * gib, macOSMajor: 14).memoryBand == .upTo8GB)
        #expect(try MetricsEnvironment.classify(chipBrand: "Apple M5 Max", physicalMemoryBytes: 128 * gib, macOSMajor: 27).chipClass == .appleM4OrLater)
        #expect(try MetricsEnvironment.classify(chipBrand: "Apple M5 Max", physicalMemoryBytes: 128 * gib, macOSMajor: 27).memoryBand == .over64GB)
        #expect(try MetricsEnvironment.classify(chipBrand: "Intel(R) Core(TM) i9", physicalMemoryBytes: 16 * gib, macOSMajor: 13).chipClass == .intel)
        #expect(try MetricsEnvironment.classify(chipBrand: "something odd", physicalMemoryBytes: 0, macOSMajor: 15).chipClass == .unknown)
        #expect(try MetricsEnvironment.classify(chipBrand: "Apple M2", physicalMemoryBytes: 0, macOSMajor: 15).memoryBand == .unknown)
        #expect(throws: MetricsValidationError.invalidEnvironment) {
            try MetricsEnvironment.classify(chipBrand: "Apple M2", physicalMemoryBytes: gib, macOSMajor: 7)
        }
    }

    @Test("histogram buckets use exclusive upper edges and an open top bucket")
    func histogramBuckets() {
        let words = MetricsHistogramSpec.words
        #expect(words.bucketIndex(for: 0) == 0)
        #expect(words.bucketIndex(for: 1) == 1)
        #expect(words.bucketIndex(for: 2) == 1)
        #expect(words.bucketIndex(for: 3) == 2)
        #expect(words.bucketIndex(for: 320) == words.bucketCount - 2)
        #expect(words.bucketIndex(for: 321) == words.bucketCount - 1)
        #expect(words.bucketIndex(for: 5_000_000) == words.bucketCount - 1)
        for spec in MetricsHistogramSpec.allCases {
            #expect(spec.upperEdges == spec.upperEdges.sorted())
            #expect(Set(spec.upperEdges).count == spec.upperEdges.count)
            #expect(spec.upperEdges.last.map { $0 < spec.maximumValue } == true)
        }
    }

    @Test("histogram records clamp and keep sum coherent with its buckets")
    func histogramRecording() throws {
        var histogram = MetricsHistogram(spec: .releaseToDeliveryMilliseconds)
        histogram.record(100)
        histogram.record(900)
        histogram.record(-50)
        histogram.record(50_000_000)
        #expect(histogram.sampleCount == 4)
        #expect(histogram.sum == 100 + 900 + 0 + MetricsHistogramSpec.releaseToDeliveryMilliseconds.maximumValue)
        #expect(histogram.isCoherent)
        #expect(throws: MetricsValidationError.inconsistentHistogram) {
            try MetricsHistogram(spec: .words, counts: [1, 0, 0, 0, 0, 0, 0, 0, 0, 0], sum: 500)
        }
        #expect(throws: MetricsValidationError.inconsistentHistogram) {
            try MetricsHistogram(spec: .words, counts: [1, 2], sum: 1)
        }
        #expect(throws: MetricsValidationError.countOutOfRange) {
            try MetricsHistogram(spec: .words, counts: [-1, 0, 0, 0, 0, 0, 0, 0, 0, 0], sum: 0)
        }
    }
}
