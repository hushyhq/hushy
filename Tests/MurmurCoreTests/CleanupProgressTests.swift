import Foundation
import Synchronization
import Testing
@testable import MurmurCore

/// The read-only "sentence finished" notification (`CleanupProgress`) and the timing fields on the
/// per-sentence log line (`GroupTrace.timingFields`). Neither may change what cleanup produces, and
/// neither may carry a word of the dictation.
@Suite("Cleanup progress and per-sentence timings")
struct CleanupProgressTests {
    /// Invented, and long enough to be cleaned in more than one group.
    private func longDictation(sentences: Int = 10) -> String {
        Array(repeating: "Um, so we, uh, need to ship the report by Friday.", count: sentences).joined(separator: " ")
    }

    private final class Recorder: Sendable {
        private let events = Mutex<[CleanupProgress]>([])
        var all: [CleanupProgress] { events.withLock { $0 } }
        func note(_ progress: CleanupProgress) { events.withLock { $0.append(progress) } }
    }

    /// Answers every cleanup call by handing the draft back with one marker word removed.
    private final class EchoModel: LanguageModel {
        var identifier: String { "echo" }
        var availability: LanguageModelAvailability { .available }
        func supportsLanguage(_ languageCode: String) -> Bool { true }
        func prewarm(instructions: String) {}
        func prefixCache(instructions: String) async {}
        func respond(
            instructions: String, prompt: String, schema: GenerationSchemaSpec, options: LanguageModelOptions
        ) async throws -> String {
            guard schema.name == SmartCleaner.Cleaned.generationSchema.name else { throw LanguageModelError.unsupportedSchema(schema.name) }
            let draft = prompt.replacingOccurrences(of: "Transcript: ", with: "").replacingOccurrences(of: "\nOutput:", with: "")
            return String(decoding: try JSONEncoder().encode(["text": draft]), as: UTF8.self)
        }
    }

    @Test("cleanup produces exactly the same result with a listener as without one", arguments: [true, false])
    func identicalWithAndWithoutListener(withModel: Bool) async {
        let raw = longDictation()
        let model: any LanguageModel = withModel ? EchoModel() : NullLanguageModel()
        let plain = await SmartCleaner(model: model).clean(raw, options: CleanupOptions())
        let recorder = Recorder()
        let watched = await SmartCleaner(model: model).clean(raw, options: CleanupOptions(), onProgress: { recorder.note($0) })
        #expect(watched.text == plain.text)
        #expect(watched.pressEnter == plain.pressEnter)
        #expect(watched.usedModel == plain.usedModel)
        #expect(watched.rejection == plain.rejection)
        #expect(watched.speedFallback == plain.speedFallback)
        #expect(watched.groups.map(\.words) == plain.groups.map(\.words))
        #expect(watched.groups.map(\.outcome) == plain.groups.map(\.outcome))
        #expect(!recorder.all.isEmpty, "test setup: this dictation is cleaned group by group")
    }

    @Test("one event before the first sentence, then one per sentence, in order, ending with everything done")
    func eventsInOrder() async throws {
        let raw = longDictation()
        let recorder = Recorder()
        let result = await SmartCleaner(model: NullLanguageModel()).clean(raw, options: CleanupOptions(), onProgress: { recorder.note($0) })
        let events = recorder.all
        let count = result.groups.count
        try #require(count > 1)
        try #require(events.count == count + 1)
        #expect(events.first == CleanupProgress(groupsDone: 0, groupCount: count, wordsDone: 0, wordCount: events[0].wordCount))
        #expect(events.map(\.groupsDone) == Array(0...count))
        #expect(events.allSatisfy { $0.groupCount == count && $0.wordCount == events[0].wordCount })
        #expect(events[0].wordCount == TextSegmentation.groups(raw).reduce(0) { $0 + TextStats.wordCount($1.text) })
        for (earlier, later) in zip(events, events.dropFirst()) {
            #expect(later.wordsDone > earlier.wordsDone, "progress never goes backwards or stands still between sentences")
        }
        #expect(events.last?.wordsDone == events[0].wordCount)
        #expect(events.last?.fraction == 1)
        #expect(events.dropLast().allSatisfy { $0.fraction < 1 })
    }

    @Test("sentences cleaned while the person was still speaking count as done at once")
    func earlyCleanedGroupsCount() async {
        let raw = longDictation()
        let options = CleanupOptions()
        let cleaner = SmartCleaner(model: NullLanguageModel())
        for group in TextSegmentation.groups(raw) where !group.isTail {
            await cleaner.prewarmGroup(group.text, options: options)
        }
        let recorder = Recorder()
        let result = await cleaner.clean(raw, options: options, onProgress: { recorder.note($0) })
        #expect(result.groupSources.contains(.prewarmHit))
        #expect(recorder.all.count == result.groups.count + 1)
        #expect(recorder.all.last?.fraction == 1)
    }

