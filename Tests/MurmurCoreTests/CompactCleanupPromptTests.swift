import Foundation
import Testing
@testable import MurmurCore

@Suite("Compact cleanup prompt + training pair check (M7 fine-tune)")
struct CompactCleanupPromptTests {
    @Test("paragraph labels require an explicit allowance and still undergo word checks")
    func trainingParagraphAllowance() {
        let raw = "We finished the report this morning. The team reviewed every section before lunch."
        let target = "We finished the report this morning.\n\nThe team reviewed every section before lunch."
        #expect(TrainingPairCheck.check(raw: raw, target: target, level: .clean).rejection == ListStructureGuard.reason)
        #expect(TrainingPairCheck.check(raw: raw, target: target, level: .clean, allowingParagraphBreaks: true).rejection == nil)
        let dropped = "We finished the report this morning.\n\nThe team reviewed every section."
        #expect(TrainingPairCheck.check(raw: raw, target: dropped, level: .clean, allowingParagraphBreaks: true).rejection != nil)
    }
    @Test("production Clean/Polished instructions map to the compact text of the same level")
    func mapsLevels() throws {
        let clean = try #require(CompactCleanupPrompt.systemText(forInstructions: SmartCleaner.cleanupInstructions(confidenceGuided: false)))
        let polished = try #require(CompactCleanupPrompt.systemText(
            forInstructions: SmartCleaner.cleanupInstructions(confidenceGuided: false, grammarRepair: true)))
        #expect(clean == CompactCleanupPrompt.systemText(level: .clean))
        #expect(polished == CompactCleanupPrompt.systemText(level: .polished))
        #expect(clean.contains("Level: Clean.") && clean.contains("Do not fix grammar"))
        #expect(polished.contains("Level: Polished.") && polished.contains("Also fix grammar"))
        // The point of the compact prompt: an order of magnitude shorter than production.
        #expect(clean.count * 5 < SmartCleaner.instructions.count)
    }

    @Test("confidence and language blocks carry over; other instructions are left alone")
    func suffixes() throws {
        let production = SmartCleaner.cleanupInstructions(confidenceGuided: true, languageToKeep: "de")
        let compact = try #require(CompactCleanupPrompt.systemText(forInstructions: production))
        #expect(compact.hasPrefix(CompactCleanupPrompt.systemText(level: .clean)))
        #expect(compact.contains("⟦⟧"))
        #expect(compact.hasSuffix(SmartCleaner.languageInstructions(for: "de")))
        #expect(CompactCleanupPrompt.systemText(forInstructions: "Which candidate keeps everything?") == nil)
    }

    @Test("the answer is the grammar's compact JSON, and it round-trips")
    func answerJSON() throws {
        let text = "Pack:\n- The tent\n- A \"lantern\" \\ torch\tbag — naïve/ok"
        let json = CompactCleanupPrompt.answerJSON(text)
        #expect(json.hasPrefix("{\"text\":\"Pack:\\n- The tent"))
        #expect(!json.contains("\\/"))
        #expect(json.contains("naïve"))
        let decoded = try JSONDecoder().decode([String: String].self, from: Data(json.utf8))
        #expect(decoded["text"] == text)
    }

    @Test("user turn is byte-identical to production's")
    func userTurn() {
        #expect(CompactCleanupPrompt.userPrompt(draft: "hi there") == "Transcript: hi there\nOutput:")
    }

    @Test("training pairs go through the production guards")
    func trainingPairCheck() {
        let good = TrainingPairCheck.check(
            raw: "um the invoices is due monday and it need to go to both client",
            target: "The invoices are due Monday and they need to go to both clients.", level: .polished)
        #expect(good.rejection == nil)
        #expect(good.modelAsked)
        #expect(!good.draft.lowercased().contains("um "))

        let collapsed = TrainingPairCheck.check(raw: "i had had enough of the the delays", target: "I had enough of the delays.", level: .clean)
        #expect(collapsed.rejection?.contains("doubled") == true)

        let digits = TrainingPairCheck.check(
            raw: "the budget i think it should be fifty thousand not forty",
            target: "I think the budget should be 50,000, not 40,000.", level: .polished)
        #expect(digits.rejection != nil)

        let negative = TrainingPairCheck.check(raw: "No, I don't want the beta.", target: "No, I don't want the beta.", level: .clean)
        #expect(negative.rejection == nil)
        #expect(negative.draft == "No, I don't want the beta.")
    }

    @Test("protected terms are enforced")
    func protectedTerms() {
        let result = TrainingPairCheck.check(
            raw: "send it to siobhan by noon", target: "Send it to Shivon by noon.", level: .clean, protectedTerms: ["Siobhan"])
        #expect(result.rejection != nil)
    }
}
