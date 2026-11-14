import Foundation
import Testing
@testable import MurmurCore

/// One- and two-word dictations are located by an earlier read of the same field (the anchor),
/// never by guessing. Every sentence and name here is invented.
private let fixedNow = Date(timeIntervalSince1970: 1_800_000_000)

private func snapshots(_ values: [String?], from first: TimeInterval = 2, step: TimeInterval = 2) -> [FieldSnapshot] {
    values.enumerated().map { FieldSnapshot(value: $1, elapsed: first + Double($0) * step) }
}

private func derive(
    _ inserted: String, reads: [String?], raw: String? = nil, context: LearningContext = LearningContext(),
    id: Int64 = 1
) -> CorrectionCapture? {
    CorrectionCapture.deriveLatest(
        inserted: inserted, raw: raw ?? inserted, snapshots: snapshots(reads), context: context,
        dictationID: id, now: fixedNow, isCommonWord: isTestCommon)
}

private func term(_ before: String, _ after: String) -> CorrectionEvent {
    CorrectionEvent(kind: .asrTerm, before: before, after: after)
}

@Suite("Learning · short dictations · learned")
struct ShortDictationLearnedTests {
    @Test("a misspelled name fixed inside an empty field")
    func emptyField() throws {
        let capture = try #require(derive("Pria.", reads: ["Pria.", "Priya.", "Priya.", "Priya."]))
        #expect(capture.events == [term("Pria", "Priya")])
        #expect(capture.dictationID == 1)
    }

    @Test("a fix inside a field with text before and after")
    func textBeforeAndAfter() throws {
        let before = "Hi team,\nplease welcome Pria. Thanks for waiting."
        let after = "Hi team,\nplease welcome Priya. Thanks for waiting."
        let capture = try #require(derive("Pria.", reads: [before, after, after]))
        #expect(capture.events == [term("Pria", "Priya")])
    }

    @Test("a fix at the start of a field")
    func startOfField() throws {
        let capture = try #require(derive("Kubernetis", reads: [
            "Kubernetis is down since morning", "Kubernetes is down since morning", "Kubernetes is down since morning"]))
        #expect(capture.events == [term("Kubernetis", "Kubernetes")])
    }

    @Test("a fix at the end of a field")
    func endOfField() throws {
        let capture = try #require(derive("Nikolai", reads: [
            "Please forward this to Nikolai", "Please forward this to Nicolai", "Please forward this to Nicolai"]))
        #expect(capture.events == [term("Nikolai", "Nicolai")])
    }

    @Test("a two-word dictation with one word fixed")
    func twoWords() throws {
        let capture = try #require(derive("Pria Raman", reads: [
            "Notes from Pria Raman today", "Notes from Priya Raman today", "Notes from Priya Raman today"]))
        #expect(capture.events == [term("Pria", "Priya")])
    }

    @Test("the second word of a two-word dictation fixed")
    func secondWord() throws {
        let capture = try #require(derive("Priya Ramon", reads: ["Priya Ramon", "Priya Raman", "Priya Raman"]))
        #expect(capture.events == [term("Ramon", "Raman")])
    }

    @Test("the person kept the fix for the rest of the window: later identical reads count")
    func laterReads() throws {
        let fixed = "see Priya"
        let capture = try #require(derive("Pria", reads: ["see Pria", fixed, fixed, fixed, fixed]))
        #expect(capture.events == [term("Pria", "Priya")])
    }

    @Test("a fix seen on two reads, then the field is emptied (sent), is still learned")
    func sentAfterFix() throws {
        let capture = try #require(derive("Pria", reads: ["Pria", "Priya", "Priya", ""]))
        #expect(capture.events == [term("Pria", "Priya")])
    }

    @Test("never grants the one-letter shortcut: the two-observation rule stays")
    func noShortcut() throws {
        let capture = try #require(derive("Pria.", reads: ["Pria.", "Priya.", "Priya."]))
        #expect(capture.oneEditSpellingKeys.isEmpty)
    }

    @Test("a closer anchor is used when the person typed on after the dictation")
    func typedOnBeforeFix() throws {
        let capture = try #require(derive("Pria", reads: [
            "Pria", "Pria and then", "Pria and then more", "Priya and then more", "Priya and then more"]))
        #expect(capture.events == [term("Pria", "Priya")])
    }
}

@Suite("Learning · short dictations · learned items")
struct ShortDictationStoreTests {
    private func record(_ capture: CorrectionCapture?, _ store: Store) throws {
        let capture = try #require(capture)
        try store.recordCorrections(capture, policy: LearningPolicy(autoActivateTerms: true))
    }

    @Test("one short fix is only a candidate; the second distinct dictation activates the term")
    func twoObservations() throws {
        let store = try Store()
        try record(derive("Pria.", reads: ["Pria.", "Priya.", "Priya."], id: 1), store)
        #expect(try store.learnedItems().allSatisfy { $0.status != .active })
        try record(derive("Pria", reads: ["Pria", "Priya", "Priya"], id: 2), store)
        let active = try store.learnedItems().filter { $0.status == .active && $0.kind == .term }
        #expect(active.map(\.key) == ["priya"])
    }