    @Test("a dictation cleaned in one call, or by rules alone, sends nothing: there is no honest fraction")
    func noEventsWithoutGroups() async {
        let recorder = Recorder()
        _ = await SmartCleaner(model: NullLanguageModel()).clean("Lunch on Thursday works for me.", options: CleanupOptions(), onProgress: { recorder.note($0) })
        _ = await SmartCleaner(model: NullLanguageModel()).clean(longDictation(), options: CleanupOptions(), strategy: .rules, onProgress: { recorder.note($0) })
        #expect(recorder.all.isEmpty)
    }

    @Test("the fraction is the share of words settled, and never outside 0 to 1")
    func fraction() {
        #expect(CleanupProgress(groupsDone: 1, groupCount: 4, wordsDone: 20, wordCount: 80).fraction == 0.25)
        #expect(CleanupProgress(groupsDone: 0, groupCount: 0, wordsDone: 0, wordCount: 0).fraction == 0)
        #expect(CleanupProgress(groupsDone: 2, groupCount: 2, wordsDone: 90, wordCount: 80).fraction == 1)
    }

    // MARK: The log line's timing fields

    @Test("the timing fields say where one sentence's time went, in milliseconds")
    func timingFields() {
        let trace = GroupTrace(
            words: 20, outcome: .used, guardCode: nil, edited: true, modelMs: 5_632, retries: 1, secondPass: .kept,
            askedAgain: .passed, retryMs: 410, secondPassMs: 4_950, firstAskMs: 230)
        #expect(trace.checksMs == 5_632 - 230 - 410 - 4_950)
        #expect(trace.timingFields == "firstMs=230 checksMs=42 askAgainMs=410 plainMs=- secondMs=4950 totalMs=5632 retries=1 again=passed second=kept")
    }

    @Test("the plain second ask after a refused register answer is its own field, not counted as checks")
    func timingFieldsWithPlainRetry() {
        var trace = GroupTrace(words: 17, outcome: .used, guardCode: nil, edited: true, modelMs: 2_953, firstAskMs: 920)
        trace.plainRetryMs = 2_010
        #expect(trace.checksMs == 23)
        #expect(trace.timingFields == "firstMs=920 checksMs=23 askAgainMs=- plainMs=2010 secondMs=- totalMs=2953 retries=0 again=none second=none")
    }

    @Test("a step that did not run prints a dash, and a sentence the model never saw prints all dashes")
    func timingFieldsWhenStepsDidNotRun() {
        let plain = GroupTrace(words: 12, outcome: .used, guardCode: nil, edited: false, modelMs: 220, firstAskMs: 200)
        #expect(plain.timingFields == "firstMs=200 checksMs=20 askAgainMs=- plainMs=- secondMs=- totalMs=220 retries=0 again=none second=none")
        let notAsked = GroupTrace(words: 12, outcome: .notAsked, guardCode: nil, edited: false, modelMs: nil)
        #expect(notAsked.checksMs == nil)
        #expect(notAsked.timingFields == "firstMs=- checksMs=- askAgainMs=- plainMs=- secondMs=- totalMs=- retries=0 again=none second=none")
    }

    @Test("the timing fields are numbers and fixed words only: never a word of the dictation")
    func timingFieldsCarryNoText() {
        let trace = GroupTrace(
            words: 9, outcome: .rejectedByGuard, guardCode: nil, edited: false, modelMs: 300,
            rejectedCandidate: "the quarterly numbers are confidential", firstAskMs: 250)
        let fields = trace.timingFields
        for word in ["quarterly", "numbers", "confidential"] { #expect(!fields.contains(word)) }
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzAM0123456789=- ")
        #expect(fields.unicodeScalars.allSatisfy(allowed.contains))
        let keys = fields.split(separator: " ").map { $0.split(separator: "=").first.map(String.init) ?? "" }
        #expect(keys == ["firstMs", "checksMs", "askAgainMs", "plainMs", "secondMs", "totalMs", "retries", "again", "second"])
    }

    @Test("a second pass keeps the first ask's time and adds its own")
    func secondPassKeepsFirstAsk() {
        let first = GroupTrace(words: 18, outcome: .used, guardCode: nil, edited: true, modelMs: 240, firstAskMs: 210)
        let after = first.afterSecondPass(.used, took: .milliseconds(3_000), widenedOnly: false)
        #expect(after.firstAskMs == 210)
        #expect(after.secondPassMs == 3_000)
        #expect(after.modelMs == 3_240)
        #expect(after.checksMs == 30)
        #expect(after.with(source: .fresh).firstAskMs == 210)
    }
}
