import Foundation
import Testing
@testable import MurmurCore

/// Task 142: the two untrained prompt versions (`v2Context`, `v2Paragraphs`) are v2 with one line changed or added, and v2 itself
/// has not moved (the fine-tune is married to its exact text).
@Suite("Compact cleanup prompt experiments (Task 142)")
struct CompactCleanupPromptExperimentTests {
    @Test("v2 text is exactly what it was")
    func v2Pinned() {
        let clean = CompactCleanupPrompt.systemText(level: .clean)
        #expect(clean.contains("never add line breaks, bullets or numbering; keep existing \"- \"/\"1. \" lines."))
        #expect(!clean.contains("Before:"))
        #expect(CompactCleanupPrompt.systemText(level: .polished, version: .v2) == CompactCleanupPrompt.systemText(level: .polished))
    }

    @Test("v2Context is v2 plus the one line that names the context lines, ahead of the contract")
    func contextVersion() {
        for level in [CleanupLevel.clean, .polished] {
            let v2 = CompactCleanupPrompt.systemText(level: level)
            let context = CompactCleanupPrompt.systemText(level: level, version: .v2Context)
            #expect(context.contains(CompactCleanupPrompt.contextRule))
            #expect(context.replacingOccurrences(of: CompactCleanupPrompt.contextRule + "\n", with: "") == v2)
            #expect(context.count < v2.count + 400)
        }
    }

    @Test("v2Paragraphs swaps the layout clause for a paragraph allowance and nothing else")
    func paragraphVersion() {
        let v2 = CompactCleanupPrompt.systemText(level: .polished)
        let paragraphs = CompactCleanupPrompt.systemText(level: .polished, version: .v2Paragraphs)
        #expect(paragraphs != v2)
        #expect(!paragraphs.contains("never add line breaks"))
        #expect(paragraphs.contains("start a new paragraph"))
        #expect(paragraphs.contains("never add bullets or numbering"))
        // Same heading, same rules for Polished, same contract.
        #expect(paragraphs.hasPrefix("Clean up a dictation transcript. Level: Polished."))
        #expect(paragraphs.hasSuffix(CompactCleanupPrompt.contract))
        #expect(paragraphs.contains("Also fix grammar"))
    }

    @Test("production instructions map to the new versions, and the context note a caller appended is not said twice")
    func mapping() throws {
        let production = SmartCleaner.cleanupInstructions(confidenceGuided: false, grammarRepair: true)
        let mapped = try #require(CompactCleanupPrompt.systemText(forInstructions: production, version: .v2Context))
        #expect(mapped == CompactCleanupPrompt.systemText(level: .polished, version: .v2Context))
        let withNote = try #require(CompactCleanupPrompt.systemText(forInstructions: production + SmartCleaner.neighbourContextNote, version: .v2Context))
        #expect(withNote == mapped)
        // Under the plain compact prompt the note rides along as the caller wrote it.
        let plain = try #require(CompactCleanupPrompt.systemText(forInstructions: production + SmartCleaner.neighbourContextNote))
        #expect(plain == CompactCleanupPrompt.systemText(level: .polished) + SmartCleaner.neighbourContextNote)
        let paragraphs = try #require(CompactCleanupPrompt.systemText(forInstructions: production, version: .v2Paragraphs))
        #expect(paragraphs == CompactCleanupPrompt.systemText(level: .polished, version: .v2Paragraphs))
    }

    @Test("the user turn with context lists the sides that have text, and is the plain turn when neither does")
    func contextTurn() {
        #expect(CompactCleanupPrompt.contextUserPrompt(draft: "hi", before: nil, after: nil) == CompactCleanupPrompt.userPrompt(draft: "hi"))
        #expect(CompactCleanupPrompt.contextUserPrompt(draft: "hi", before: " ", after: "") == CompactCleanupPrompt.userPrompt(draft: "hi"))
        #expect(CompactCleanupPrompt.contextUserPrompt(draft: "mid", before: "one two", after: "four five")
            == "Before: one two\nTranscript: mid\nAfter: four five\nOutput:")
        #expect(CompactCleanupPrompt.contextUserPrompt(draft: "mid", before: nil, after: "four") == "Transcript: mid\nAfter: four\nOutput:")
    }
}
