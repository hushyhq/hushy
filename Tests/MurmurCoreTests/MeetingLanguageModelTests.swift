import Foundation
import Synchronization
import Testing
@testable import MurmurCore

/// Answers the three summary schemas; can fail every call, and records what it was asked and when.
private final class DigestFake: LanguageModel {
    let name: String
    let contextTokens: Int
    let failsAlways: Bool
    private let log = Mutex<[(schema: String, at: ContinuousClock.Instant, background: Bool)]>([])
    private let onCall: (@Sendable () -> Void)?

    init(_ name: String, contextTokens: Int, failsAlways: Bool = false, onCall: (@Sendable () -> Void)? = nil) {
        self.name = name
        self.contextTokens = contextTokens
        self.failsAlways = failsAlways
        self.onCall = onCall
    }

    var calls: Int { log.withLock { $0.count } }
    var times: [ContinuousClock.Instant] { log.withLock { $0.map(\.at) } }
    /// `LanguageModelOptions.isBackground` of each call, in order.
    var background: [Bool] { log.withLock { $0.map(\.background) } }
    var identifier: String { name }
    var availability: LanguageModelAvailability { .available }
    func supportsLanguage(_ languageCode: String) -> Bool { true }
    func prewarm(instructions: String) {}
    func prefixCache(instructions: String) async {}

    func respond(instructions: String, prompt: String, schema: GenerationSchemaSpec, options: LanguageModelOptions) async throws -> String {
        log.withLock { $0.append((schema.name, ContinuousClock.now, options.isBackground)) }
        onCall?()
        if failsAlways { throw LanguageModelError.malformedOutput("scripted") }
        switch schema.name {
        case "MeetingPartNotes":
            return #"{"speakers":[],"decisions":[],"actionItems":[{"owner":"Priya","task":"Task from \#(name)","due":""}],"changes":[],"keyPoints":["Point"]}"#
        case "MeetingMerge":
            return #"{"title":"Merged by \#(name)","keyPoints":["All"],"decisions":[],"dropItems":[],"updates":[]}"#
        default:
            return #"{"title":"Merged by \#(name)","keyPoints":["All"],"decisions":[],"actionItems":[{"owner":"Priya","task":"Task","due":""}]}"#
        }
    }
}

/// A model whose first `hanging` calls run until cancelled (a long decode that honours cancellation), then answers
/// after `answerAfter`.
private final class LongDecodeFake: LanguageModel {
    private let hanging: Int
    private let answerAfter: Duration

    init(hanging: Int = 1, answerAfter: Duration = .zero) {
        self.hanging = hanging
        self.answerAfter = answerAfter
    }

    private let counters = Mutex((started: 0, cancelled: 0))
    var started: Int { counters.withLock { $0.started } }
    var cancelled: Int { counters.withLock { $0.cancelled } }
    var contextTokens: Int { 262_144 }
    var identifier: String { "long-decode" }
    var availability: LanguageModelAvailability { .available }
    func supportsLanguage(_ languageCode: String) -> Bool { true }
    func prewarm(instructions: String) {}
    func prefixCache(instructions: String) async {}

    func respond(instructions: String, prompt: String, schema: GenerationSchemaSpec, options: LanguageModelOptions) async throws -> String {
        let number = counters.withLock { state -> Int in state.started += 1; return state.started }
        if number <= hanging {
            do { try await Task.sleep(for: .seconds(30)) } catch {
                counters.withLock { $0.cancelled += 1 }
                throw CancellationError()
            }
        }
        try await Task.sleep(for: answerAfter)
        return #"{"title":"Merged by long-decode","keyPoints":["All"],"decisions":[],"actionItems":[{"owner":"Priya","task":"Task","due":""}]}"#
    }
}

