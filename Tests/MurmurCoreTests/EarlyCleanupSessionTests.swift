import Foundation
import Synchronization
import Testing
@testable import MurmurCore

/// The session that hears a recording while it is still going and has its closed sentence groups cleaned
/// (`EarlyCleanupSession`), driven here with a scripted recogniser and a scripted model.
@Suite("Early cleanup: the while-speaking session", .timeLimit(.minutes(1)), .serialized)
struct EarlyCleanupSessionTests {
    /// Ten words each: two make a group.
    private let sentences = (1...6).map { "The report for region number \($0) is ready for review." }
    private var final: String { sentences.joined(separator: " ") }
    private let settings = PipelineSettings(cleanupOptions: CleanupOptions(level: .polished))
    private let second = [Float](repeating: 0.01, count: 16_000)

    private func pipeline(_ model: SessionModel) -> DictationPipeline {
        let budget: Duration = .seconds(5)
        return DictationPipeline(
            transcriber: SilentTranscriber(),
            cleaner: SmartCleaner(
                budget: budget, correctionBudget: budget, polishedBudget: budget, segmentBudget: budget,
                model: model, health: ModelHealth()))
    }

    /// A recogniser that has heard one more sentence for every two seconds of audio.
    private func recogniser(_ heard: SessionRecogniser) -> EarlyCleanupSession.Recognise {
        { samples in try await heard.transcribe(samples) }
    }

    private func feed(_ session: EarlyCleanupSession, seconds: Int) async {
        for _ in 0..<(seconds / 2) {
            await session.add(second + second)
            await session.settle()
        }
    }

    @Test("a dictation shorter than the first-pass time never runs the recogniser early")
    func shortDictationCostsNothing() async {
        let heard = SessionRecogniser(sentences)
        let model = SessionModel()
        let session = EarlyCleanupSession(
            pipeline: pipeline(model), settings: settings, detectsLanguage: false, recognise: recogniser(heard))
        await feed(session, seconds: 8)
        session.close()
        #expect(heard.calls == 0)
        #expect(model.calls == 0)
    }

    @Test("closed groups are cleaned while the recording goes on, and the release reuses them with the same text")
    func cleansClosedGroupsAndReleaseReusesThem() async {
        let reference = await pipeline(SessionModel()).clean(final, settings: settings)
        let heard = SessionRecogniser(sentences)
        let model = SessionModel()
        let subject = pipeline(model)
        let session = EarlyCleanupSession(
            pipeline: subject, settings: settings, detectsLanguage: false,
            schedule: EarlyPassSchedule(first: 2, gap: 2, stretch: 0), recognise: recogniser(heard))
        await feed(session, seconds: 12)
        session.close()
        // Six sentences heard by twelve seconds: two closed groups, the last group left alone.
        #expect(await session.groupsStarted == 2)
        #expect(model.calls == 2)
        let output = await subject.clean(final, settings: settings)
        #expect(output.text == reference.text)
        #expect(output.groupSources == [.prewarmHit, .prewarmHit, .fresh])
        #expect(output.early == EarlyCleanupTally(started: 2, used: 2))
        #expect(model.calls == 3)
    }

    @Test("after the release no pass starts and no group is cleaned, whatever audio still arrives")
    func nothingAfterTheRelease() async {
        let heard = SessionRecogniser(sentences)
        let model = SessionModel()
        let session = EarlyCleanupSession(
            pipeline: pipeline(model), settings: settings, detectsLanguage: false,
            schedule: EarlyPassSchedule(first: 2, gap: 2, stretch: 0), recognise: recogniser(heard))
        await feed(session, seconds: 4)
        session.close()
        let passes = heard.calls
        await feed(session, seconds: 12)
        #expect(heard.calls == passes)
        #expect(model.calls == 0)
    }

    @Test("a pass that finishes after the release is not acted on")
    func latePassIsDropped() async {
        let heard = SessionRecogniser(sentences, delay: .milliseconds(200), from: 10)
        let model = SessionModel()
        let session = EarlyCleanupSession(
            pipeline: pipeline(model), settings: settings, detectsLanguage: false,
            schedule: EarlyPassSchedule(first: 2, gap: 2, stretch: 0), recognise: recogniser(heard))
        // Eight seconds: four sentences, nothing closed yet. The pass at ten seconds is slow and the key comes up under it.
        await feed(session, seconds: 8)
        await session.add(second + second)
        session.close()
        await session.settle()
        #expect(heard.calls == 5)
        #expect(await session.groupsStarted == 0)
        #expect(model.calls == 0)
    }

