import Foundation
import Testing
@testable import MurmurCore

/// A check that objects because the model's rewrite lost a small piece of what was said (a contrastive "actually", a
/// hedge, a purpose phrase...) does not cost the person the rest of the rewrite. When the lost piece sat inside a
/// span the model also reworded, the piece is put back into the model's words, next to the word it stood beside;
/// when its place is not certain, the whole span goes back as it always did.
@Suite("Dropped word restore", .timeLimit(.minutes(2)), .serialized)
struct DroppedWordRestoreTests {
    /// Judges a candidate the way a check on "actually" does: it objects when the word is missing.
    private let wantsActually: @Sendable (String) -> Bool = { !$0.lowercased().contains("actually") }

    // MARK: The repair itself

    @Test("a dropped word that sat inside a reworded span goes back into the model's words")
    func mergedSpanKeepsTheRewording() {
        let draft = "we actually remainder customers every Friday before lunch"
        let answer = "we remind customers every Friday before lunch"
        let repaired = SpanRepair.repair(draft: draft, answer: answer, restoring: true, objects: wantsActually)
        #expect(repaired?.text == "we actually remind customers every Friday before lunch")
        #expect(repaired?.reverted == 1)
    }

    @Test("without the restore the same span goes back whole and nothing of the rewrite is left")
    func mergedSpanGoesBackWholeWithoutRestore() {
        let draft = "we actually remainder customers every Friday before lunch"
        let answer = "we remind customers every Friday before lunch"
        #expect(SpanRepair.repair(draft: draft, answer: answer, restoring: false, objects: wantsActually) == nil)
        guard case .allGuilty = SpanRepair.attempt(draft: draft, answer: answer, restoring: false, objects: wantsActually) else {
            Issue.record("expected nothing of the rewrite to be left")
            return
        }
    }

    @Test("a dropped word at the end of a reworded span goes back behind the model's words")
    func pieceAtTheEndOfTheSpan() {
        let draft = "send the invoise actually to Priya today and copy Kenji on the thread"
        let answer = "send the invoice to Priya today and copy Kenji on the thread"
        let repaired = SpanRepair.repair(draft: draft, answer: answer, restoring: true, objects: wantsActually)
        #expect(repaired?.text == "send the invoice actually to Priya today and copy Kenji on the thread")
    }

    @Test("a dropped word in the middle of a span reworded on both sides has no certain place: the span goes back whole")
    func pieceInTheMiddleIsNotPlaced() {
        let draft = "ask them to move remainder actually remainder emails to the shared folder today"
        let answer = "ask them to move reminder emails to the shared folder today"
        #expect(SpanRepair.repair(draft: draft, answer: answer, restoring: true, objects: wantsActually) == nil)
    }

    @Test("when two different pieces would each satisfy the check, none is guessed")
    func ambiguousPieceIsNotPlaced() {
        let draft = "we should aaa bbb the report on Friday and send the notes to the team"
        let answer = "we should ccc the report on Friday and send the notes to the team"
        // Either word would quiet this check; neither has a better claim to be the lost one.
        let eitherWord: @Sendable (String) -> Bool = { !($0.contains("aaa") || $0.contains("bbb")) }
        #expect(SpanRepair.repair(draft: draft, answer: answer, restoring: true, objects: eitherWord) == nil)
    }

    @Test("a neighbour the model also changed cannot anchor the piece: the span goes back whole, the other change stays")
    func changedNeighbourIsNoAnchor() {
        let draft = "we actually remainder customers every Friday before lunch"
        let answer = "We remind customers every Friday before lunch"
        // Both "we" and the span after it differ in the answer, so the piece has nothing untouched to stand beside.
        let repaired = SpanRepair.repair(draft: draft, answer: answer, restoring: true, objects: wantsActually)
        #expect(repaired?.text == "We actually remainder customers every Friday before lunch")
    }

    @Test("a piece that would not end the objection once put back is not used")
    func restoreIsCheckedAgain() {
        let draft = "we actually remainder customers every Friday before lunch"
        let answer = "we remind customers every Friday before lunch"
        // The check also objects to "remind", so putting "actually" back does not clear it.
        let stillObjects: @Sendable (String) -> Bool = { !$0.contains("actually") || $0.contains("remind") }
        #expect(SpanRepair.repair(draft: draft, answer: answer, restoring: true, objects: stillObjects) == nil)
    }

