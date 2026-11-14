import Foundation
import Testing
@testable import MurmurCore

/// A small fixed lexicon so classification tests don't depend on the Mac's word list.
let testCommonWords: Set<String> = [
    "send", "the", "deck", "to", "before", "meeting", "tomorrow", "can", "you", "ask", "about", "cluster",
    "we", "should", "move", "our", "services", "and", "i", "think", "is", "ready", "ping", "release",
    "their", "there", "on", "tuesday", "friday", "john", "big", "large", "a", "it", "this", "so",
    "actually", "like", "um", "hey", "are", "free", "for", "lunch", "cube", "cuddle", "notes", "nodes",
    "grays", "grace", "at", "meet", "let's", "call", "me", "check", "in", "with", "later", "today",
]
func isTestCommon(_ word: String) -> Bool { testCommonWords.contains(word) }

@Suite("Learning · alignment")
struct CorrectionAlignmentTests {
    @Test("aligns a one-word replacement")
    func replacement() {
        let alignment = CorrectionAlignment.align(
            inserted: CorrectionAlignment.tokens("Send the deck to Pria before the meeting."),
            edited: CorrectionAlignment.tokens("Send the deck to Priya before the meeting."))
        #expect(alignment.edits == [WordEdit(before: ["Pria"], after: ["Priya"])])
        #expect(alignment.surfaceChanges.isEmpty)
    }

    @Test("locates the dictation inside surrounding field text, including an edited first word")
    func locateInField() throws {
        let alignment = try #require(CorrectionAlignment.locate(
            inserted: "Pria said the cluster is ready.",
            in: "Hi team,\nPriya said the cluster is ready.\nThanks, N"))
        #expect(alignment.edits == [WordEdit(before: ["Pria"], after: ["Priya"])])
        #expect(alignment.edited.count == alignment.inserted.count)
    }

    @Test("a field that reads two lines back as one is not an edit; a split term joined still is")
    func lineJoin() throws {
        let alignment = try #require(CorrectionAlignment.locate(
            inserted: "Quick update on the plan.\nCan you ask Pria to send it?",
            in: "Quick update on the plan.Can you ask Priya to send it?"))
        #expect(alignment.edits == [WordEdit(before: ["Pria"], after: ["Priya"])])
        let joined = CorrectionAlignment.align(
            inserted: CorrectionAlignment.tokens("It lives in the Terra form module."),
            edited: CorrectionAlignment.tokens("It lives in the Terraform module."))
        #expect(joined.edits == [WordEdit(before: ["Terra", "form"], after: ["Terraform"])])
    }

    @Test("records casing-only changes as surface changes, not edits")
    func surfaceOnly() {
        let alignment = CorrectionAlignment.align(
            inserted: ["Hey,", "are", "you", "free?"], edited: ["hey,", "are", "you", "free?"])
        #expect(alignment.edits.isEmpty)
        #expect(alignment.surfaceChanges.count == 1)
    }

    @Test("refuses to anchor on scattered common words")
    func scattered() {
        let field = Array(repeating: "the quick brown fox jumps over a lazy dog", count: 5).joined(separator: " ")
        #expect(CorrectionAlignment.locate(inserted: "send the deck to the team today", in: field) == nil)
    }

    @Test("refuses a runaway field, but not a long document")
    func longField() {
        let runaway = Array(repeating: "word", count: CorrectionAlignment.maxFieldTokens + 1).joined(separator: " ")
        #expect(CorrectionAlignment.locate(inserted: "word word word", in: runaway) == nil)
        let document = Array(repeating: "word", count: 700).joined(separator: " ") + " send the deck to Pria today"
        let alignment = CorrectionAlignment.locate(inserted: "send the deck to Priya today", in: document)
        #expect(alignment?.edits == [WordEdit(before: ["Priya"], after: ["Pria"])])
    }
}

@Suite("Learning · classification")
struct CorrectionClassifierTests {
    private func classify(_ inserted: String, _ edited: String, raw: String? = nil) -> [CorrectionEvent] {
        let alignment = CorrectionAlignment.align(
            inserted: CorrectionAlignment.tokens(inserted), edited: CorrectionAlignment.tokens(edited))
        return CorrectionClassifier.classify(alignment, raw: raw ?? inserted, isCommonWord: isTestCommon)
    }

