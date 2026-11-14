import Foundation
import Testing
@testable import MurmurCore

/// A small model can loop on a short token and write the same ending over and over ("lordcom.com.com.com.").
/// Measured 2026-10-10: the existing checks already refuse such an answer for a spoken address, at both levels, so a
/// repeat born in the model is not what reaches the page. These pin that, and `RepeatTrace` names the stage if one does.
@Suite("Looped address answers", .timeLimit(.minutes(1)))
struct LoopedAddressAnswerTests {
    private static let loops = [
        ("Jimmy lord com.", "Jimmy lordcom.com.com.com."),
        ("Jimmy lord com", "Jimmy lordcom.com.com.com."),
        ("Jimmy lord.com.", "Jimmy lord.com.com.com.com."),
        ("Jimmy lord dot com.", "Jimmy lord.com.com.com.com."),
        ("open dana pike dot com please", "Open dana pike.com.com.com please."),
        ("tell mira holt dot org", "Tell mira holt.org.org.org."),
    ]

    @Test("a looped ending is refused at every level", arguments: [OutputGuard.Profile.disfluencyOnly, .localGrammar, .grammarRepair])
    func refusesLoopedEnding(profile: OutputGuard.Profile) {
        for (draft, answer) in Self.loops {
            let verdict = OutputGuard.check(answer, raw: draft, draft: draft, profile: profile)
            guard case .rejected(let reason) = verdict else {
                Issue.record("accepted \(draft) -> \(answer)")
                continue
            }
            #expect(GuardCode(reason: reason) == .changedCodeText, "\(draft) -> \(answer): \(reason)")
        }
    }

    @Test("a looped answer through the cleaner leaves the plain text, at both levels", arguments: [CleanupLevel.clean, .polished])
    func throughTheCleaner(level: CleanupLevel) async {
        for (draft, answer) in Self.loops {
            let model = LoopingModel(json: "{\"text\": \"\(answer)\"}")
            let output = await SmartCleaner(model: model, health: ModelHealth())
                .clean(draft, options: CleanupOptions(level: level))
            #expect(RepeatTrace(output.text).longestRun <= RepeatTrace(draft).longestRun, "\(draft) -> \(output.text)")
        }
    }

    @Test("a repeat the speaker said stays out of the way of the check")
    func spokenRepeatsAreNotRefused() {
        for (draft, answer) in [
            ("we we need the the report", "We need the report."),
            ("it was so so good", "It was so so good."),
            ("go to example dot com", "Go to example.com."),
            ("call 555 555 1234", "Call 555 555 1234."),
        ] {
            if case .rejected(let reason) = OutputGuard.check(answer, raw: draft, draft: draft) {
                Issue.record("refused \(draft) -> \(answer): \(reason)")
            }
        }
    }
}

@Suite("Repeat trace")
struct RepeatTraceTests {
    @Test("counts words and the longest run of one word, ignoring case and punctuation")
    func counts() {
        let trace = RepeatTrace("Jimmy lordcom.com.COM.com.")
        #expect(trace.tokens == 5)
        #expect(trace.longestRun == 3)
        #expect(RepeatTrace("").longestRun == 0)
        #expect(RepeatTrace("one two three").longestRun == 1)
        #expect(RepeatTrace("had had enough").longestRun == 2)
    }

    @Test("a stage is named only when it made a word repeat further than its input did")
    func addedOnlyWhenGrown() {
        let input = RepeatTrace("Jimmy lord com.")
        #expect(RepeatTrace.added(from: input, to: RepeatTrace("Jimmy lordcom.com.com.com.")))
        #expect(!RepeatTrace.added(from: input, to: RepeatTrace("Jimmy lord.com.")))
        #expect(!RepeatTrace.added(from: RepeatTrace("had had enough"), to: RepeatTrace("had had enough.")))
        #expect(RepeatTrace.added(from: RepeatTrace("so"), to: RepeatTrace("so so")))
    }

    @Test("text that already repeats three times is flagged as the recogniser's")
    func loopedRecogniserText() {
        #expect(RepeatTrace("Jimmy lordcom.com.com.com.").isLoopedRecogniserText)
        #expect(!RepeatTrace("very very cold").isLoopedRecogniserText)
    }

    @Test("a log line holds a stage name and counts, never the words")
    func lineHasNoWords() {
        let line = RepeatTrace.line(stage: "model", from: RepeatTrace("Jimmy lord com."), to: RepeatTrace("Jimmy lordcom.com.com.com."))
        #expect(line == "repeat_added stage=model words=3->5 longest_run=1->3")
        #expect(!line.lowercased().contains("jimmy") && !line.lowercased().contains("lord"))
        let looped = RepeatTrace.looped(stage: "recogniser", RepeatTrace("Jimmy lordcom.com.com.com."))
        #expect(looped == "repeat_in_input stage=recogniser words=5 longest_run=3")
    }
}

private final class LoopingModel: LanguageModel {
    private let json: String
    init(json: String) { self.json = json }
    var identifier: String { "looping" }
    var availability: LanguageModelAvailability { .available }
    func supportsLanguage(_ languageCode: String) -> Bool { true }
    func prewarm(instructions: String) {}
    func prefixCache(instructions: String) async {}
    func respond(
        instructions: String, prompt: String, schema: GenerationSchemaSpec, options: LanguageModelOptions
    ) async throws -> String { json }
}