    @Test("a dropped word is not carried across a sentence break: the span goes back whole")
    func sentenceBreakIsNotCrossed() {
        let draft = "that is done. actually remainder him again on Monday morning before lunch"
        let answer = "That is done. Remind him again on Monday morning before lunch"
        let repaired = SpanRepair.repair(draft: draft, answer: answer, restoring: true, objects: wantsActually)
        #expect(repaired?.text == "That is done. actually remainder him again on Monday morning before lunch")
    }

    @Test("only a short protected word or phrase is restored; values, polarity and whole clauses stay revert-only")
    func restorableCodesAreDecided() {
        for code: GuardCode in [
            .droppedContrastiveActually, .droppedHedge, .droppedStanceWord, .droppedPurposePhrase, .droppedAdmission,
            .droppedClarificationLeadIn, .droppedMarkedWord, .droppedIdentifier,
        ] {
            #expect(SpanRepair.restorableCodes.contains(code), "\(code.rawValue)")
            #expect(SpanRepair.localCodes.contains(code), "\(code.rawValue)")
        }
        for code: GuardCode in [
            .droppedNumber, .droppedNegation, .droppedContentWords, .droppedTooMuch, .droppedLeadingRequest,
            .droppedClauseBeforeHedge, .droppedTrailingClause, .droppedTrailOff, .collapsedDoubledWord,
            .changedDigits, .changedName, .addedNegation,
        ] {
            #expect(!SpanRepair.restorableCodes.contains(code), "\(code.rawValue)")
        }
    }

    // MARK: Through the cleaner

    private func run(
        _ spoken: String, low: Set<String> = [], edit: @escaping @Sendable (String) -> String
    ) async -> SmartCleaner.Output {
        let cleaner = SmartCleaner(
            budget: .seconds(6), correctionBudget: .seconds(6), polishedBudget: .seconds(6), segmentBudget: .seconds(6),
            model: MarkedEditModel(edit), health: ModelHealth())
        let confidences = spoken.split(separator: " ").map {
            WordConfidence(word: String($0), confidence: low.contains(String($0).lowercased()) ? 0.2 : 0.99)
        }
        return await cleaner.clean(
            spoken, confidences: low.isEmpty ? nil : confidences, options: CleanupOptions(level: .polished))
    }

    private static let shipping = "I called the vendor and they actually shiped the order on Monday and I will check the tracking page tomorrow morning"

    @Test("the model's fix beside a dropped actually stays and the word comes back, other fixes included")
    func fixesStayAndTheWordComesBack() async {
        let output = await run(Self.shipping, low: ["shiped"]) {
            $0.replacingOccurrences(of: "they actually shiped", with: "they shipped")
                .replacingOccurrences(of: "Monday and", with: "Monday, and")
        }
        let group = output.groups.first
        let note = "\(String(describing: group?.guardCode)) \(output.text)"
        #expect(group?.outcome == .used, "\(note)")
        #expect((group?.repairedSpans ?? 0) >= 1, "\(note)")
        #expect(group?.askedAgain == AskedAgain.none)
        #expect(output.text.contains("actually shipped"), "\(output.text)")
        #expect(!output.text.contains("shiped"), "\(output.text)")
        #expect(output.text.contains("Monday, and"), "\(output.text)")
    }

    @Test("a rewrite whose only change is the reworded span with the word dropped is used, not a fall-back")
    func onlyChangeIsTheMergedSpan() async {
        let output = await run(Self.shipping, low: ["shiped"]) {
            $0.replacingOccurrences(of: "they actually shiped", with: "they shipped")
        }
        let group = output.groups.first
        #expect(group?.outcome == .used, "\(String(describing: group?.guardCode)) \(output.text)")
        #expect(output.text.contains("actually shipped"), "\(output.text)")
        #expect(group?.repairHadNothingToKeep == false)
    }