    @Test("a misheard name is an ASR term correction")
    func asrName() {
        #expect(classify("Send the deck to Pria.", "Send the deck to Priya.").map(\.kind) == [.asrTerm])
        #expect(classify("Ask Karthick about the release.", "Ask Karthik about the release.").first?.after == "Karthik")
    }

    @Test("a misheard jargon term, including multi-word hearings, is an ASR term")
    func asrJargon() {
        #expect(classify("We should move our services to Kubernetis.", "We should move our services to Kubernetes.")
            .map(\.kind) == [.asrTerm])
        #expect(classify("Can you check the cube cuddle logs", "Can you check the kubectl logs").map(\.kind) == [.asrTerm])
    }

    @Test("swapping one ordinary word for another is a rewrite")
    func commonSwap() {
        #expect(classify("I think their ready.", "I think there ready.").map(\.kind) == [.rewrite])
        #expect(classify("Check the nodes later.", "Check the notes later.").map(\.kind) == [.rewrite])
    }

    @Test("a deliberate change to a different name or day is a rewrite")
    func deliberate() {
        #expect(classify("Send the deck to John.", "Send the deck to Sarah.").map(\.kind) == [.rewrite])
        #expect(classify("Let's meet on Tuesday.", "Let's meet on Friday.").map(\.kind) == [.rewrite])
        // The word list grades a day as a name, so it is not an ordinary word, yet a changed day is still a change of plan.
        #expect(classify("Let's meet on Tuesday.", "Let's meet on Thursday.").map(\.kind) == [.rewrite])
    }

    @Test("numbers are never vocabulary")
    func numbers() {
        #expect(classify("Call me at 2023 today.", "Call me at 2024 today.").map(\.kind) == [.rewrite])
    }

    @Test("typing back a word cleanup removed is a cleanup over-edit")
    func overEdit() {
        let events = classify("I think it is ready.", "I think it is actually ready.", raw: "I think it is actually ready.")
        #expect(events.map(\.kind) == [.cleanupOverEdit])
        #expect(events.first?.after == "actually")
    }

    @Test("typing new words the speaker never said is a rewrite")
    func addedContent() {
        #expect(classify("I think it is ready.", "I think it is almost ready.").map(\.kind) == [.rewrite])
    }

    @Test("deleting a leftover filler is a cleanup under-edit; deleting content is a rewrite")
    func underEdit() {
        #expect(classify("So it is like ready.", "So it is ready.").map(\.kind) == [.cleanupUnderEdit])
        #expect(classify("The deck is ready for lunch.", "The deck is ready.").map(\.kind) == [.rewrite])
    }

    @Test("lowercasing and dropping the period are formatting")
    func formatting() {
        let events = classify("Hey, are you free for lunch.", "hey, are you free for lunch")
        #expect(events.map(\.kind) == [.formatting, .formatting])
        #expect(CorrectionClassifier.formattingSignal(before: "Hey,", after: "hey,") == .lowercased)
        #expect(CorrectionClassifier.formattingSignal(before: "lunch.", after: "lunch") == .droppedTerminalPeriod)
    }

    @Test("a missing final period is not a style signal when the user kept typing")
    func continuation() throws {
        let continued = try #require(CorrectionAlignment.locate(
            inserted: "Please ask the team on the thread.", in: "Please ask the team on the thread about the budget"))
        #expect(continued.continuesAfter)
        #expect(CorrectionClassifier.classify(continued, raw: "", isCommonWord: isTestCommon).isEmpty)
        let ended = try #require(CorrectionAlignment.locate(
            inserted: "Please ask the team on the thread.", in: "Please ask the team on the thread\nThanks"))
        #expect(!ended.continuesAfter)
        #expect(CorrectionClassifier.classify(ended, raw: "", isCommonWord: isTestCommon).map(\.kind) == [.formatting])
    }

    @Test("the real lexicon treats words written almost only with a capital as names, and modern words as words")
    func realLexicon() {
        #expect(LearningLexicon.isCommonWord("meeting"))
        #expect(LearningLexicon.isCommonWord("invited"))
        #expect(!LearningLexicon.isCommonWord("priya"))
        #expect(!LearningLexicon.isCommonWord("sarah"))
        #expect(LearningLexicon.isCommonWord("email") && LearningLexicon.isCommonWord("podcast"))
        #expect(!LearningLexicon.isCommonWord("codex") && !LearningLexicon.isCommonWord("anthropic"))
    }
}

