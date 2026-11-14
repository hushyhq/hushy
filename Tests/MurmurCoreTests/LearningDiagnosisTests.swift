import Foundation
import GRDB
import Testing
@testable import MurmurCore

/// Why an edit taught nothing, as the `learning` log line says it. Every sentence is invented.
@Suite("Learning diagnosis")
struct LearningDiagnosisTests {
    private let dictation = "please send the Veloria report to the whole team before noon today"

    private func drop(_ inserted: String, _ field: String?, _ context: LearningContext = LearningContext()) -> CorrectionDrop? {
        guard case .dropped(let drop) = CorrectionCapture.explain(
            inserted: inserted, raw: inserted, fieldValue: field, context: context, dictationID: 1) else { return nil }
        return drop
    }

    private func looks(_ values: String?...) -> [FieldSnapshot] {
        values.enumerated().map { FieldSnapshot(value: $1, elapsed: Double($0 + 1) * 2) }
    }

    // MARK: Why one look taught nothing

    @Test("each rule that drops a change names itself, with the number it judged by")
    func dropReasons() {
        #expect(drop(dictation, nil) == .unreadable)
        #expect(drop(dictation, "Note: " + dictation + " Thanks") == .unchanged)
        #expect(drop(dictation, "  \n") == .cleared)
        #expect(drop(dictation, "the crates are packed and the cart leaves at dawn") == .notLocated)
        #expect(drop("Tarrow Rij", "Tavren Ridge") == .tooFewWords(2))
        #expect(drop(dictation, dictation, LearningContext(isCodeContext: true)) == .refused(.codeContext))
        #expect(drop(dictation, dictation, LearningContext(elapsed: 90)) == .refused(.tooLate))
        // Seven words added to twelve: more than the 40% a correction may change.
        let longer = dictation.replacingOccurrences(of: "report", with: "report and the two long overdue Nerula summaries")
        #expect(drop(dictation, longer) == .shareChanged(percent: 58))
        // Five separate one-word changes in sixteen words: under 40%, over four runs.
        let sixteen = "we will pack the crates then load the cart then check the list then leave early"
        let fiveRuns = "we shall pack the boxes then load the wagon then check the sheet then leave late"
        #expect(drop(sixteen, fiveRuns) == .editRuns(5))
        // One ordinary word for another is a rewrite, which is never learned.
        #expect(drop(dictation, dictation.replacingOccurrences(of: "today", with: "tomorrow")) == .rewrite(changes: 1))
    }