/// Every odd-numbered call runs until cancelled (a dictation cuts it short); every even-numbered one is answered by
/// `answers`.
private final class CutShortEveryOtherFake: LanguageModel {
    private let answers: DigestFake
    private let counters = Mutex((started: 0, cancelled: 0))
    var started: Int { counters.withLock { $0.started } }
    var cancelled: Int { counters.withLock { $0.cancelled } }

    init(answers: DigestFake) { self.answers = answers }

    var contextTokens: Int { answers.contextTokens }
    var identifier: String { answers.identifier }
    var availability: LanguageModelAvailability { .available }
    func supportsLanguage(_ languageCode: String) -> Bool { true }
    func prewarm(instructions: String) {}
    func prefixCache(instructions: String) async {}

    func respond(instructions: String, prompt: String, schema: GenerationSchemaSpec, options: LanguageModelOptions) async throws -> String {
        let number = counters.withLock { state -> Int in state.started += 1; return state.started }
        if number % 2 == 1 {
            do { try await Task.sleep(for: .seconds(30)) } catch {
                counters.withLock { $0.cancelled += 1 }
                throw CancellationError()
            }
        }
        return try await answers.respond(instructions: instructions, prompt: prompt, schema: schema, options: options)
    }
}

@Suite("Meeting summaries on the cleanup model")
struct MeetingLanguageModelTests {
    static let fourB = EffectiveCleanupBackend.local(ModelRegistry.hushyCleanup4B)
    static let longTranscript = TranscriptChunkerTests.meeting(turns: 200)  // 4,000 words

    private func meeting(shared: DigestFake, apple: DigestFake, poll: Duration = .milliseconds(5))
        -> (MeetingLanguageModel, ForegroundActivity) {
        let activity = ForegroundActivity()
        return (MeetingLanguageModel(shared: shared, apple: apple, activity: activity, pollInterval: poll), activity)
    }

    // MARK: Which model

    @Test("only the local 4B shares its instance with meetings; the 2B, Apple FM and rules do not", arguments: [
        (EffectiveCleanupBackend.local(ModelRegistry.hushyCleanup4B), true),
        (.local(ModelRegistry.hushyCleanup2BIntent), false),
        (.local(ModelRegistry.hushyCleanup2B), false),
        (.local(ModelRegistry.qwen08B4bit), false),
        (.apple, false),
        (.rules, false),
    ])
    func rule(backend: EffectiveCleanupBackend, expected: Bool) {
        #expect(ModelTierPolicy.meetingUsesCleanupModel(backend) == expected)
    }

    @Test("routed to the 4B, every summary call goes to the shared instance and none to Apple FM")
    func sharedInstance() async {
        let shared = DigestFake("four-b", contextTokens: 262_144), apple = DigestFake("apple", contextTokens: 4_096)
        let (model, _) = meeting(shared: shared, apple: apple)
        model.route(for: Self.fourB)
        let (output, report) = await NoteSummarizer.summarize(Self.longTranscript, fallbackTitle: "Note", model: model)
        #expect(model.route == .sharedLocal)
        #expect(report.strategy == .mapReduce)
        #expect(report.pieces == 2, "a 262k window means 3,000-word pieces, as in the eval")
        #expect(output.title == "Merged by four-b")
        #expect(shared.calls == 3 && apple.calls == 0)
        #expect(!report.reranOnApple)
    }

    @Test("routed anywhere else, summaries use Apple FM, as before this change", arguments: [
        EffectiveCleanupBackend.local(ModelRegistry.hushyCleanup2BIntent), .apple, .rules,
    ])
    func appleRoute(backend: EffectiveCleanupBackend) async {
        let shared = DigestFake("shared", contextTokens: 262_144), apple = DigestFake("apple", contextTokens: 4_096)
        let (model, _) = meeting(shared: shared, apple: apple)
        model.route(for: .local(ModelRegistry.hushyCleanup4B))
        model.route(for: backend)
        let (output, report) = await NoteSummarizer.summarize(Self.longTranscript, fallbackTitle: "Note", model: model)
        #expect(model.route == .apple)
        #expect(output.title == "Merged by apple")
        #expect(report.pieces == 3, "Apple FM's 4,096 window means 1,500-word pieces")
        #expect(shared.calls == 0)
        #expect(model.appleFallback == nil)
    }