@Suite("Learning · capture gate and privacy")
struct CorrectionCaptureTests {
    private let inserted = "Send the deck to Pria before the meeting."
    private let field = "Send the deck to Priya before the meeting."

    private func derive(_ context: LearningContext, field: String? = nil, inserted: String? = nil) -> CorrectionCapture? {
        CorrectionCapture.derive(
            inserted: inserted ?? self.inserted, raw: inserted ?? self.inserted, fieldValue: field ?? self.field,
            context: context, dictationID: 7, isCommonWord: isTestCommon)
    }

    @Test("a small correction in an ordinary app is captured")
    func captured() throws {
        let capture = try #require(derive(LearningContext(appBundleID: "com.tinyspeck.slackmacgap")))
        #expect(capture.events == [CorrectionEvent(kind: .asrTerm, before: "Pria", after: "Priya")])
        #expect(capture.dictationID == 7)
    }

    @Test("nothing is captured when learning is off, the app is excluded, or the field is secure")
    func privacyRefusals() {
        #expect(derive(LearningContext(isEnabled: false)) == nil)
        #expect(derive(LearningContext(appBundleID: "com.x", excludedBundleIDs: ["com.x"])) == nil)
        #expect(derive(LearningContext(isSecureField: true)) == nil)
        #expect(derive(LearningContext(isDenylistedApp: true)) == nil)
        #expect(LearningGate.refusal(LearningContext(isSecureField: true)) == .secureField)
        #expect(LearningGate.refusal(LearningContext(appBundleID: "com.x", excludedBundleIDs: ["com.x"])) == .excludedApp)
    }

    @Test("code editors, other languages and late reads are refused")
    func contextRefusals() {
        #expect(derive(LearningContext(isCodeContext: true)) == nil)
        #expect(derive(LearningContext(detectedLanguage: "es")) == nil)
        #expect(derive(LearningContext(detectedLanguage: "en-GB")) != nil)
        #expect(derive(LearningContext(elapsed: LearningGate.maxEditAge + 1)) == nil)
    }

    @Test("large rewrites, untouched text and very short dictations teach nothing")
    func conservative() {
        #expect(derive(LearningContext(), field: "Actually never mind, I will present it myself on Friday.") == nil)
        #expect(derive(LearningContext(), field: inserted) == nil)
        #expect(derive(LearningContext(), field: "Priya.", inserted: "Pria.") == nil)
        #expect(CorrectionCapture.derive(inserted: inserted, raw: inserted, fieldValue: nil, context: LearningContext(),
                                         dictationID: 1, isCommonWord: isTestCommon) == nil)
    }

    @Test("a rewrite mixed into a correction is dropped, the term kept")
    func mixed() throws {
        let capture = try #require(derive(
            LearningContext(), field: "Send the deck to Priya before the meeting.",
            inserted: "Send the deck to Pria before the meeting."))
        #expect(capture.events.allSatisfy { $0.kind != .rewrite })
    }
}

@Suite("Learning · repeated field reads")
struct CorrectionSnapshotTests {
    private let inserted = "Send the deck to Pria before the meeting."
    private let fixed = "Send the deck to Priya before the meeting."

    private func derive(_ snapshots: [FieldSnapshot], context: LearningContext = LearningContext()) -> CorrectionCapture? {
        CorrectionCapture.deriveLatest(
            inserted: inserted, raw: inserted, snapshots: snapshots, context: context,
            dictationID: 3, isCommonWord: isTestCommon)
    }