    @Test("the same dictation counted twice does not activate")
    func sameDictationTwice() throws {
        let store = try Store()
        try record(derive("Pria.", reads: ["Pria.", "Priya.", "Priya."], id: 1), store)
        try record(derive("Pria.", reads: ["Pria.", "Priya.", "Priya."], id: 1), store)
        #expect(try store.learnedItems().allSatisfy { $0.status != .active })
    }
}

@Suite("Learning · short dictations · refused")
struct ShortDictationRefusalTests {
    @Test("the corrected spelling already appears elsewhere in the field")
    func correctedSpellingElsewhere() {
        #expect(derive("Pria", reads: [
            "Priya wrote it. Pria", "Priya wrote it. Priya", "Priya wrote it. Priya"]) == nil)
    }

    @Test("the dictated word appears twice in the earlier read, so there is no single place to anchor")
    func ambiguousAnchor() {
        #expect(derive("Pria", reads: [
            "Pria asked. Pria", "Pria asked. Priya", "Pria asked. Priya"]) == nil)
    }

    @Test("the heard word is still in the field after the fix, in a two-word dictation with a unique anchor")
    func heardWordLeftBehind() {
        #expect(derive("Pria Raman", reads: [
            "Pria Raman and Pria", "Priya Raman and Pria", "Priya Raman and Pria"]) == nil)
        // The same shape without the leftover is learned, so the refusal above is the leftover's.
        #expect(derive("Pria Raman", reads: [
            "Pria Raman and Anil", "Priya Raman and Anil", "Priya Raman and Anil"]) != nil)
    }

    @Test("the heard word sits next to the dictation in another spelling or case")
    func heardKeyElsewhere() {
        #expect(derive("Pria", reads: ["met pria, then Pria", "met pria, then Priya", "met pria, then Priya"]) == nil)
        #expect(derive("Pria", reads: ["met Anil, then Pria", "met Anil, then Priya", "met Anil, then Priya"]) != nil)
    }

    @Test("the corrected word sits next to the dictation in another spelling or case")
    func fixedKeyElsewhere() {
        #expect(derive("Pria", reads: ["Priya, note: Pria", "Priya, note: Priya", "Priya, note: Priya"]) == nil)
        #expect(derive("Pria", reads: ["Anil, note: Pria", "Anil, note: Priya", "Anil, note: Priya"]) != nil)
    }

    @Test("replaced with an unrelated word")
    func unrelated() {
        #expect(derive("Pria", reads: ["met Pria", "met Gustavo", "met Gustavo"]) == nil)
    }

    @Test("an ordinary word swapped for another ordinary word")
    func ordinarySwap() {
        #expect(derive("their", reads: ["call their", "call there", "call there"]) == nil)
        #expect(derive("big", reads: ["a big", "a large", "a large"]) == nil)
    }

    @Test("digits")
    func digits() {
        #expect(derive("Room 10", reads: ["Meet in Room 10", "Meet in Room 11", "Meet in Room 11"]) == nil)
        #expect(derive("Gate4", reads: ["Gate4", "Gate5", "Gate5"]) == nil)
    }

    @Test("text around the insertion point changed")
    func surroundingChanged() {
        #expect(derive("Pria", reads: [
            "Hi team, welcome Pria today", "Hi all, welcome Priya today", "Hi all, welcome Priya today"]) == nil)
        #expect(derive("Pria", reads: [
            "welcome Pria today", "welcome Priya", "welcome Priya"]) == nil)
    }

    @Test("a word added")
    func wordAdded() {
        #expect(derive("Pria", reads: ["Pria", "Pria Raman", "Pria Raman"]) == nil)
        #expect(derive("Pria", reads: ["Pria", "Priya Raman", "Priya Raman"]) == nil)
    }

    @Test("a word deleted from a two-word dictation")
    func wordDeleted() {
        #expect(derive("Pria Raman", reads: ["Pria Raman", "Priya", "Priya"]) == nil)
    }

    @Test("the dictation deleted")
    func dictationDeleted() {
        #expect(derive("Pria", reads: ["hello Pria today", "hello today", "hello today"]) == nil)
    }

    @Test("the field emptied")
    func fieldEmptied() {
        #expect(derive("Pria", reads: ["Pria", "", ""]) == nil)
    }

    @Test("a field that could not be read")
    func unreadable() {
        #expect(derive("Pria", reads: ["Pria", nil, nil]) == nil)
    }

    @Test("both words of a two-word dictation changed")
    func bothWordsChanged() {
        #expect(derive("Pria Raman", reads: ["Pria Raman", "Priya Ramen", "Priya Ramen"]) == nil)
    }

    @Test("a second edit elsewhere in the field")
    func secondEditElsewhere() {
        #expect(derive("Pria", reads: [
            "Pria and the deck", "Priya and the decks", "Priya and the decks"]) == nil)
    }

    @Test("a correction that does not sound like what was heard")
    func notSoundAlike() {
        #expect(derive("Pria", reads: ["met Pria", "met Zachariah", "met Zachariah"]) == nil)
    }

    @Test("a casing or punctuation-only change")
    func formattingOnly() {
        #expect(derive("Pria.", reads: ["Pria.", "pria.", "pria."]) == nil)
        #expect(derive("Pria.", reads: ["Pria.", "Pria", "Pria"]) == nil)
    }

    @Test("a word that only gained or lost a suffix (an inflection or a half-typed word)")
    func inflection() {
        #expect(derive("Terraform", reads: ["use Terraform", "use Terraforms", "use Terraforms"]) == nil)
        #expect(derive("Priyanka", reads: ["ask Priyanka", "ask Priya", "ask Priya"]) == nil)
    }

    @Test("missing anchor: the first read already shows the fixed text")
    func missingAnchor() {
        #expect(derive("Pria", reads: ["met Priya", "met Priya", "met Priya"]) == nil)
    }

    @Test("missing anchor: no read at all")
    func noReads() {
        #expect(derive("Pria", reads: []) == nil)
    }

    @Test("a fix that was seen on a single read only (it may be half typed)")
    func singleRead() {
        #expect(derive("Pria", reads: ["met Pria", "met Priya"]) == nil)
    }

    @Test("the person kept changing the word: the newest spelling is not stable")
    func notStable() {
        #expect(derive("Pria", reads: ["met Pria", "met Priy", "met Priya"]) == nil)
        #expect(derive("Pria", reads: ["met Pria", "met Priya", "met Priya", "met Priyah"]) == nil)
    }

    @Test("the fix was undone: the dictation is back at the end")
    func undone() {
        #expect(derive("Pria", reads: ["met Pria", "met Priya", "met Priya", "met Pria"]) == nil)
    }

    @Test("a secure field")
    func secureField() {
        #expect(derive("Pria", reads: ["Pria", "Priya", "Priya"], context: LearningContext(isSecureField: true)) == nil)
    }

    @Test("a code editor or terminal")
    func codeEditor() {
        #expect(derive("Pria", reads: ["Pria", "Priya", "Priya"], context: LearningContext(isCodeContext: true)) == nil)
    }

    @Test("password manager, excluded app, learning off, non-English")
    func otherGateRefusals() {
        let reads = ["Pria", "Priya", "Priya"]
        #expect(derive("Pria", reads: reads, context: LearningContext(isDenylistedApp: true)) == nil)
        #expect(derive("Pria", reads: reads, context: LearningContext(
            appBundleID: "com.example.mail", excludedBundleIDs: ["com.example.mail"])) == nil)
        #expect(derive("Pria", reads: reads, context: LearningContext(isEnabled: false)) == nil)
        #expect(derive("Pria", reads: reads, context: LearningContext(detectedLanguage: "de")) == nil)
    }

    @Test("the fix is only visible on reads older than the age limit")
    func tooLate() {
        let reads = [FieldSnapshot(value: "Pria", elapsed: 2), FieldSnapshot(value: "Priya", elapsed: 70),
                     FieldSnapshot(value: "Priya", elapsed: 74)]
        #expect(CorrectionCapture.deriveLatest(
            inserted: "Pria", raw: "Pria", snapshots: reads, context: LearningContext(), dictationID: 1,
            now: fixedNow, isCommonWord: isTestCommon) == nil)
    }
}