    // MARK: When the 4B fails

    @Test("when the 4B cannot answer, the whole summary runs again on Apple FM and its digest is kept")
    func fallsBackToApple() async {
        let shared = DigestFake("four-b", contextTokens: 262_144, failsAlways: true)
        let apple = DigestFake("apple", contextTokens: 4_096)
        let (model, _) = meeting(shared: shared, apple: apple)
        model.route(for: Self.fourB)
        let (output, report) = await NoteSummarizer.summarize(Self.longTranscript, fallbackTitle: "Note", model: model)
        #expect(report.reranOnApple)
        #expect(output.title == "Merged by apple")
        #expect(output.actionItems.contains("Priya: Task from apple"))
        #expect(apple.calls > 0 && shared.calls > 0)
    }

    @Test("when neither model can answer, the note gets the extractive summary")
    func fallsBackToExtractive() async {
        let shared = DigestFake("four-b", contextTokens: 262_144, failsAlways: true)
        let apple = DigestFake("apple", contextTokens: 4_096, failsAlways: true)
        let (model, _) = meeting(shared: shared, apple: apple)
        model.route(for: Self.fourB)
        let (output, report) = await NoteSummarizer.summarize(Self.longTranscript, fallbackTitle: "Note", model: model)
        #expect(report.extractiveOnly)
        #expect(!output.title.isEmpty)
    }

    @Test("a short note that the 4B answers is not run twice")
    func noRerunWhenFine() async {
        let shared = DigestFake("four-b", contextTokens: 262_144), apple = DigestFake("apple", contextTokens: 4_096)
        let (model, _) = meeting(shared: shared, apple: apple)
        model.route(for: Self.fourB)
        _ = await NoteSummarizer.summarize(TranscriptChunkerTests.meeting(turns: 40), fallbackTitle: "Note", model: model)
        #expect(apple.calls == 0 && shared.calls == 1)
    }

    // MARK: Dictation first

    @Test("summary calls reach the shared 4B as background work, which the 4B stops without a trace when a dictation cuts it short")
    func callsAreBackgroundWork() async {
        let shared = DigestFake("four-b", contextTokens: 262_144), apple = DigestFake("apple", contextTokens: 4_096)
        let (model, _) = meeting(shared: shared, apple: apple)
        model.route(for: Self.fourB)
        _ = await NoteSummarizer.summarize(Self.longTranscript, fallbackTitle: "Note", model: model)
        #expect(shared.background == [true, true, true], "both pieces and the merge")
    }

    @Test("a summary call waits while a dictation is in progress, and the wait does not use up its budget")
    func waitsForDictation() async {
        let shared = DigestFake("four-b", contextTokens: 262_144), apple = DigestFake("apple", contextTokens: 4_096)
        let (model, activity) = meeting(shared: shared, apple: apple)
        model.route(for: Self.fourB)
        activity.set(busy: true)
        var configuration = NoteSummarizer.Configuration()
        configuration.callBudget = .milliseconds(100)
        let transcript = TranscriptChunkerTests.meeting(turns: 40)
        let summary = Task { await NoteSummarizer.summarize(transcript, fallbackTitle: "Note", model: model, configuration: configuration) }
        try? await Task.sleep(for: .milliseconds(300))
        #expect(shared.calls == 0, "the dictation goes first")
        activity.set(busy: false)
        let (output, report) = await summary.value
        #expect(shared.calls == 1)
        #expect(report.failures.isEmpty, "300 ms of waiting did not time the 100 ms call out")
        #expect(output.title == "Merged by four-b")
    }