    @Test("a fix made and sent between two looks is still learned from the look that saw it")
    func fixThenSend() throws {
        let capture = try #require(derive([
            FieldSnapshot(value: inserted, elapsed: 8),
            FieldSnapshot(value: fixed, elapsed: 14),
            FieldSnapshot(value: "", elapsed: 20),
            FieldSnapshot(value: nil, elapsed: 26),
        ]))
        #expect(capture.events == [CorrectionEvent(kind: .asrTerm, before: "Pria", after: "Priya")])
        #expect(capture.dictationID == 3)
    }

    @Test("the latest look that shows a correction wins over an earlier half-finished one")
    func latestWins() throws {
        let twice = "Send the deck to Pria before the meeting. Ping Pria."
        let capture = try #require(CorrectionCapture.deriveLatest(
            inserted: "Send the deck to Pria before the meeting.", raw: "Send the deck to Pria before the meeting.",
            snapshots: [
                FieldSnapshot(value: "Send the deck to Pri before the meeting.", elapsed: 9),
                FieldSnapshot(value: fixed, elapsed: 15),
                FieldSnapshot(value: twice, elapsed: 21),
            ],
            context: LearningContext(), dictationID: 3, isCommonWord: isTestCommon))
        #expect(capture.events.first?.after == "Priya")
    }

    @Test("a name caught half-typed just before the message is sent is not learned; the same name on Return is")
    func halfTyped() {
        let pasted = "I spoke with Karthick and the release notes are nearly finished."
        func lesson(onReturn: Bool) -> CorrectionDerivation {
            CorrectionCapture.explainLatest(
                inserted: pasted, raw: pasted,
                snapshots: [
                    FieldSnapshot(value: pasted, elapsed: 1),
                    FieldSnapshot(value: pasted.replacingOccurrences(of: "Karthick", with: "Kar"), elapsed: 2),
                    FieldSnapshot(value: pasted.replacingOccurrences(of: "Karthick", with: onReturn ? "Karthik" : "Karthi"), elapsed: 3, onReturn: onReturn),
                    FieldSnapshot(value: "", elapsed: 4),
                ],
                context: LearningContext(), dictationID: 1, isCommonWord: isTestCommon)
        }
        #expect(lesson(onReturn: false) == .dropped(.notSettled))
        #expect(lesson(onReturn: true).capture?.events.map(\.after) == ["Karthik"])
    }

    @Test("looks that never show a correction teach nothing")
    func untouched() {
        #expect(derive([FieldSnapshot(value: inserted, elapsed: 8), FieldSnapshot(value: inserted, elapsed: 30)]) == nil)
        #expect(derive([]) == nil)
    }

    @Test("each look is gated on its own age, and a refused context learns nothing")
    func gates() {
        #expect(derive([FieldSnapshot(value: fixed, elapsed: LearningGate.maxEditAge + 1)]) == nil)
        #expect(derive([FieldSnapshot(value: fixed, elapsed: 14)], context: LearningContext(isSecureField: true)) == nil)
        #expect(derive([FieldSnapshot(value: fixed, elapsed: 14)], context: LearningContext(isEnabled: false)) == nil)
    }
}

@Suite("Learning · reads before the edit verdict")
struct EarlyReadScheduleTests {
    @Test("a fix sent inside the first eight seconds can be read; the verdict read stays at eight")
    func schedule() {
        let offsets = LearningReadSchedule.offsets
        #expect(offsets.contains(LearningReadSchedule.verdictOffset))
        #expect(LearningReadSchedule.verdictOffset == 8)
        let early = offsets.filter { $0 < LearningReadSchedule.verdictOffset }
        #expect(early.count >= 3)
        #expect(early.first.map { $0 <= 2 } == true)
    }

    @Test("the first two seconds are read densely enough that a fix held for a second is seen twice")
    func denseEarlyReads() {
        let early = LearningReadSchedule.offsets.filter { $0 <= 2 }
        #expect(early.count >= 4)
        #expect(zip(early, early.dropFirst()).allSatisfy { $1 - $0 <= 0.5 })
    }

