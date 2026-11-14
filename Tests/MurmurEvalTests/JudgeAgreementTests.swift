import Foundation
import Testing

@testable import murmur_eval

@Suite("JudgeAgreementReport")
struct JudgeAgreementTests {
    private func verdict(_ passed: Bool, score: Double = 3.0) -> JudgeVerdict {
        JudgeVerdict(passed: passed, meaningScore: score, reasoning: "r")
    }

    @Test func fullAgreementYieldsRateOneAndNoDisagreements() {
        let entries = [
            JudgeAgreementEntry(caseID: "a", claudeVerdict: verdict(true), codexVerdict: verdict(true)),
            JudgeAgreementEntry(caseID: "b", claudeVerdict: verdict(false), codexVerdict: verdict(false)),
        ]
        let report = JudgeAgreementReport.compute(entries)
        #expect(report.agreementRate == 1.0)
        #expect(report.disagreements.isEmpty)
    }

    @Test func fullDisagreementYieldsRateZero() {
        let entries = [
            JudgeAgreementEntry(caseID: "a", claudeVerdict: verdict(true), codexVerdict: verdict(false)),
            JudgeAgreementEntry(caseID: "b", claudeVerdict: verdict(false), codexVerdict: verdict(true)),
        ]
        let report = JudgeAgreementReport.compute(entries)
        #expect(report.agreementRate == 0.0)
        #expect(report.disagreements.count == 2)
    }

    @Test func partialAgreementComputesCorrectFraction() {
        let entries = [
            JudgeAgreementEntry(caseID: "a", claudeVerdict: verdict(true), codexVerdict: verdict(true)),
            JudgeAgreementEntry(caseID: "b", claudeVerdict: verdict(true), codexVerdict: verdict(false)),
            JudgeAgreementEntry(caseID: "c", claudeVerdict: verdict(false), codexVerdict: verdict(false)),
            JudgeAgreementEntry(caseID: "d", claudeVerdict: verdict(false), codexVerdict: verdict(true)),
        ]
        let report = JudgeAgreementReport.compute(entries)
        #expect(report.agreementRate == 0.5)
        #expect(report.disagreements.map(\.caseID).sorted() == ["b", "d"])
    }

    @Test func emptyEntriesReportsFullAgreementByConvention() {
        let report = JudgeAgreementReport.compute([])
        #expect(report.agreementRate == 1.0)
        #expect(report.disagreements.isEmpty)
    }

    @Test func agreementIgnoresMeaningScoreDifferencesWhenPassFailMatches() {
        // Two backends can differ on the continuous score but still "agree" for this report's
        // purposes, since the report is specifically about the pass/fail signal.
        let entries = [
            JudgeAgreementEntry(caseID: "a", claudeVerdict: verdict(true, score: 3.1), codexVerdict: verdict(true, score: 3.9))
        ]
        let report = JudgeAgreementReport.compute(entries)
        #expect(report.agreementRate == 1.0)
    }
}