    @Test("once a dictation has started, no further summary call starts until it is over")
    func yieldsBetweenPieces() async {
        let activity = ForegroundActivity()
        let released = Mutex(ContinuousClock.Instant?.none)
        let shared = DigestFake("four-b", contextTokens: 262_144, onCall: {
            // The first piece's call is running when the person presses the key; the key is released 150 ms later.
            guard released.withLock({ $0 }) == nil else { return }
            activity.set(busy: true)
            released.withLock { $0 = ContinuousClock.now.advanced(by: .milliseconds(150)) }
            Task {
                try? await Task.sleep(for: .milliseconds(150))
                activity.set(busy: false)
            }
        })
        let model = MeetingLanguageModel(shared: shared, apple: DigestFake("apple", contextTokens: 4_096),
                                         activity: activity, health: ModelHealth(), pollInterval: .milliseconds(5),
                                         quietAfterPreemption: .milliseconds(20))
        model.route(for: Self.fourB)
        _ = await NoteSummarizer.summarize(Self.longTranscript, fallbackTitle: "Note", model: model)
        let times = shared.times, release = released.withLock { $0 }
        #expect(times.count >= 3, "a call the key press cut short is asked again")
        #expect(times.dropFirst().allSatisfy { $0 >= release! }, "nothing else started until the dictation was over")
    }

    @Test("a dictation that starts mid-call stops that call within moments; the call runs again after the dictation, not as a failure")
    func preemptsTheRunningCall() async {
        let shared = LongDecodeFake()
        let activity = ForegroundActivity()
        let model = MeetingLanguageModel(shared: shared, apple: DigestFake("apple", contextTokens: 4_096), activity: activity,
                                         health: ModelHealth(), pollInterval: .milliseconds(5), preemptInterval: .milliseconds(5),
                                         quietAfterPreemption: .milliseconds(20))
        model.route(for: Self.fourB)
        let transcript = TranscriptChunkerTests.meeting(turns: 40)
        let summary = Task { await NoteSummarizer.summarize(transcript, fallbackTitle: "Note", model: model) }
        while shared.started == 0 { try? await Task.sleep(for: .milliseconds(5)) }
        let pressed = ContinuousClock.now
        activity.set(busy: true)
        while shared.cancelled == 0, ContinuousClock.now - pressed < .seconds(5) { try? await Task.sleep(for: .milliseconds(5)) }
        #expect(shared.cancelled == 1, "the 30 s call was stopped")
        #expect(ContinuousClock.now - pressed < .seconds(2), "within moments of the key press, not after the call")
        #expect(shared.started == 1, "and it does not start again while the dictation is in progress")
        activity.set(busy: false)
        let (output, report) = await summary.value
        #expect(shared.started == 2)
        #expect(report.failures.isEmpty && report.retries == 0)
        #expect(report.calls == 1)
        #expect(output.title == "Merged by long-decode")
    }

    @Test("a dictation always comes first: the third, fourth and fifth cut the summary short too, and it finishes after them")
    func dictationAlwaysFirst() async {
        let shared = LongDecodeFake(hanging: 5, answerAfter: .milliseconds(50))
        let activity = ForegroundActivity()
        let model = MeetingLanguageModel(shared: shared, apple: DigestFake("apple", contextTokens: 4_096), activity: activity,
                                         health: ModelHealth(), pollInterval: .milliseconds(5), preemptInterval: .milliseconds(5),
                                         quietAfterPreemption: .milliseconds(5))
        model.route(for: Self.fourB)
        let transcript = TranscriptChunkerTests.meeting(turns: 40)
        let summary = Task { await NoteSummarizer.summarize(transcript, fallbackTitle: "Note", model: model) }
        for attempt in 1...5 {
            while shared.started < attempt { try? await Task.sleep(for: .milliseconds(5)) }
            let pressed = ContinuousClock.now
            activity.set(busy: true)
            while shared.cancelled < attempt, ContinuousClock.now - pressed < .seconds(5) { try? await Task.sleep(for: .milliseconds(5)) }
            #expect(shared.cancelled == attempt, "dictation \(attempt) stopped the call")
            #expect(ContinuousClock.now - pressed < .seconds(2), "within moments, not after the call")
            activity.set(busy: false)
        }
        let (output, report) = await summary.value
        #expect(shared.cancelled == 5 && shared.started == 6)
        #expect(output.title == "Merged by long-decode")
        #expect(report.failures.isEmpty)
    }