    @Test("reads are ordered, never more than four seconds apart after the first, and inside the age gate")
    func spacing() {
        let offsets = LearningReadSchedule.offsets
        #expect(offsets == offsets.sorted())
        #expect(Set(offsets).count == offsets.count)
        #expect(zip(offsets, offsets.dropFirst()).allSatisfy { $1 - $0 <= 4 })
        #expect(offsets.last.map { $0 <= LearningGate.maxEditAge } == true)
        #expect(offsets.last == 30)
        #expect(!offsets.contains(60))
    }
}

@Suite("Learning · a fix sent within seconds")
struct FastFixAndSendTests {
    private let inserted = "Send the deck to Pria before the meeting."
    private let fixed = "Send the deck to Priya before the meeting."

    /// What a chat box holds: the dictation, then the fix, then nothing once it is sent.
    private func field(at seconds: TimeInterval, fixedAt: TimeInterval, sentAt: TimeInterval) -> String {
        seconds >= sentAt ? "" : seconds >= fixedAt ? fixed : inserted
    }

    @Test("a fix made 1.2 s after paste and sent at 2.3 s is learned through the one-letter path")
    func fixedAndSentInTwoSeconds() throws {
        let snapshots = LearningReadSchedule.offsets.filter { $0 < LearningReadSchedule.verdictOffset }.map {
            FieldSnapshot(value: field(at: $0, fixedAt: 1.2, sentAt: 2.3), elapsed: $0)
        }
        let capture = try #require(CorrectionCapture.deriveLatest(
            inserted: inserted, raw: inserted, snapshots: snapshots,
            context: LearningContext(appBundleID: "com.anthropic.claudefordesktop"), dictationID: 1, isCommonWord: isTestCommon))
        #expect(capture.events == [CorrectionEvent(kind: .asrTerm, before: "Pria", after: "Priya")])
        #expect(capture.oneEditSpellingKeys == ["priya"])
        let learned = Learner.observe(capture, existing: [], knownTerms: [], policy: LearningPolicy(autoActivateTerms: true))
        #expect(learned.first?.status == .active)
    }

    @Test("on the old 2, 4, 6 s reads the same fix is seen once, so it stays a candidate")
    func oldScheduleSawItOnce() throws {
        let snapshots = [2.0, 4, 6].map { FieldSnapshot(value: field(at: $0, fixedAt: 1.2, sentAt: 2.3), elapsed: $0) }
        let capture = try #require(CorrectionCapture.deriveLatest(
            inserted: inserted, raw: inserted, snapshots: snapshots,
            context: LearningContext(appBundleID: "com.anthropic.claudefordesktop"), dictationID: 1, isCommonWord: isTestCommon))
        #expect(capture.oneEditSpellingKeys.isEmpty)
        let learned = Learner.observe(capture, existing: [], knownTerms: [], policy: LearningPolicy(autoActivateTerms: true))
        #expect(learned.first?.status == .candidate)
    }
}

@Suite("Learning · a fix caught half-typed")
struct HalfTypedFixTests {
    /// "Priya" is one inserted interior letter from "Pria": the one-letter path's exact shape,
    /// and also what a person passes through on the way to typing "Priyanka".
    private let inserted = "Send the deck to Pria before the meeting."
    private let partial = "Send the deck to Priya before the meeting."
    private let finished = "Send the deck to Priyanka before the meeting."
    private let auto = LearningPolicy(autoActivateTerms: true)

    private func derive(_ snapshots: [FieldSnapshot], id: Int64 = 1) -> CorrectionCapture? {
        CorrectionCapture.deriveLatest(
            inserted: inserted, raw: inserted, snapshots: snapshots, context: LearningContext(appBundleID: "com.apple.mail"),
            dictationID: id, isCommonWord: isTestCommon)
    }

    private func status(_ capture: CorrectionCapture, existing: [LearnedItem] = []) -> [LearnedItem] {
        Learner.observe(capture, existing: existing, knownTerms: [], policy: auto)
    }

