import Foundation
import Testing
@testable import MurmurCore

@Suite("Usage metrics: dictation facts to event")
struct DictationMetricInputTests {
    private func input(
        _ result: DictationMetricInput.Result = .pasted, outcome: ModelOutcome? = .used,
        backend: EffectiveCleanupBackend = .apple, mode: Mode? = nil, level: CleanupLevel = .clean,
        words: Int = 12, audio: Double = 4.2, speech: Int? = 310, cleanup: Int? = 640, release: Int? = 980
    ) -> DictationMetricInput {
        DictationMetricInput(
            result: result, modelOutcome: outcome, backend: backend, cleanupLevel: level, mode: mode, wordCount: words,
            audioSeconds: audio, speechMilliseconds: speech, cleanupMilliseconds: cleanup, releaseToDeliveryMilliseconds: release)
    }

    @Test("a pasted dictation keeps its timings and has no fallback")
    func pasted() throws {
        let event = try input().event()
        #expect(event.feedback.delivery == .succeeded)
        #expect(event.feedback.cleanupModelProfile == .appleSystem)
        #expect(event.feedback.fallbackReason == nil)
        #expect(event.releaseToDeliveryMilliseconds == 980)
        #expect(event.audioMilliseconds == 4_200)
        #expect(event.speechMilliseconds == 310 && event.cleanupMilliseconds == 640)
        #expect(event.wordCount == 12)
        #expect(event.feedback.editObservation == .unknown && event.feedback.editCoverage == .notAttempted)
    }

    @Test("anything not pasted has no delivery timing; failed stays failed and cancelled stays cancelled")
    func notDelivered() throws {
        for result in [DictationMetricInput.Result.copied, .heldSecure, .noField, .failed] {
            let event = try input(result).event()
            #expect(event.feedback.delivery != .succeeded)
            #expect(event.releaseToDeliveryMilliseconds == nil)
        }
        #expect(try input(.failed).event().feedback.delivery == .failed)
        #expect(try input(.cancelled).event().feedback.delivery == .cancelled)
    }

    @Test("every model outcome maps to a fallback reason or none, and nothing is left unmapped")
    func fallbackMapping() {
        let expected: [ModelOutcome: DictationFeedback.FallbackReason?] = [
            .used: nil, .notAsked: .disabled, .unavailable: .modelUnavailable, .rejectedByGuard: .modelRejected,
            .skippedSlow: .modelTimedOut, .breakerOpen: .modelTimedOut, .timeout: .modelTimedOut,
            .modelBusy: .systemBusy, .thermalSerious: .thermalPressure, .modelError: .other, .refused: .other,
            .releaseWindow: .other, .prewarmLate: .other, .notResponding: .modelTimedOut,
        ]
        #expect(Set(expected.keys) == Set(ModelOutcome.allCases))
        for (outcome, reason) in expected { #expect(DictationMetricInput.fallback(for: outcome) == reason, "\(outcome)") }
        #expect(DictationMetricInput.fallback(for: nil) == nil)
    }

    @Test("the cleanup profile follows the backend, and an unavailable model reads as unavailable")
    func profileMapping() throws {
        #expect(try input(outcome: .notAsked, backend: .rules).event().feedback.cleanupModelProfile == .rules)
        #expect(try input(backend: .apple).event().feedback.cleanupModelProfile == .appleSystem)
        #expect(try input(outcome: .unavailable, backend: .apple).event().feedback.cleanupModelProfile == .unavailable)
        let tuned = ModelRegistry.entries.first { $0.promptProfile == .compact }
        let untuned = ModelRegistry.entries.first { $0.promptProfile == .production }
        if let tuned { #expect(try input(backend: .local(tuned.id)).event().feedback.cleanupModelProfile == .localFineTuned) }
        if let untuned { #expect(try input(backend: .local(untuned.id)).event().feedback.cleanupModelProfile == .localUntuned) }
        #expect(try input(backend: .local("no-such-model")).event().feedback.cleanupModelProfile == .localUntuned)
    }

    @Test("a custom mode is only ever 'custom', never its name; no mode is 'none'")
    func modeKind() throws {
        let custom = Mode(name: "Standup notes for Acme", icon: "star", cleanupLevel: .clean, prompt: "secret words", isBuiltIn: false)
        #expect(try input(mode: custom).event().modeKind == .custom)
        #expect(try input(mode: nil).event().modeKind == MetricsModeKind.none)
    }

    @Test("absurd inputs are clamped, never rejected")
    func clamps() throws {
        let event = try input(words: Int.max, audio: 1e12, speech: Int.max, cleanup: -5, release: Int.max).event()
        #expect(event.wordCount == MetricsHistogramSpec.words.maximumValue)
        #expect(event.audioMilliseconds == MetricsHistogramSpec.audioMilliseconds.maximumValue)
        #expect(event.cleanupMilliseconds == 0)
        #expect(try input(audio: -3).event().audioMilliseconds == 0)
    }
}