    @Test("a person who dictates every few seconds still gets a summary: past the yield limit it runs on Apple FM, and every dictation still stopped the 4B")
    func dictatingOftenStillGetsASummary() async {
        let shared = LongDecodeFake(hanging: .max)
        let apple = DigestFake("apple", contextTokens: 4_096)
        let activity = ForegroundActivity()
        let model = MeetingLanguageModel(shared: shared, apple: apple, activity: activity, health: ModelHealth(),
                                         pollInterval: .milliseconds(5), preemptInterval: .milliseconds(5),
                                         quietAfterPreemption: .milliseconds(40))
        model.route(for: Self.fourB)
        var configuration = NoteSummarizer.Configuration()
        configuration.dictationYieldLimit = .milliseconds(300)
        // A 20 ms dictation every 50 ms: never the 40 ms of quiet the summary waits for after a cut-short call.
        let dictating = Task {
            while !Task.isCancelled {
                activity.set(busy: true)
                try? await Task.sleep(for: .milliseconds(20))
                activity.set(busy: false)
                try? await Task.sleep(for: .milliseconds(30))
            }
        }
        defer { dictating.cancel() }
        let transcript = TranscriptChunkerTests.meeting(turns: 40)
        let summary = Task { await NoteSummarizer.summarize(transcript, fallbackTitle: "Note", model: model, configuration: configuration) }
        let finished = await withTaskGroup(of: (ExtractiveSummarizer.Output, NoteSummarizer.Report)?.self) { group in
            group.addTask { await summary.value }
            group.addTask {
                try? await Task.sleep(for: .seconds(5))
                summary.cancel()
                return nil
            }
            defer { group.cancelAll() }
            return await group.next() ?? nil
        }
        #expect(finished != nil, "the summary finished while the person kept dictating")
        guard let (output, report) = finished else { return }
        #expect(report.reranOnApple)
        #expect(output.title == "Merged by apple")
        #expect(shared.started > 0 && shared.cancelled == shared.started, "each dictation stopped the 4B call it met")
        let startedOnFourB = shared.started
        try? await Task.sleep(for: .milliseconds(100))
        #expect(shared.started == startedOnFourB, "nothing more runs on the 4B once the summary has moved")
    }

    @Test("a call no dictation interrupts is not cut by what is left of the yield limit: it runs for its call budget")
    func uninterruptedCallOutlivesTheYieldLimit() async {
        let shared = LongDecodeFake(hanging: 0, answerAfter: .milliseconds(600))
        let apple = DigestFake("apple", contextTokens: 4_096)
        let activity = ForegroundActivity()
        let model = MeetingLanguageModel(shared: shared, apple: apple, activity: activity, health: ModelHealth(),
                                         pollInterval: .milliseconds(5), preemptInterval: .milliseconds(5),
                                         quietAfterPreemption: .milliseconds(5))
        model.route(for: Self.fourB)
        var configuration = NoteSummarizer.Configuration()
        configuration.dictationYieldLimit = .seconds(1)
        let transcript = TranscriptChunkerTests.meeting(turns: 40)
        // A dictation is in progress when the summary starts: it waits 800 ms of its 1 s, then its call starts and no
        // dictation comes. The call takes 600 ms, three times what is left of the limit.
        activity.set(busy: true)
        let summary = Task { await NoteSummarizer.summarize(transcript, fallbackTitle: "Note", model: model, configuration: configuration) }
        try? await Task.sleep(for: .milliseconds(800))
        activity.set(busy: false)
        let (output, report) = await summary.value
        #expect(output.title == "Merged by long-decode", "the 4B's answer was used")
        #expect(!report.gaveWayToDictation && !report.reranOnApple, "nothing sent the summary to Apple FM")
        #expect(shared.started == 1 && shared.cancelled == 0, "and the 4B's call was never stopped")
        #expect(apple.calls == 0)
        #expect(report.failures.isEmpty)
    }