    @Test("a repaired part is reported as repaired, never as the plain version")
    func historyDoesNotSayPlain() async throws {
        let output = await run(Self.shipping, low: ["shiped"]) {
            $0.replacingOccurrences(of: "they actually shiped", with: "they shipped")
        }
        let summary = try #require(CleanupOutcomeSummary(groups: output.groups, level: .polished))
        #expect(summary.code == "ran-repaired", "\(summary.code)")
        #expect(!summary.plainLine.contains("plain version"))
    }

    @Test("a dropped actually that is the only thing the model changed still falls back with the code named")
    func onlyTheWordDroppedStillFallsBack() async {
        let output = await run(Self.shipping) { $0.replacingOccurrences(of: "they actually shiped", with: "they shiped") }
        #expect(output.groups.first?.outcome == .rejectedByGuard)
        #expect(output.groups.first?.guardCode == .droppedContrastiveActually)
        #expect(output.text.contains("actually"))
    }

    private static let reminders = "please set a remainder for Monday morning and I actually want the remainder to repeat every week and send the remainder to Kenji before lunch"

    @Test("a word the model corrected at every place it was heard, beside a dropped actually: the rewrite is used whole")
    func correctedEverywhereAndDroppedWord() async throws {
        let output = await run(Self.reminders, low: ["remainder"]) {
            $0.replacingOccurrences(of: "I actually want", with: "I want").replacingOccurrences(of: "remainder", with: "reminder")
                .replacingOccurrences(of: "morning and", with: "morning, and")
        }
        let group = output.groups.first
        #expect(group?.outcome == .used, "\(String(describing: group?.guardCode)) \(output.text)")
        #expect(output.text.contains("I actually want the reminder"), "\(output.text)")
        #expect(output.text.contains("set a reminder for Monday morning, and"), "\(output.text)")
        #expect(output.text.contains("send the reminder to Kenji"), "\(output.text)")
        #expect(!output.text.contains("remainder"), "\(output.text)")
        let summary = try #require(CleanupOutcomeSummary(groups: output.groups, level: .polished))
        #expect(summary.code == "ran-repaired", "\(summary.code)")
        #expect(!summary.plainLine.contains("plain version"))
    }

    @Test("the same words corrected without confidence marks are used whole too")
    func correctedEverywhereWithoutConfidence() async {
        let output = await run(Self.reminders) {
            $0.replacingOccurrences(of: "I actually want", with: "I want").replacingOccurrences(of: "remainder", with: "reminder")
        }
        #expect(output.groups.first?.outcome == .used, "\(String(describing: output.groups.first?.guardCode)) \(output.text)")
        #expect(output.text.contains("I actually want the reminder"), "\(output.text)")
        #expect(!output.text.contains("remainder"), "\(output.text)")
    }

    @Test("a word replaced by an unrelated one at every place is a real loss: the plain version stays")
    func unrelatedReplacementEverywhereIsALoss() async {
        let output = await run(Self.reminders, low: ["remainder"]) {
            $0.replacingOccurrences(of: "I actually want", with: "I want").replacingOccurrences(of: "remainder", with: "calendar")
        }
        #expect(output.groups.first?.outcome == .rejectedByGuard, "\(output.text)")
        #expect(output.text.contains("remainder"), "\(output.text)")
    }
}

/// Answers the draft (marks removed) with `edit` applied.
final class MarkedEditModel: LanguageModel {
    private let edit: @Sendable (String) -> String
    init(_ edit: @escaping @Sendable (String) -> String) { self.edit = edit }
    var identifier: String { "marked-edit-model" }
    var availability: LanguageModelAvailability { .available }
    func supportsLanguage(_ languageCode: String) -> Bool { true }
    func prewarm(instructions: String) {}
    func prefixCache(instructions: String) async {}
    func respond(
        instructions: String, prompt: String, schema: GenerationSchemaSpec, options: LanguageModelOptions
    ) async throws -> String {
        guard schema.name == SmartCleaner.Cleaned.generationSchema.name else { throw LanguageModelError.unsupportedSchema(schema.name) }
        let draft = prompt.replacingOccurrences(of: "Transcript: ", with: "").replacingOccurrences(of: "\nOutput:", with: "")
            .replacingOccurrences(of: "⟦", with: "").replacingOccurrences(of: "⟧", with: "")
        return String(decoding: try JSONEncoder().encode(["text": edit(draft)]), as: UTF8.self)
    }
}
