import Foundation
import Testing
@testable import MurmurCore

@Suite("Evidence-supported edit learning")
struct TermEvidenceTests {
    @Test func supportedCapitalizedFixActivatesOnce() throws {
        let evidence = TermEvidence(dictionary: [], screenTerms: ["Codex"], appNames: [])
        let capture = try #require(CorrectionCapture.deriveLatest(inserted: "please ask codec for help", raw: "please ask codec for help",
            snapshots: [.init(value: "please ask Codex for help", elapsed: 4), .init(value: "please ask Codex for help", elapsed: 8)],
            context: LearningContext(appBundleID: "app.test"), dictationID: 1, evidence: evidence))
        let item = try #require(Learner.observe(capture, existing: [], knownTerms: []).first)
        #expect(item.status == .active)
        #expect(item.value == "Codex")
    }

    @Test func transientSupportedFixDoesNotActivate() throws {
        let capture = try #require(CorrectionCapture.deriveLatest(inserted: "please ask codec for help", raw: "please ask codec for help",
            snapshots: [.init(value: "please ask Codex for help", elapsed: 4), .init(value: "please ask Code for help", elapsed: 8)],
            context: LearningContext(appBundleID: "app.test"), dictationID: 1,
            evidence: TermEvidence(dictionary: [], screenTerms: ["Codex", "Code"], appNames: [])))
        #expect(capture.supportedKeys.isEmpty)
        #expect(Learner.observe(capture, existing: [], knownTerms: []).first?.status == .candidate)
    }

    @Test func supportedSpellingElsewhereDoesNotGrantShortcut() throws {
        let value = "Codex is ready. please ask Codex for help"
        let capture = try #require(CorrectionCapture.deriveLatest(inserted: "please ask codec for help", raw: "please ask codec for help",
            snapshots: [.init(value: value, elapsed: 4), .init(value: value, elapsed: 8)],
            context: LearningContext(appBundleID: "app.test"), dictationID: 1,
            evidence: TermEvidence(dictionary: [], screenTerms: ["Codex"], appNames: [])))
        #expect(capture.supportedKeys.isEmpty)
        #expect(Learner.observe(capture, existing: [], knownTerms: []).first?.status == .candidate)
    }

    @Test func dictionaryEvidenceSupportsOneFix() throws {
        let evidence = TermEvidence(dictionary: [DictionaryEntry(term: "Codex")], screenTerms: [], appNames: [])
        let capture = try #require(CorrectionCapture.derive(inserted: "please ask codec for help", raw: "please ask codec for help", fieldValue: "please ask Codex for help", context: LearningContext(appBundleID: "app.test"), dictationID: 1, evidence: evidence))
        #expect(Learner.observe(capture, existing: [], knownTerms: ["codex"]).first?.status == .active)
    }

    @Test func dictionarySupportsCaseOnlyTermFix() throws {
        try assertCaseOnlyFix(TermEvidence(dictionary: [DictionaryEntry(term: "Notion")], screenTerms: [], appNames: []))
    }

    @Test func screenSupportsCaseOnlyTermFix() throws {
        try assertCaseOnlyFix(TermEvidence(dictionary: [], screenTerms: ["Notion"], appNames: []))
    }

    @Test func unsupportedCapitalizationTeachesNothing() {
        #expect(CorrectionCapture.deriveLatest(inserted: "please open notion for me", raw: "please open notion for me",
                                               snapshots: [FieldSnapshot(value: "please open Notion for me", elapsed: 8)],
                                               context: LearningContext(appBundleID: "app.test"), dictationID: 1) == nil)
    }

    private func assertCaseOnlyFix(_ evidence: TermEvidence) throws {
        let capture = try #require(CorrectionCapture.deriveLatest(inserted: "please open notion for me", raw: "please open notion for me",
                                                                 snapshots: [FieldSnapshot(value: "please open Notion for me", elapsed: 8)],
                                                                 context: LearningContext(appBundleID: "app.test"), dictationID: 1, evidence: evidence))
        #expect(capture.events == [CorrectionEvent(kind: .asrTerm, before: "notion", after: "Notion")])
        let item = try #require(Learner.observe(capture, existing: [], knownTerms: []).first)
        #expect(item.value == "Notion")
        #expect(item.status == .candidate)
        #expect(item.appBundleID == "app.test")
    }

    @Test func contentDeletionIsNotAStyleHabit() {
        #expect(CorrectionCapture.derive(inserted: "the bright green build is ready", raw: "the bright green build is ready", fieldValue: "the green build is ready", context: LearningContext(appBundleID: "app.test"), dictationID: 1) == nil)
    }

    @Test func signOffAndLowercaseAreNarrowFormattingSignals() {
        #expect(CorrectionClassifier.formattingSignal(before: "Thanks!", after: "Thanks,") == .signOffComma)
        #expect(CorrectionClassifier.formattingSignal(before: "Ready!", after: "Ready.") == .noExclamation)
        #expect(CorrectionClassifier.formattingSignal(before: "Ready.", after: "ready.") == .lowercased)
        #expect(CorrectionClassifier.formattingSignal(before: "great!", after: "fine.") == nil)
    }

    @Test func unsupportedStillNeedsTwo() throws {
        let capture = try #require(CorrectionCapture.deriveLatest(inserted: "please ask Pria for help", raw: "please ask Pria for help", snapshots: [FieldSnapshot(value: "please ask Priya for help", elapsed: 8)], context: LearningContext(appBundleID: "app.test"), dictationID: 1))
        let first = Learner.observe(capture, existing: [], knownTerms: [])
        #expect(first.first?.status == .candidate)
        let second = CorrectionCapture(dictationID: 2, appBundleID: capture.appBundleID,
                                       capturedAt: capture.capturedAt, events: capture.events)
        #expect(Learner.observe(second, existing: first, knownTerms: []).first?.status == .active)
    }

    @Test func ordinaryLowercaseAndRewriteTeachNothing() {
        let evidence = TermEvidence(dictionary: [], screenTerms: ["text", "previous"], appNames: [])
        for typed in ["text", "previous"] {
            #expect(CorrectionCapture.derive(inserted: "please paste the Next here", raw: "please paste the Next here", fieldValue: "please paste the \(typed) here", context: LearningContext(appBundleID: "app.test"), dictationID: 1, evidence: evidence) == nil)
        }
    }

    @Test func greetingAndExclamationBecomePerAppHabits() throws {
        var items: [LearnedItem] = []
        for id in 1...3 {
            let capture = try #require(CorrectionCapture.derive(inserted: "Hi Sam, the build is green!", raw: "Hi Sam, the build is green!", fieldValue: "the build is green.", context: LearningContext(appBundleID: "app.test"), dictationID: Int64(id)))
            let changed = Learner.observe(capture, existing: items, knownTerms: [])
            items = changed
        }
        #expect(items.filter { $0.isReadySuggestion }.count == 2)
        #expect(PreferenceHints.from(items, bundleID: "app.test").isEmpty)
        items = items.map { Learner.confirm($0) }
        #expect(PreferenceHints.from(items, bundleID: "app.test").promptLine?.contains("greeting") == true)
        #expect(PreferenceHints.from(items, bundleID: "app.other").promptLine == nil)
    }
}