    @Test("a call a dictation cuts short after the yield limit ran out sends the summary to Apple FM then, not before")
    func dictationAfterTheLimitSendsItToApple() async {
        let shared = LongDecodeFake(hanging: .max)
        let apple = DigestFake("apple", contextTokens: 4_096)
        let activity = ForegroundActivity()
        let model = MeetingLanguageModel(shared: shared, apple: apple, activity: activity, health: ModelHealth(),
                                         pollInterval: .milliseconds(5), preemptInterval: .milliseconds(5),
                                         quietAfterPreemption: .milliseconds(5))
        model.route(for: Self.fourB)
        var configuration = NoteSummarizer.Configuration()
        configuration.dictationYieldLimit = .seconds(1)
        let transcript = TranscriptChunkerTests.meeting(turns: 40)
        activity.set(busy: true)
        let summary = Task { await NoteSummarizer.summarize(transcript, fallbackTitle: "Note", model: model, configuration: configuration) }
        try? await Task.sleep(for: .milliseconds(800))
        activity.set(busy: false)
        while shared.started == 0 { try? await Task.sleep(for: .milliseconds(5)) }
        // The call runs on with no dictation for 1.5 s, then one starts: the call is cut, and past the limit it is the last.
        try? await Task.sleep(for: .milliseconds(1_500))
        #expect(shared.cancelled == 0, "nothing stopped the call before the dictation")
        let nextDictation = ContinuousClock.now
        activity.set(busy: true)
        let (output, report) = await summary.value
        activity.set(busy: false)
        #expect(report.reranOnApple && report.failures.isEmpty)
        #expect(output.title == "Merged by apple")
        #expect(shared.started == 1 && shared.cancelled == 1, "the dictation stopped the 4B's call")
        #expect(apple.times.first.map { $0 >= nextDictation } == true, "and the summary moved to Apple FM after it")
    }

    @Test("the yield limit covers the whole summary, not each call: pieces that each give way a little add up to it")
    func limitCoversTheWholeSummary() async {
        let shared = CutShortEveryOtherFake(answers: DigestFake("four-b", contextTokens: 262_144))
        let apple = DigestFake("apple", contextTokens: 4_096)
        let activity = ForegroundActivity()
        let model = MeetingLanguageModel(shared: shared, apple: apple, activity: activity, health: ModelHealth(),
                                         pollInterval: .milliseconds(5), preemptInterval: .milliseconds(5),
                                         quietAfterPreemption: .milliseconds(5))
        model.route(for: Self.fourB)
        var configuration = NoteSummarizer.Configuration()
        configuration.dictationYieldLimit = .milliseconds(1_000)
        // Two pieces and the merge: a dictation cuts each call's first attempt short 400 ms in, 1.2 s in all.
        let dictating = Task {
            var cut = 0
            while !Task.isCancelled {
                while shared.started <= cut * 2, !Task.isCancelled { try? await Task.sleep(for: .milliseconds(5)) }
                try? await Task.sleep(for: .milliseconds(400))
                activity.set(busy: true)
                while shared.cancelled <= cut, !Task.isCancelled { try? await Task.sleep(for: .milliseconds(5)) }
                activity.set(busy: false)
                cut += 1
            }
        }
        defer { dictating.cancel() }
        let (output, report) = await NoteSummarizer.summarize(Self.longTranscript, fallbackTitle: "Note", model: model,
                                                              configuration: configuration)
        #expect(report.reranOnApple, "past 1 s of giving way in all, the summary ran on Apple FM")
        #expect(output.title == "Merged by apple")
    }