@Suite("Learning · short dictations · three words or more are unchanged")
struct LongDictationUnchangedTests {
    @Test("a three-word dictation is derived by the original rules, anchor or not")
    func threeWords() throws {  // no earlier unchanged read: a three-word dictation needs no anchor
        let inserted = "Ask Pria today."
        let fixed = "Hi all,\nAsk Priya today.\nThanks"
        let viaLatest = try #require(derive(inserted, reads: [fixed, fixed]))
        let direct = try #require(CorrectionCapture.derive(
            inserted: inserted, raw: inserted, fieldValue: fixed, context: LearningContext(elapsed: 2),
            dictationID: 1, now: fixedNow, isCommonWord: isTestCommon))
        #expect(viaLatest == direct)
        #expect(viaLatest.events == [term("Pria", "Priya")])
    }

    @Test("a dictation of one word that the original rules would refuse stays refused through derive")
    func singleFieldDeriveStillRefuses() {
        #expect(CorrectionCapture.derive(
            inserted: "Pria", raw: "Pria", fieldValue: "Priya", context: LearningContext(elapsed: 2),
            dictationID: 1, now: fixedNow, isCommonWord: isTestCommon) == nil)
    }
}

@Suite struct ShortDictationRevertTests {
    @Test(arguments: [("code deck", "Codex"), ("Codex", "code deck")])
    func multiwordRevertChangesTokenCount(_ heard: String, _ written: String) throws {
        let swap = VocabularySwap(heard: heard, written: written, source: .dictionaryAlias)
        let capture = try #require(CorrectionCapture.deriveLatest(inserted: written, raw: heard,
            snapshots: snapshots(["before \(written) after", "before \(heard) after", "before \(heard) after"]),
            context: LearningContext(appBundleID: "app.mail"), dictationID: 1, swaps: [swap]))
        #expect(capture.reverts == [Revert(swap: swap, typed: heard)])
        #expect(capture.events.isEmpty)
    }
}
