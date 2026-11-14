import Foundation
import Testing
@testable import MurmurCore

@Suite("Line break counts for the log", .timeLimit(.minutes(1)))
struct LineBreakCountTests {
    @Test("paragraph gaps and newlines are counted, never the text", arguments: [
        ("one block of text.", 0, 0),
        ("first.\n\nsecond.", 1, 2),
        ("first.\n\nsecond.\n\nthird.", 2, 4),
        ("a list:\n1. one\n2. two", 0, 2),
        ("gap of three\n\n\nthen text", 1, 3),
        ("windows\r\n\r\nbreaks", 1, 2),
        ("", 0, 0),
    ])
    func counts(_ text: String, _ paragraphs: Int, _ lines: Int) {
        let count = LineBreakCount(of: text)
        #expect(count.paragraphs == paragraphs && count.lines == lines)
        #expect(count.logSummary == "\(paragraphs)/\(lines)")
    }

    @Test("the model's answer is counted on the trace of its group, whether or not it was used")
    func traceHoldsTheAnswerBreaks() async {
        let model = ParagraphModel(answer: "We met on Monday and agreed the plan.\n\nOn Tuesday we started the work.")
        let cleaner = SmartCleaner(model: model, health: ModelHealth())
        let output = await cleaner.clean(
            "we met on monday and agreed the plan on tuesday we started the work",
            options: CleanupOptions(level: .polished), strategy: .model)
        #expect(output.groups.first?.answerBreaks == LineBreakCount(paragraphs: 1, lines: 2))
        let none = await SmartCleaner().clean("we met on monday", options: CleanupOptions(level: .polished), strategy: .rules)
        #expect(none.groups.allSatisfy { $0.answerBreaks == nil })
    }
}

private struct ParagraphModel: LanguageModel {
    let answer: String
    var identifier: String { "synthetic-paragraphs" }
    var availability: LanguageModelAvailability { .available }
    func supportsLanguage(_ languageCode: String) -> Bool { true }
    func prewarm(instructions: String) {}
    func prefixCache(instructions: String) async {}
    func respond(instructions: String, prompt: String, schema: GenerationSchemaSpec, options: LanguageModelOptions) async throws -> String {
        String(decoding: try JSONEncoder().encode(["text": answer]), as: UTF8.self)
    }
}