    @Test("a dictation that starts between the summary's wait and the call is yield time, not a call timeout, and is not waited out twice")
    func dictationBetweenWaitAndCall() async {
        let activity = ForegroundActivity()
        let begun = Mutex(false)
        let shared = DigestFake("four-b", contextTokens: 262_144)
        let model = MeetingLanguageModel(shared: shared, apple: DigestFake("apple", contextTokens: 4_096), activity: activity,
                                         health: ModelHealth(), pollInterval: .milliseconds(5), preemptInterval: .milliseconds(5),
                                         quietAfterPreemption: .milliseconds(5), respondBegins: {
            // The summarizer's wait found no dictation; one starts before the call does, and keeps going.
            guard !begun.withLock({ let was = $0; $0 = true; return was }) else { return }
            activity.set(busy: true)
        })
        model.route(for: Self.fourB)
        var configuration = NoteSummarizer.Configuration()
        let allowance = Duration.seconds(1)
        configuration.callBudget = allowance
        configuration.dictationYieldLimit = allowance
        var run = NoteSummarizer.Run(model: model, configuration: configuration)
        let began = ContinuousClock.now
        let digest = await run.callWithRetry("Instructions", prompt: "Prompt", MeetingDigest.self)
        let elapsed = ContinuousClock.now - began
        activity.set(busy: false)
        #expect(digest == nil)
        #expect(run.report.gaveWayToDictation, "the run's yield limit ran out")
        #expect(run.report.failures.isEmpty, "waiting on a dictation is not a call that timed out")
        #expect(run.report.retries == 0)
        #expect(shared.calls == 0, "the 4B never started a call over the dictation")
        // The dictation never ends, so every wait the run makes lasts its whole allowance and a sleep never returns early:
        // a second wait would take the run to two allowances or more whatever the load, and one wait leaves a whole
        // allowance of room for a slow machine.
        #expect(elapsed < allowance * 2, "one allowance for the run, not one per wait (\(elapsed))")
    }

    @Test("a summary call that finds a dictation in progress stops at once instead of waiting for it")
    func respondDoesNotWait() async {
        let activity = ForegroundActivity()
        let shared = DigestFake("four-b", contextTokens: 262_144)
        let model = MeetingLanguageModel(shared: shared, apple: DigestFake("apple", contextTokens: 4_096),
                                         activity: activity, health: ModelHealth(), pollInterval: .milliseconds(5))
        model.route(for: Self.fourB)
        activity.set(busy: true)
        let releaser = Task { try? await Task.sleep(for: .seconds(2)); activity.set(busy: false) }
        defer { releaser.cancel() }
        var preempted = false
        do {
            _ = try await model.respond(instructions: "i", prompt: "p", schema: MeetingDigest.generationSchema, options: .greedy)
        } catch is ForegroundPreempted { preempted = true } catch {}
        #expect(preempted)
        #expect(activity.isBusy, "it did not wait for the dictation to end")
        #expect(shared.calls == 0)
    }

    @Test("after a cut-short call the summary waits for a quiet spell, longer for each one in a row, up to 30 s")
    func quietSpellGrows() {
        let base = Duration.seconds(2)
        #expect(MeetingLanguageModel.quietPeriod(afterPreemptions: 0, base: base) == .zero)
        #expect(MeetingLanguageModel.quietPeriod(afterPreemptions: 1, base: base) == .seconds(2))
        #expect(MeetingLanguageModel.quietPeriod(afterPreemptions: 3, base: base) == .seconds(8))
        #expect(MeetingLanguageModel.quietPeriod(afterPreemptions: 40, base: base) == .seconds(30))
    }

