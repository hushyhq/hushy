import Testing
@testable import MurmurCore

@Suite("Extraction outcome categories")
struct ExtractionOutcomeTests {
    @Test("each way an extraction ends has one fixed category, a log line and a usage event")
    func categories() {
        #expect(ExtractionOutcome(.notAnAction) == .notAnAction)
        #expect(ExtractionOutcome(.rejected("timeout")) == .rejectedBudget)
        #expect(ExtractionOutcome(.rejected("skipped: breaker-open")) == .rejectedBreaker)
        #expect(ExtractionOutcome(.rejected("skipped: skipped-slow")) == .rejectedBreaker)
        #expect(ExtractionOutcome(.rejected("model error")) == .modelError)
        #expect(ExtractionOutcome(.actions([])) == .acted)
        #expect(ExtractionOutcome(.modelUnavailable) == nil)
        #expect(ExtractionOutcome.acted.metric == nil, "acting is counted when the action runs")
        #expect(ExtractionOutcome.notAnAction.metric == VoiceActionMetricEvent(outcome: .failed, failure: .other))
        #expect(ExtractionOutcome.rejectedBudget.metric == VoiceActionMetricEvent(outcome: .failed, failure: .timedOut))
        #expect(ExtractionOutcome.rejectedBreaker.metric == VoiceActionMetricEvent(outcome: .failed, failure: .timedOut))
        #expect(ExtractionOutcome.modelError.metric == VoiceActionMetricEvent(outcome: .failed, failure: .backendFailed))
    }

    @Test("the log line is the category word and nothing else")
    func logLine() {
        for outcome in ExtractionOutcome.allCases {
            #expect(outcome.logLine == "action extraction: \(outcome.rawValue)")
        }
    }
}
