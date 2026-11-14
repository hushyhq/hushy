import Foundation
import Testing
@testable import MurmurCore

/// A Dictionary or learned replacement must be idempotent: applied to text that already reads as the term it changes
/// nothing. A term that contains its own heard phrase (the name, then the name plus an ending) used to be written again
/// by the replacement, because a "." counts as the end of a word. Invented names only.
private let day: TimeInterval = 86_400
private let start = Date(timeIntervalSince1970: 1_800_000_000)

private func learned(heard: String, meant: String) -> [LearnedItem] {
    var items: [LearnedItem] = []
    for (id, offset) in [(Int64(1), 0.0), (2, day)] {
        let capture = CorrectionCapture(
            dictationID: id, appBundleID: "com.apple.mail", capturedAt: start.addingTimeInterval(offset),
            events: [CorrectionEvent(kind: .asrTerm, before: heard, after: meant)])
        let changed = Learner.observe(capture, existing: items, knownTerms: [], policy: LearningPolicy(autoActivateTerms: true))
        let ids = Set(changed.map(\.identity))
        items = items.filter { !ids.contains($0.identity) } + changed
    }
    return items
}

private struct Shape {
    let name: String
    let term: String
    let heard: String
    /// Text where the heard phrase stands alone, and text that already reads as the term.
    let spoken: String
    let alreadyTerm: String
}

private let shapes = [
    Shape(name: "prefix, one word", term: "jimmylord.com", heard: "jimmylord", spoken: "go to jimmylord today", alreadyTerm: "go to jimmylord.com today"),
    Shape(name: "prefix, two words", term: "jimmylord.com", heard: "jimmy lord", spoken: "go to jimmy lord today", alreadyTerm: "go to jimmylord.com today"),
    Shape(name: "prefix, two words, spoken as written", term: "jimmylord.com", heard: "jimmy lord", spoken: "go to jimmy lord today", alreadyTerm: "go to jimmy lord.com today"),
    Shape(name: "suffix", term: "mail.danapike.org", heard: "danapike.org", spoken: "write to danapike.org today", alreadyTerm: "write to mail.danapike.org today"),
    Shape(name: "middle", term: "www.miraholt.com", heard: "miraholt", spoken: "go to miraholt today", alreadyTerm: "go to www.miraholt.com today"),
]

@Suite("Replacement idempotence", .timeLimit(.minutes(1)))
struct ReplacementIdempotenceTests {
    private func personalizers(_ shape: Shape) -> [(String, Personalizer)] {
        let entry = DictionaryEntry(term: shape.term, soundsLike: [shape.heard])
        let plain = DictionaryEntry(term: shape.term)
        return [
            ("dictionary sounds-like", Personalizer(dictionary: [entry])),
            ("learned", LearnedPersonalization.personalizer(dictionary: [], snippets: [], learned: learned(heard: shape.heard, meant: shape.term))),
            ("learned merged into a dictionary entry", LearnedPersonalization.personalizer(
                dictionary: [plain], snippets: [], learned: learned(heard: shape.heard, meant: shape.term))),
        ]
    }

    @Test("text that already reads as the term gets it written once, never again", arguments: shapes.indices)
    func alreadyTheTermIsWrittenOnce(index: Int) {
        let shape = shapes[index]
        for (source, personalizer) in personalizers(shape) {
            for text in [shape.alreadyTerm, shape.alreadyTerm.capitalized, shape.alreadyTerm + ".", shape.term, shape.term + "."] {
                let out = personalizer.apply(text).text
                #expect(RepeatTrace(out).longestRun <= RepeatTrace(text).longestRun, "\(shape.name) / \(source): \(text) -> \(out)")
                #expect(out.components(separatedBy: shape.term).count == 2, "\(shape.name) / \(source): \(text) -> \(out)")
            }
        }
    }

    @Test("text that is exactly the term is not counted as a fix", arguments: shapes.indices)
    func exactTermIsNotAFix(index: Int) {
        let shape = shapes[index]
        for (_, personalizer) in personalizers(shape) {
            let output = personalizer.apply("go to \(shape.term) today")
            #expect(output.text == "go to \(shape.term) today")
            #expect(output.dictionaryFixes == 0)
        }
    }

    @Test("the heard phrase alone becomes the term once", arguments: shapes.indices)
    func heardBecomesTermOnce(index: Int) {
        let shape = shapes[index]
        for (source, personalizer) in personalizers(shape) {
            let out = personalizer.apply(shape.spoken).text
            #expect(out.components(separatedBy: shape.term).count == 2, "\(shape.name) / \(source): \(shape.spoken) -> \(out)")
        }
    }

    @Test("applying a replacement to its own output changes nothing", arguments: shapes.indices)
    func idempotent(index: Int) {
        let shape = shapes[index]
        for (source, personalizer) in personalizers(shape) {
            for text in [shape.spoken, shape.alreadyTerm, shape.heard, shape.heard + ".", shape.heard.capitalized + ".com."] {
                let once = personalizer.apply(text).text
                let twice = personalizer.apply(once).text
                #expect(once == twice, "\(shape.name) / \(source): \(text) -> \(once) -> \(twice)")
            }
        }
    }

    @Test("the whole cleanup, with a scripted answer, writes the term once")
    func throughTheCleaner() async {
        for shape in shapes {
            for (source, personalizer) in personalizers(shape) {
                let answer = shape.spoken.prefix(1).uppercased() + shape.spoken.dropFirst() + "."
                let model = ScriptedAnswer(json: "{\"text\": \"\(answer)\"}")
                let output = await SmartCleaner(model: model, health: ModelHealth())
                    .clean(shape.spoken, options: CleanupOptions(level: .clean), personalizer: personalizer)
                #expect(output.text.components(separatedBy: shape.term).count == 2, "\(shape.name) / \(source): \(output.text)")
            }
        }
    }
}

private final class ScriptedAnswer: LanguageModel {
    private let json: String
    init(json: String) { self.json = json }
    var identifier: String { "scripted" }
    var availability: LanguageModelAvailability { .available }
    func supportsLanguage(_ languageCode: String) -> Bool { true }
    func prewarm(instructions: String) {}
    func prefixCache(instructions: String) async {}
    func respond(
        instructions: String, prompt: String, schema: GenerationSchemaSpec, options: LanguageModelOptions
    ) async throws -> String { json }
}