    @Test("after a cut-short call the next one does not start until no dictation has run for the quiet spell")
    func waitsForQuietSpell() async {
        let shared = LongDecodeFake(hanging: 1)
        let activity = ForegroundActivity()
        let model = MeetingLanguageModel(shared: shared, apple: DigestFake("apple", contextTokens: 4_096), activity: activity,
                                         health: ModelHealth(), pollInterval: .milliseconds(5), preemptInterval: .milliseconds(5),
                                         quietAfterPreemption: .milliseconds(300))
        model.route(for: Self.fourB)
        let transcript = TranscriptChunkerTests.meeting(turns: 40)
        let summary = Task { await NoteSummarizer.summarize(transcript, fallbackTitle: "Note", model: model) }
        while shared.started == 0 { try? await Task.sleep(for: .milliseconds(5)) }
        activity.set(busy: true)
        while shared.cancelled == 0 { try? await Task.sleep(for: .milliseconds(5)) }
        activity.set(busy: false)
        try? await Task.sleep(for: .milliseconds(150))
        activity.set(busy: true)  // a second dictation inside the quiet spell starts the spell over
        try? await Task.sleep(for: .milliseconds(50))
        let released = ContinuousClock.now
        activity.set(busy: false)
        try? await Task.sleep(for: .milliseconds(150))
        #expect(shared.started == 1, "still waiting for 300 ms of quiet")
        _ = await summary.value
        #expect(shared.started == 2)
        #expect(ContinuousClock.now - released >= .milliseconds(300))
    }

    @Test("a dictation that times out while a summary call holds the shared model is not counted against the model")
    func contentionIsNotSlowness() async {
        let health = ModelHealth()
        let shared = LongDecodeFake(hanging: 1, answerAfter: .milliseconds(10))
        let activity = ForegroundActivity()
        let model = MeetingLanguageModel(shared: shared, apple: DigestFake("apple", contextTokens: 4_096), activity: activity,
                                         health: health, pollInterval: .milliseconds(5), preemptInterval: .milliseconds(5),
                                         quietAfterPreemption: .milliseconds(5))
        model.route(for: Self.fourB)
        let transcript = TranscriptChunkerTests.meeting(turns: 40)
        let summary = Task { await NoteSummarizer.summarize(transcript, fallbackTitle: "Note", model: model) }
        while shared.started == 0 { try? await Task.sleep(for: .milliseconds(5)) }
        // Two dictation cleanups whose calls ran while the summary held the model, both out of time.
        let budget = Duration.milliseconds(40)
        try? await Task.sleep(for: budget)
        health.recordTimeout(budget: budget, elapsed: budget)
        health.recordTimeout(budget: budget, elapsed: budget)
        #expect(health.sharedWithBackground(during: budget))
        #expect(health.verdict(budget: budget) == .call, "the breaker stays shut")
        activity.set(busy: true)
        while shared.cancelled == 0 { try? await Task.sleep(for: .milliseconds(5)) }
        activity.set(busy: false)
        _ = await summary.value
        // Calls that started after the summary was over are measurements again.
        try? await Task.sleep(for: budget)
        health.recordTimeout(budget: budget, elapsed: budget)
        health.recordTimeout(budget: budget, elapsed: budget)
        #expect(!health.sharedWithBackground(during: budget))
        #expect(health.verdict(budget: budget) == .skip(.breakerOpen))
    }

    @Test("a cancelled summary stops waiting")
    func cancelStopsWaiting() async {
        let activity = ForegroundActivity()
        activity.set(busy: true)
        let waiting = Task { await activity.waitUntilIdle(pollInterval: .milliseconds(5)) }
        try? await Task.sleep(for: .milliseconds(30))
        waiting.cancel()
        await waiting.value
        #expect(activity.isBusy)
    }

    @Test("Apple FM is not held back: its calls do not contend with a local model")
    func appleDoesNotYield() async {
        let apple = DigestFake("apple", contextTokens: 4_096)
        let (model, activity) = meeting(shared: DigestFake("shared", contextTokens: 262_144), apple: apple)
        model.route(for: .apple)
        activity.set(busy: true)
        await model.yieldToForeground()  // returns at once
        #expect(activity.isBusy)
    }
}
