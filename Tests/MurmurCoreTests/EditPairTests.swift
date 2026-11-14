import Foundation
import Testing
@testable import MurmurCore

/// The before-and-after memory keeps from a changed dictation. Every sentence is invented.
@Suite("Edit pairs")
struct EditPairTests {
    private let dictation = "we can meet at Tarrow Rij on Friday after the review"

    /// Looks at the field two seconds apart: the dictation as pasted, then each later value.
    private func looks(_ values: String?...) -> [FieldSnapshot] {
        values.enumerated().map { FieldSnapshot(value: $1, elapsed: Double($0 + 1) * 2) }
    }

    private func pairs(_ inserted: String, _ snapshots: [FieldSnapshot], _ context: LearningContext = LearningContext()) -> [EditPair] {
        EditPair.derive(inserted: inserted, snapshots: snapshots, context: context)
    }

    @Test("a fixed name gives one pair: the changed words and three of the dictation's own either side")
    func oneChange() {
        let fixed = "we can meet at Tavren Ridge on Friday after the review"
        #expect(pairs(dictation, looks(dictation, fixed, fixed)) == [
            EditPair(before: "can meet at Tarrow Rij on Friday after", after: "can meet at Tavren Ridge on Friday after"),
        ])
    }

    @Test("nothing else in the field is ever in a pair, even when the first and last words changed")
    func surroundingTextStaysOut() {
        let inserted = "bring the lantern and the map to the gate tonight"
        let before = "Note for the Veloria crew:\n", after = "\nSigned, the Nerula desk"
        let edited = "Carry the lantern and the map to the gate today"
        let found = pairs(inserted, looks(before + inserted + after, before + edited + after, before + edited + after))
        #expect(found == [
            EditPair(before: "bring the lantern and", after: "Carry the lantern and"),
            EditPair(before: "to the gate tonight", after: "to the gate today"),
        ])
        for word in ["Note", "Veloria", "crew", "Signed", "Nerula", "desk"] {
            #expect(!found.contains { $0.before.contains(word) || $0.after.contains(word) })
        }
    }

    @Test("without an earlier look that held the dictation, its place is unknown and there is no pair")
    func needsAnAnchor() {
        let fixed = "we can meet at Tavren Ridge on Friday after the review"
        #expect(pairs(dictation, looks(fixed, fixed, fixed)).isEmpty)
        // Twice in the field: which one was pasted cannot be told.
        #expect(pairs(dictation, looks(dictation + " " + dictation, fixed + " " + dictation, fixed + " " + dictation)).isEmpty)
    }

    @Test("a look whose text around the dictation changed is not used")
    func surroundingsMustHold() {
        let fixed = "we can meet at Tavren Ridge on Friday after the review"
        let found = pairs(dictation, looks("Agenda: " + dictation, "Plan: " + fixed, "Plan: " + fixed))
        #expect(found.isEmpty)
    }

    @Test("a reworded passage the learned-item path drops as a rewrite (over 40% changed) is a pair")
    func rewriteIsKept() {
        let inserted = "the crates for the Veloria run are packed and ready"
        let edited = "the crates for the Veloria run are packed, labelled, stacked by the door and ready"
        let context = LearningContext()
        #expect(CorrectionCapture.derive(inserted: inserted, raw: inserted, fieldValue: edited, context: context, dictationID: 1) == nil)
        #expect(pairs(inserted, looks(inserted, edited, edited), context) == [
            EditPair(before: "Veloria run are packed and ready", after: "Veloria run are packed, labelled, stacked by the door and ready"),
        ])
    }

    @Test("when too few of the dictation's words are left to find it, nothing is kept")
    func replacedOutright() {
        let other = "the crates are packed and the cart leaves at dawn from the yard"
        #expect(pairs(dictation, looks(dictation, other, other)).isEmpty)
    }

    @Test("a change longer than the cap is not kept; a shorter one beside it still is")
    func lengthCap() {
        let filler = (1...60).map { "word\($0)" }
        let inserted = (["send", "the", "Veloria", "list"] + filler + ["before", "the", "meeting", "starts"]).joined(separator: " ")
        // Every third filler word changed: one run of changes far longer than the cap.
        let reworked = filler.enumerated().map { $0.offset % 3 == 0 ? "changed\($0.offset)" : $0.element }
        let edited = (["send", "the", "Veloria", "list"] + reworked + ["before", "the", "meeting", "starts"]).joined(separator: " ")
        #expect(pairs(inserted, looks(inserted, edited, edited)).isEmpty)
        let small = inserted.replacingOccurrences(of: "meeting starts", with: "review begins")
        #expect(pairs(inserted, looks(inserted, small, small)) == [
            EditPair(before: "word60 before the meeting starts", after: "word60 before the review begins"),
        ])
    }

    @Test("changes far apart are separate pairs, three at most")
    func separatePairs() {
        let words = (1...60).map { "word\($0)" }
        let inserted = words.joined(separator: " ")
        var changed = words
        for index in [5, 20, 35, 50] { changed[index] = "fixed\(index)" }
        let edited = changed.joined(separator: " ")
        let found = pairs(inserted, looks(inserted, edited, edited))
        #expect(found.count == EditPair.maxPairs)
        #expect(found.first == EditPair(before: "word3 word4 word5 word6 word7 word8 word9", after: "word3 word4 word5 fixed5 word7 word8 word9"))
    }

    @Test("capitals and punctuation count as a change; a full stop dropped to keep typing does not")
    func surfaceChanges() {
        let inserted = "hello team, the draft is ready."
        let capital = "Hello team, the draft is ready."
        #expect(pairs(inserted, looks(inserted, capital, capital)) == [
            EditPair(before: "hello team, the draft", after: "Hello team, the draft"),
        ])
        let continued = "hello team, the draft is ready and the notes follow"
        #expect(pairs(inserted, looks(inserted, continued, continued)).isEmpty)
    }

    @Test("text typed after the dictation is not part of the pair")
    func typedAfter() {
        let fixed = "we can meet at Tavren Ridge on Friday after the review and bring the map"
        #expect(pairs(dictation, looks(dictation, fixed, fixed)) == [
            EditPair(before: "can meet at Tarrow Rij on Friday after", after: "can meet at Tavren Ridge on Friday after"),
        ])
    }

    @Test("a change seen only on the last look may be half typed, so it waits; one the field moved on from is kept")
    func settledOnly() {
        let half = "we can meet at Tav Rij on Friday after the review"
        #expect(pairs(dictation, looks(dictation, dictation, half)).isEmpty)
        let fixed = "we can meet at Tavren Ridge on Friday after the review"
        // Fixed, then sent: the box is empty on the later looks.
        #expect(pairs(dictation, looks(dictation, fixed, "", "")).count == 1)
    }

    @Test("a dictation left as it was, or put back, gives nothing")
    func unchanged() {
        let fixed = "we can meet at Tavren Ridge on Friday after the review"
        #expect(pairs(dictation, looks(dictation, dictation, dictation)).isEmpty)
        #expect(pairs(dictation, looks(dictation, fixed, fixed, dictation)).isEmpty)
    }

    @Test("every refusal the learning gate knows gives nothing, and so does a dictation under three words")
    func refusals() {
        let fixed = "we can meet at Tavren Ridge on Friday after the review"
        let snapshots = looks(dictation, fixed, fixed)
        let refused = [
            LearningContext(isEnabled: false),
            LearningContext(appBundleID: "app.quillpad.mail", excludedBundleIDs: ["app.quillpad.mail"]),
            LearningContext(isSecureField: true), LearningContext(isDenylistedApp: true),
            LearningContext(isCodeContext: true), LearningContext(detectedLanguage: "fr"),
        ]
        for context in refused { #expect(pairs(dictation, snapshots, context).isEmpty) }
        #expect(pairs(dictation, snapshots).count == 1)
        // Looks taken after the gate's time limit are not read.
        let late = [FieldSnapshot(value: dictation, elapsed: 2), FieldSnapshot(value: fixed, elapsed: 90),
                    FieldSnapshot(value: fixed, elapsed: 94)]
        #expect(pairs(dictation, late).isEmpty)
        #expect(pairs("Tarrow Rij", looks("Tarrow Rij", "Tavren Ridge", "Tavren Ridge")).isEmpty)
    }

    @Test("a pair marks the words that changed on each side")
    func words() {
        let pair = EditPair(before: "meet at Tarrow Rij on Friday", after: "meet at Tavren Ridge on Friday")
        #expect(pair.words.before.filter(\.isChanged).map(\.text) == ["Tarrow", "Rij"])
        #expect(pair.words.after.filter(\.isChanged).map(\.text) == ["Tavren", "Ridge"])
        #expect(pair.words.before.map(\.text).joined(separator: " ") == pair.before)
        #expect(pair.words.after.map(\.text).joined(separator: " ") == pair.after)
    }
}