    @Test("one read that shows the word half-way is not enough for the one-letter path")
    func singleReadIsNotVerified() throws {
        let capture = try #require(derive([
            FieldSnapshot(value: partial, elapsed: 4),
            FieldSnapshot(value: "", elapsed: 10),
        ]))
        #expect(capture.events == [CorrectionEvent(kind: .asrTerm, before: "Pria", after: "Priya")])
        #expect(capture.oneEditSpellingKeys.isEmpty)
        #expect(status(capture).first?.status == .candidate)
    }

    @Test("the same spelling on two reads is a settled fix and keeps the one-letter path")
    func repeatedReadsAreVerified() throws {
        let capture = try #require(derive([
            FieldSnapshot(value: partial, elapsed: 4),
            FieldSnapshot(value: partial, elapsed: 6),
            FieldSnapshot(value: "", elapsed: 10),
        ]))
        #expect(capture.oneEditSpellingKeys == ["priya"])
        #expect(status(capture).first?.status == .active)
    }

    @Test("a half-typed spelling seen once, then a longer unrecognised rewrite, is still not verified")
    func laterRewriteDoesNotVerifyEarlierPartial() throws {
        // "Priyanka" is not a spelling repair of "Pria", so the older read is the newest correction.
        let capture = try #require(derive([
            FieldSnapshot(value: partial, elapsed: 4),
            FieldSnapshot(value: finished, elapsed: 8),
        ]))
        #expect(capture.events.first?.after == "Priya")
        #expect(capture.oneEditSpellingKeys.isEmpty)
        #expect(status(capture).first?.status == .candidate)
    }

    @Test("the same half-typed spelling caught in two separate dictations does reach the two-sighting rule")
    func samePartialTwiceActivates() throws {
        let first = try #require(derive([FieldSnapshot(value: partial, elapsed: 4)], id: 1))
        let second = try #require(derive([FieldSnapshot(value: partial, elapsed: 4)], id: 2))
        let afterFirst = status(first)
        #expect(afterFirst.allSatisfy { $0.status == .candidate })
        #expect(status(second, existing: afterFirst).contains { $0.status == .active })
    }

    @Test("a fix that stays the same while the person keeps typing after it keeps the one-letter path")
    func fixThenKeepTyping() throws {
        let capture = try #require(derive([
            FieldSnapshot(value: partial + " Thanks", elapsed: 4),
            FieldSnapshot(value: partial + " Thanks, see you there", elapsed: 6),
            FieldSnapshot(value: partial + " Thanks, see you there at nine.", elapsed: 8),
        ]))
        #expect(capture.oneEditSpellingKeys == ["priya"])
        #expect(status(capture).first?.status == .active)
    }

    @Test("stability is per spelling: a second fix seen once does not borrow the first fix's repeats")
    func stabilityIsPerSpelling() throws {
        let twoWords = "Send the deck to Pria before the meeting with Kamal."
        let capture = try #require(CorrectionCapture.deriveLatest(
            inserted: twoWords, raw: twoWords,
            snapshots: [
                FieldSnapshot(value: "Send the deck to Priya before the meeting with Kamal.", elapsed: 4),
                FieldSnapshot(value: "Send the deck to Priya before the meeting with Kamal.", elapsed: 6),
                FieldSnapshot(value: "Send the deck to Priya before the meeting with Kamaal.", elapsed: 8),
            ],
            context: LearningContext(appBundleID: "com.apple.mail"), dictationID: 1, isCommonWord: isTestCommon))
        #expect(!capture.oneEditSpellingKeys.contains("kamaal"))
        #expect(capture.oneEditSpellingKeys.contains("priya"))
    }

    @Test("a secure field on any one read refuses learning, however early")
    func secureOnAnyRead() {
        var context = LearningContext(appBundleID: "com.apple.mail")
        context.isSecureField = true
        #expect(CorrectionCapture.deriveLatest(
            inserted: inserted, raw: inserted,
            snapshots: [FieldSnapshot(value: partial, elapsed: 2), FieldSnapshot(value: partial, elapsed: 4)],
            context: context, dictationID: 1, isCommonWord: isTestCommon) == nil)
    }
}

@Suite("Learning · what each look may teach")
struct LearningReadsTests {
    private let inserted = "Send the deck to Pria before the meeting."
    private let fixed = "Send the deck to Priya before the meeting."

