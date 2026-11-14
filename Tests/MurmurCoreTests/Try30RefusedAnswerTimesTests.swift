import Foundation
import Testing
@testable import MurmurCore

private struct TimesTranscriber: Transcriber {
    let text: String
    func transcribe(_ samples: [Float]) async throws -> String { text }
}

private struct ScriptedTimesModel: LanguageModel {
    enum Behaviour: Sendable {
        case refuse
        case fail
        case answer(String)
    }

    let behaviour: Behaviour
    var identifier: String { "scripted-times" }
    var availability: LanguageModelAvailability { .available }
    func supportsLanguage(_ languageCode: String) -> Bool { true }
    func prewarm(instructions: String) {}
    func prefixCache(instructions: String) async {}
    func respond(
        instructions: String, prompt: String, schema: GenerationSchemaSpec, options: LanguageModelOptions
    ) async throws -> String {
        switch behaviour {
        case .refuse: throw LanguageModelError.refused("scripted")
        case .fail: throw LanguageModelError.malformedOutput("scripted")
        case .answer(let text): return String(decoding: try JSONEncoder().encode(["text": text]), as: UTF8.self)
        }
    }
}

/// TRY-30: a clock time with evidence is written as typed whichever way the model call ends. A refused,
/// failed or guard-rejected answer falls back to the rules draft, which must already hold the typed time.
@Suite("TRY-30 clock times when the model answer is refused")
struct Try30RefusedAnswerTimesTests {
    private func run(_ raw: String, behaviour: ScriptedTimesModel.Behaviour, whole: Bool) async -> PipelineResult {
        let cleaner = SmartCleaner(
            model: ScriptedTimesModel(behaviour: behaviour), health: ModelHealth(), wholeTranscript: { whole })
        let pipeline = DictationPipeline(transcriber: TimesTranscriber(text: raw), cleaner: cleaner)
        return await pipeline.clean(raw, settings: PipelineSettings(cleanupOptions: CleanupOptions(level: .polished)))
    }

    private static let cases: [(raw: String, expected: String)] = [
        ("The standup moved to nine fifteen in the morning.", "The standup moved to 9:15 in the morning."),
        ("Let's call it a day at three thirty this afternoon.", "Let's call it a day at 3:30 this afternoon."),
        ("Ping the on-call at ten pm if it's still down.", "Ping the on-call at 10:00pm if it's still down."),
        ("Meet at ten thirty tomorrow.", "Meet at 10:30 tomorrow."),
    ]

    @Test("a refused model call keeps the typed time", arguments: [true, false])
    func refusedCall(whole: Bool) async {
        for (raw, expected) in Self.cases {
            let result = await run(raw, behaviour: .refuse, whole: whole)
            #expect(result.text == expected, "whole=\(whole) rejection=\(String(describing: result.rejection))")
        }
    }

    @Test("a failed model call keeps the typed time", arguments: [true, false])
    func failedCall(whole: Bool) async {
        for (raw, expected) in Self.cases {
            let result = await run(raw, behaviour: .fail, whole: whole)
            #expect(result.text == expected, "whole=\(whole) rejection=\(String(describing: result.rejection))")
        }
    }

    @Test("an answer the guards reject keeps the typed time", arguments: [true, false])
    func rejectedAnswer(whole: Bool) async {
        for (raw, expected) in Self.cases {
            let reply = "I'm sorry, I can't help with that request."
            let result = await run(raw, behaviour: .answer(reply), whole: whole)
            #expect(result.text == expected, "whole=\(whole) rejection=\(String(describing: result.rejection))")
        }
    }

    @Test("an answer that kept the time as words is written as typed", arguments: [true, false])
    func answerKeptWords(whole: Bool) async {
        for (raw, expected) in Self.cases {
            let result = await run(raw, behaviour: .answer(raw), whole: whole)
            #expect(result.text == expected, "whole=\(whole) rejection=\(String(describing: result.rejection))")
        }
    }
}