    @Test("explaining changes nothing about what is learned: derive is explain's capture")
    func explainMatchesDerive() {
        let fixed = "please call Priya about the Veloria report today"
        let inserted = "please call Pria about the Veloria report today"
        let context = LearningContext()
        let derived = CorrectionCapture.derive(inserted: inserted, raw: inserted, fieldValue: fixed, context: context,
                                               dictationID: 7, now: Date(timeIntervalSince1970: 0))
        let explained = CorrectionCapture.explain(inserted: inserted, raw: inserted, fieldValue: fixed, context: context,
                                                  dictationID: 7, now: Date(timeIntervalSince1970: 0))
        #expect(derived != nil)
        #expect(explained.capture == derived)
        #expect(CorrectionCapture.explain(inserted: inserted, raw: inserted, fieldValue: inserted, context: context,
                                          dictationID: 7).capture == nil)
    }

    // MARK: Why no look taught anything

    @Test("across looks the newest one that saw the dictation changed gives the reason")
    func latestReason() {
        func reason(_ inserted: String, _ snapshots: [FieldSnapshot]) -> CorrectionDrop? {
            guard case .dropped(let drop) = CorrectionCapture.explainLatest(
                inserted: inserted, raw: inserted, snapshots: snapshots, context: LearningContext(), dictationID: 1) else { return nil }
            return drop
        }
        let rewritten = dictation.replacingOccurrences(of: "today", with: "tomorrow")
        #expect(reason(dictation, looks(nil, nil)) == .unreadable)
        #expect(reason(dictation, looks(dictation, nil, dictation)) == .unchanged)
        #expect(reason(dictation, looks(dictation, rewritten, rewritten)) == .rewrite(changes: 1))
        // Sent as it was: no look saw a change, so it is not reported as a cleared field.
        #expect(reason(dictation, looks(dictation, dictation, "")) == .unchanged)
        // A rewrite, then sent: the rewrite is why nothing was learned.
        #expect(reason(dictation, looks(dictation, rewritten, "")) == .rewrite(changes: 1))
        // Only when no look saw the dictation does the empty field or the other text give the reason.
        #expect(reason(dictation, looks("", "")) == .cleared)
        #expect(reason(dictation, looks("", "the crates are packed and the cart leaves at dawn")) == .notLocated)
    }

    @Test("a dictation of one or two words says whether its change was not the learnable shape or not settled")
    func shortReasons() {
        func reason(_ snapshots: [FieldSnapshot], _ context: LearningContext = LearningContext()) -> CorrectionDrop? {
            guard case .dropped(let drop) = CorrectionCapture.explainLatest(
                inserted: "ask Velorya", raw: "ask Velorya", snapshots: snapshots, context: context, dictationID: 1,
                isCommonWord: { $0 == "ask" }) else { return nil }
            return drop
        }
        #expect(reason(looks(nil)) == .unreadable)
        #expect(reason(looks("ask Velorya", "ask Velorya")) == .unchanged)
        // Both words replaced: not one word for one word.
        #expect(reason(looks("ask Velorya", "tell Veloria", "tell Veloria")) == .shortNoFix(words: 2))
        // The fix on a single look may be half typed.
        #expect(reason(looks("ask Velorya", "ask Velorya", "ask Veloria")) == .shortNotSettled(words: 2))
        #expect(reason(looks("ask Velorya", "ask Veloria"), LearningContext(isEnabled: false)) == .refused(.disabled))
    }

    // MARK: What recording did

    private func capture(_ before: String, _ after: String, dictation id: Int64, at date: Date = Date()) -> CorrectionCapture {
        CorrectionCapture(dictationID: id, appBundleID: "app.quillpad.mail", capturedAt: date,
                          events: [CorrectionEvent(kind: .asrTerm, before: before, after: after)])
    }

    @Test("recording says how far a candidate is toward use, when it comes into use, and why nothing was written")
    func recordReport() throws {
        let store = try Store()
        let first = try store.reportCorrections(capture("Velorya", "Veloria", dictation: 1), policy: .standard)
        #expect(first.written == 1)
        #expect(first.activated.isEmpty)
        #expect(first.progress == CorrectionRecord.Progress(seen: 1, needed: 2))
        #expect(first.skip == nil)
        // The same dictation again is not a second edit.
        #expect(try store.reportCorrections(capture("Velorya", "Veloria", dictation: 1), policy: .standard).progress?.seen == 1)
        let second = try store.reportCorrections(capture("Velorya", "Veloria", dictation: 2), policy: .standard)
        #expect(second.activated.map(\.value) == ["Veloria"])
        #expect(second.progress == nil)
        let third = try store.reportCorrections(capture("Velorya", "Veloria", dictation: 3), policy: .standard)
        #expect(third.written == 1 && third.activated.isEmpty && third.progress == nil && third.skip == nil)
        // What the existing call returns is unchanged: the items that came into use.
        #expect(try store.recordCorrections(capture("Nerulla", "Nerula", dictation: 4), policy: .standard).isEmpty)

        let id = try #require(try store.learnedItems().first { $0.value == "Veloria" }?.id)
        try store.forgetLearnedItem(id: id)
        #expect(try store.reportCorrections(capture("Velorya", "Veloria", dictation: 5), policy: .standard).skip == .forgotten)
        let empty = CorrectionCapture(dictationID: 6, appBundleID: nil, capturedAt: Date(), events: [])
        #expect(try store.reportCorrections(empty, policy: .standard).skip == .nothing)
        // The dictation the capture names is gone.
        #expect(try store.reportCorrections(capture("Savarra", "Savara", dictation: 99), policy: .standard,
                                            expectedInsertedText: "ask Savarra").skip == .stale)
    }

    @Test("a word the person's own Dictionary already holds with that hearing is not recorded")
    func knownWord() throws {
        let store = try Store()
        _ = try store.save(DictionaryEntry(term: "Veloria", soundsLike: ["Velorya"]))
        #expect(try store.reportCorrections(capture("Velorya", "Veloria", dictation: 1), policy: .standard).skip == .known)
    }

    // MARK: The line

    private func line(_ outcome: LearningDiagnosis.Outcome, verdict: String? = "edited", coverage: String? = "observed",
                      looks: Int = 10, readable: Int = 10, pairs: Int? = nil) -> String {
        var diagnosis = LearningDiagnosis(bundleID: "com.brave.Browser", outcome: outcome)
        diagnosis.verdict = verdict
        diagnosis.coverage = coverage
        diagnosis.looks = looks
        diagnosis.readable = readable
        diagnosis.pairs = pairs
        return diagnosis.line
    }

    @Test("every outcome is one line of fixed words and numbers")
    func lines() {
        let tail = " verdict=edited coverage=observed looks=10 readable=10"
        #expect(line(.notWatched(.notInserted)) == "learning app=com.brave.Browser result=not-watched why=not-inserted verdict=edited coverage=observed")
        #expect(LearningDiagnosis(bundleID: "com.brave.Browser", outcome: .notWatched(.spokenReturn)).line
            == "learning app=com.brave.Browser result=not-watched why=spoken-return")
        #expect(LearningDiagnosis(bundleID: nil, outcome: .notWatched(.notSaved)).line == "learning app=none result=not-watched why=not-saved")
        #expect(line(.refused(.excludedApp), verdict: "kept", looks: 1, readable: 1)
            == "learning app=com.brave.Browser result=refused why=excluded-app verdict=kept coverage=observed looks=1 readable=1")
        #expect(line(.unreadable(atLook: nil), verdict: "unknown", coverage: "fieldUnreadable", looks: 0, readable: 0)
            == "learning app=com.brave.Browser result=unreadable at=start verdict=unknown coverage=fieldUnreadable looks=0 readable=0")
        #expect(line(.unreadable(atLook: 1), verdict: "unknown", coverage: "fieldUnreadable", readable: 0)
            == "learning app=com.brave.Browser result=unreadable at=look-1 verdict=unknown coverage=fieldUnreadable looks=10 readable=0")
        #expect(line(.noChange, verdict: "kept") == "learning app=com.brave.Browser result=no-change verdict=kept coverage=observed looks=10 readable=10")
        #expect(line(.dropped(.tooFewWords(2))) == "learning app=com.brave.Browser result=dropped why=few-words words=2 min=3" + tail)
        #expect(line(.dropped(.shareChanged(percent: 58))) == "learning app=com.brave.Browser result=dropped why=share-changed share=58 limit=40" + tail)
        #expect(line(.dropped(.editRuns(5))) == "learning app=com.brave.Browser result=dropped why=edit-runs runs=5 limit=4" + tail)
        #expect(line(.dropped(.rewrite(changes: 1))) == "learning app=com.brave.Browser result=dropped why=rewrite changes=1" + tail)
        #expect(line(.dropped(.notLocated)) == "learning app=com.brave.Browser result=dropped why=not-located" + tail)
        #expect(line(.dropped(.cleared)) == "learning app=com.brave.Browser result=dropped why=field-cleared" + tail)
        #expect(line(.dropped(.shortNoFix(words: 1))) == "learning app=com.brave.Browser result=dropped why=short-no-fix words=1" + tail)
        #expect(line(.dropped(.shortNotSettled(words: 1))) == "learning app=com.brave.Browser result=dropped why=short-not-settled words=1 min-looks=2" + tail)
        #expect(line(.candidate(items: 1, seen: 1, needed: 2)) == "learning app=com.brave.Browser result=candidate items=1 progress=1/2" + tail)
        #expect(line(.learned(items: 1), pairs: 2) == "learning app=com.brave.Browser result=learned items=1" + tail + " pairs=2")
        #expect(line(.alreadyLearned(items: 1)) == "learning app=com.brave.Browser result=already-learned items=1" + tail)
        #expect(line(.notRecorded(.forgotten)) == "learning app=com.brave.Browser result=not-recorded why=forgotten" + tail)
        #expect(line(.notLearning(.switchedOff)) == "learning app=com.brave.Browser result=not-learning why=switched-off" + tail)
        #expect(line(.stopped(.superseded), verdict: nil, coverage: nil, looks: 2, readable: 2)
            == "learning app=com.brave.Browser result=stopped why=superseded looks=2 readable=2")
        #expect(line(.failed) == "learning app=com.brave.Browser result=failed" + tail)
        for refusal in [LearningRefusal.disabled, .excludedApp, .secureField, .denylistedApp, .codeContext, .nonEnglish, .tooLate] {
            #expect(line(.refused(refusal)).contains("result=refused why=\(LearningDiagnosis.token(refusal)) "))
        }
    }

    @Test("nothing free-form reaches the line: an app name or a verdict that is not an identifier is cut down")
    func nothingFreeForm() {
        var diagnosis = LearningDiagnosis(bundleID: "app.quillpad mail\n\"secret words\"", outcome: .noChange)
        diagnosis.verdict = "kept the secret"
        diagnosis.coverage = "obs erved!"
        #expect(diagnosis.line == "learning app=app.quillpadmailsecretwords result=no-change verdict=keptthesecret coverage=observed looks=0 readable=0")
    }
}