    @Test("ending the session drops what it had cleaned ahead, and only that")
    func endDropsItsOwnEarlyWork() async {
        let heard = SessionRecogniser(sentences)
        let model = SessionModel()
        let subject = pipeline(model)
        let session = EarlyCleanupSession(
            pipeline: subject, settings: settings, detectsLanguage: false,
            schedule: EarlyPassSchedule(first: 2, gap: 2, stretch: 0), recognise: recogniser(heard))
        await feed(session, seconds: 12)
        session.close()
        await session.end()
        let output = await subject.clean(final, settings: settings)
        #expect(output.groupSources == [.fresh, .fresh, .fresh])
        #expect(output.early == nil)
    }

    @Test("never two recogniser passes at once")
    func oneRecogniserPassAtATime() async {
        let heard = SessionRecogniser(sentences, delay: .milliseconds(80))
        let session = EarlyCleanupSession(
            pipeline: pipeline(SessionModel()), settings: settings, detectsLanguage: false,
            schedule: EarlyPassSchedule(first: 2, gap: 2, stretch: 0), recognise: recogniser(heard))
        for _ in 0..<6 { await session.add(second + second) }
        await session.settle()
        session.close()
        #expect(heard.mostAtOnce == 1)
        #expect(heard.calls >= 1)
    }

    @Test("a setting that asks no model starts no pass")
    func rulesOnlySettingDoesNothing() async {
        let heard = SessionRecogniser(sentences)
        let asSpoken = PipelineSettings(cleanupOptions: CleanupOptions(level: .verbatim))
        let session = EarlyCleanupSession(
            pipeline: pipeline(SessionModel()), settings: asSpoken, detectsLanguage: false,
            schedule: EarlyPassSchedule(first: 2, gap: 2, stretch: 0), recognise: recogniser(heard))
        await feed(session, seconds: 12)
        session.close()
        #expect(heard.calls == 0)
    }

    @Test("a recogniser that fails costs nothing but the pass")
    func failingRecogniser() async {
        let heard = SessionRecogniser(sentences, fails: true)
        let model = SessionModel()
        let session = EarlyCleanupSession(
            pipeline: pipeline(model), settings: settings, detectsLanguage: false,
            schedule: EarlyPassSchedule(first: 2, gap: 2, stretch: 0), recognise: recogniser(heard))
        await feed(session, seconds: 8)
        session.close()
        #expect(heard.calls == 4)
        #expect(model.calls == 0)
    }
}

private struct SilentTranscriber: Transcriber {
    func transcribe(_ samples: [Float]) async throws -> String { "" }
}

private struct ScriptedFailure: Error {}

/// Hears one more sentence for every two seconds of audio it is given.
private final class SessionRecogniser: Sendable {
    private let sentences: [String]
    private let delay: Duration
    private let slowFrom: Int
    private let fails: Bool
    private let state = Mutex((calls: 0, running: 0, most: 0))

    init(_ sentences: [String], delay: Duration = .zero, from slowFrom: Int = 0, fails: Bool = false) {
        self.sentences = sentences
        self.delay = delay
        self.slowFrom = slowFrom
        self.fails = fails
    }

    var calls: Int { state.withLock { $0.calls } }
    var mostAtOnce: Int { state.withLock { $0.most } }

    func transcribe(_ samples: [Float]) async throws -> String {
        state.withLock {
            $0.calls += 1
            $0.running += 1
            $0.most = max($0.most, $0.running)
        }
        defer { state.withLock { $0.running -= 1 } }
        let seconds = samples.count / 16_000
        if delay > .zero, seconds >= slowFrom { try await Task.sleep(for: delay) }
        if fails { throw ScriptedFailure() }
        return sentences.prefix(seconds / 2).joined(separator: " ")
    }
}

private final class SessionModel: LanguageModel {
    private let count = Mutex(0)
    var calls: Int { count.withLock { $0 } }
    var identifier: String { "first" }
    var availability: LanguageModelAvailability { .available }
    func supportsLanguage(_ languageCode: String) -> Bool { true }
    func prewarm(instructions: String) {}
    func prefixCache(instructions: String) async {}

    func respond(
        instructions: String, prompt: String, schema: GenerationSchemaSpec, options: LanguageModelOptions
    ) async throws -> String {
        guard schema.name == SmartCleaner.Cleaned.generationSchema.name else { throw LanguageModelError.unsupportedSchema(schema.name) }
        count.withLock { $0 += 1 }
        let draft = prompt.replacingOccurrences(of: "Transcript: ", with: "").replacingOccurrences(of: "\nOutput:", with: "")
        return String(decoding: try JSONEncoder().encode(["text": draft]), as: UTF8.self)
    }
}