    private func read(_ value: String?, _ security: FieldSecurity, _ elapsed: TimeInterval) -> FieldRead {
        FieldRead(value: value, security: security, elapsed: elapsed)
    }

    private func derive(_ resolved: LearningReads.Resolved) -> CorrectionCapture? {
        CorrectionCapture.deriveLatest(
            inserted: inserted, raw: inserted, snapshots: resolved.snapshots,
            context: LearningContext(isSecureField: resolved.isSecureField), dictationID: 1, isCommonWord: isTestCommon)
    }

    @Test("a secure field on any one look refuses learning")
    func secureOnAnyLook() {
        let resolved = LearningReads.resolve([read(fixed, .notSecure, 4), read(fixed, .secure, 6), read(fixed, .notSecure, 8)])
        #expect(resolved.isSecureField)
        #expect(derive(resolved) == nil)
    }

    @Test("a look whose security could not be read is dropped; the other looks still teach")
    func unknownLookIsDropped() throws {
        let resolved = LearningReads.resolve([read(fixed, .notSecure, 4), read(nil, .unknown, 6), read("", .notSecure, 10)])
        #expect(!resolved.isSecureField)
        let capture = try #require(derive(resolved))
        #expect(capture.events == [CorrectionEvent(kind: .asrTerm, before: "Pria", after: "Priya")])
    }

    @Test("text from a look that could not be checked is never used")
    func unknownLookTextIsNotUsed() {
        let resolved = LearningReads.resolve([read(inserted, .notSecure, 4), read(fixed, .unknown, 6)])
        #expect(!resolved.isSecureField)
        #expect(resolved.snapshots.compactMap(\.value) == [inserted])
        #expect(derive(resolved) == nil)
    }

    @Test("when every look is unknown nothing is learned, and the dictation is not marked secure")
    func allUnknown() {
        let resolved = LearningReads.resolve([read(fixed, .unknown, 4), read(fixed, .unknown, 8)])
        #expect(!resolved.isSecureField)
        #expect(resolved.snapshots.compactMap(\.value).isEmpty)
        #expect(derive(resolved) == nil)
    }
}

@Suite("Learning · a rare word across hearings")
struct RareWordHandOffTests {
    /// Treats the two ordinary words of a classic mishearing as common, like the real lexicon would.
    private let common: (String) -> Bool = { testCommonWords.union(["diary", "station", "dire"]).contains($0) }

    private func fixedCapture(_ id: Int64, heard: String, offset: TimeInterval) -> CorrectionCapture? {
        let inserted = "We should add \(heard) to the notes."
        let field = "We should add diarization to the notes."
        return CorrectionCapture.derive(
            inserted: inserted, raw: inserted, fieldValue: field,
            context: LearningContext(appBundleID: "com.tinyspeck.slackmacgap"), dictationID: id,
            now: Date(timeIntervalSince1970: 1_800_000_000 + offset), isCommonWord: common)
    }

    @Test("two different hearings fixed to one spelling activate it and replace every taught hearing")
    func differentHearings() throws {
        var items: [LearnedItem] = []
        for (id, heard) in [(Int64(1), "diarisation"), (2, "diary station"), (3, "dire ization")] {
            let capture = try #require(fixedCapture(id, heard: heard, offset: Double(id) * 3600))
            let changed = Learner.observe(capture, existing: items, knownTerms: [], policy: LearningPolicy(autoActivateTerms: true))
            let ids = Set(changed.map(\.identity))
            items = items.filter { !ids.contains($0.identity) } + changed
        }
        let item = try #require(items.first { $0.key == "diarization" })
        #expect(item.status == .active)
        #expect(item.heardAs.contains("diary station"))
        let entries = LearnedPersonalization.dictionaryEntries(from: items)
        #expect(entries.map(\.term) == ["diarization"])
        let personalizer = Personalizer(dictionary: entries, snippets: [])
        #expect(personalizer.apply("add diarisation now").text == "add diarization now")
        #expect(personalizer.apply("add dire ization now").text == "add diarization now")
        #expect(personalizer.apply("add diary station now").text == "add diarization now")
    }
}
