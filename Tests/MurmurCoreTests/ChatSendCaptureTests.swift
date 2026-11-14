import Foundation
import Testing
@testable import MurmurCore

/// A chat box empties when its message is sent. A read taken when the field reports a change (`FieldRead.onChange`)
/// sees the text as it stood the moment before, and that text is the person's finished fix, not a word half typed.
@Suite("Learning · the text a chat box held before it sent")
struct ChatSendCaptureTests {
    private let pasted = "I spoke with Karthick and the release notes are nearly finished."

    private func typed(_ name: String) -> String { pasted.replacingOccurrences(of: "Karthick", with: name) }

    private func change(_ value: String?, _ elapsed: TimeInterval) -> FieldRead {
        FieldRead(value: value, security: .notSecure, elapsed: elapsed, onChange: true)
    }

    private func look(_ value: String?, _ elapsed: TimeInterval, onReturn: Bool = false) -> FieldRead {
        FieldRead(value: value, security: .notSecure, elapsed: elapsed, onReturn: onReturn)
    }

    private func lesson(_ reads: [FieldRead]) -> CorrectionDerivation {
        CorrectionCapture.explainLatest(
            inserted: pasted, raw: pasted, snapshots: LearningReads.resolve(reads).snapshots,
            context: LearningContext(), dictationID: 1, isCommonWord: isTestCommon)
    }

    @Test("the change read before the field emptied is the last text before the clear")
    func marksTheTextBeforeTheClear() {
        let reads = [look(pasted, 0.5), change(typed("Kar"), 9.1), change(typed("Karthik"), 9.4), change("", 9.6), look("", 12)]
        #expect(LearningReads.lastBeforeClear(reads) == [2])
        #expect(LearningReads.resolve(reads).snapshots.map(\.lastBeforeClear) == [false, false, true, false, false])
    }

    @Test("a scheduled look between the change read and the clear holding the same text is the one marked")
    func sameTextOnALaterLook() {
        let reads = [change(typed("Karthik"), 9.4), look(typed("Karthik"), 9.5), change("", 9.6)]
        #expect(LearningReads.lastBeforeClear(reads) == [1])
    }

    @Test("a scheduled look that caught a word half typed is not marked: no change read saw that text")
    func halfTypedOnTheScheduleIsNotMarked() {
        // The field reported the clear but the last keystrokes' reports were missed: what the look saw is not final.
        let reads = [change(typed("Ka"), 2.9), look(typed("Kar"), 3.0), change("", 3.3)]
        #expect(LearningReads.lastBeforeClear(reads).isEmpty)
    }

    @Test("only a change read that saw the field empty marks anything")
    func onlyAChangeReadOfTheClear() {
        #expect(LearningReads.lastBeforeClear([change(typed("Karthik"), 9.4), look("", 9.6, onReturn: true), look("", 12)]).isEmpty)
        #expect(LearningReads.lastBeforeClear([change(typed("Karthik"), 9.4)]).isEmpty, "never emptied: nothing was sent")
        #expect(LearningReads.lastBeforeClear([change("", 0.2)]).isEmpty, "nothing stood before it")
    }

    @Test("a scheduled look that already found the box empty, before the clear's report, does not break the link")
    func emptyLookBeforeTheReport() {
        let reads = [look(typed("Karthi"), 2.5), change(typed("Karthik"), 2.72), look("", 3.0), change("", 3.02)]
        #expect(LearningReads.lastBeforeClear(reads) == [1])
        #expect(lesson(reads).capture?.events.map(\.after) == ["Karthik"])
    }

    @Test("an unreadable look between the text and the clear does not break the run")
    func unreadableLookInBetween() {
        let reads = [change(typed("Karthik"), 9.4), look(nil, 9.5), change("", 9.6)]
        #expect(LearningReads.lastBeforeClear(reads) == [0])
    }

    @Test("a name typed letter by letter and sent at once is learned from the change read before the clear")
    func typedAndSentAtOnce() {
        let reads = [look(pasted, 6), change(typed("K"), 9.0), change(typed("Ka"), 9.1), change(typed("Kar"), 9.2),
                     change(typed("Kart"), 9.3), change(typed("Karth"), 9.4), change(typed("Karthi"), 9.5),
                     change(typed("Karthik"), 9.6), change("", 9.8), look("", 12)]
        #expect(lesson(reads).capture?.events.map(\.after) == ["Karthik"])
    }

    @Test("the same keystrokes on scheduled looks, with the last one missed, are still held back as half typed")
    func halfTypedGuardStays() {
        let reads = [look(pasted, 1), look(typed("Kar"), 2), look(typed("Karthi"), 3), look("", 4)]
        #expect(lesson(reads) == .dropped(.notSettled))
    }

    @Test("a message sent as it was pasted says unchanged, change reads or not")
    func sentAsPasted() {
        #expect(lesson([look(pasted, 0.5), change(pasted, 0.6), change("", 3.1), look("", 8)]) == .dropped(.unchanged))
    }

    @Test("a dictation reworded before it is sent is still a rewrite, not a term")
    func rewordedStaysARewrite() {
        let reworded = "Karthick says the notes for the release are close to done, more soon."
        #expect(lesson([look(pasted, 0.5), change(reworded, 9.2), change("", 9.4)]).capture == nil)
    }

    @Test("the learning line counts change reads and the look before the clear, and leaves both off when there were none")
    func diagnosisLine() {
        var diagnosis = LearningDiagnosis(bundleID: "com.anthropic.claudefordesktop", outcome: .noChange)
        diagnosis.looks = 21
        diagnosis.readable = 21
        #expect(!diagnosis.line.contains("on-change"))
        diagnosis.changeLooks = 2
        diagnosis.beforeClear = 1
        #expect(diagnosis.line.hasSuffix("looks=21 readable=21 on-change=2 before-clear=1"))
    }
}
