import Foundation
import Synchronization
import Testing
@testable import MurmurCore

/// Cleaning sentence groups before the key release (`SmartCleaner.cleanEarly`) may only save time. The delivered text is
/// always the cleaning of the final transcript's own groups; an early result stands in for a group only when it is the
/// same call: the same group text, the same options. Anything else is cleaned after the release, as it would have been.
@Suite("Early cleanup: the delivered text is the after-release text", .timeLimit(.minutes(1)), .serialized)
struct EarlyCleanupExactTests {
    /// Ten words each: two make a group, so six make three groups.
    private let sentences = (1...6).map { "The report for region number \($0) is ready for review." }
    private var final: String { sentences.joined(separator: " ") }
    private let options = CleanupOptions(level: .polished)

    private func cleaner(_ model: EarlyModel, second: EarlyModel? = nil) -> SmartCleaner {
        let budget: Duration = .seconds(5)
        return SmartCleaner(
            budget: budget, correctionBudget: budget, polishedBudget: budget, segmentBudget: budget,
            model: model, health: ModelHealth(), secondOpinion: second)
    }

    private func closedGroups(_ text: String) -> [String] {
        TextSegmentation.groups(text).filter { !$0.isTail }.map(\.text)
    }

    @Test("groups cleaned early are not cleaned again, and the text is the same as without early cleaning")
    func sameTextFewerCallsAtRelease() async {
        let reference = await cleaner(EarlyModel("first")).clean(final, options: options)
        let model = EarlyModel("first")
        let subject = cleaner(model)
        await subject.openEarlyCleaning()
        for group in closedGroups(final) { await subject.cleanEarly(group, options: options) }
        let before = model.calls
        let output = await subject.clean(final, options: options)
        #expect(closedGroups(final).count == 2)
        #expect(output.text == reference.text)
        #expect(output.groupSources == [.prewarmHit, .prewarmHit, .fresh])
        #expect(model.calls - before == 1)
        #expect(output.early == EarlyCleanupTally(started: 2, used: 2))
        #expect(reference.early == nil)
    }

    @Test("a group the final transcript wrote differently is cleaned after the release; the after-release text wins")
    func changedGroupIsCleanedAfresh() async {
        // The recogniser's final pass joined the first two sentences with a comma.
        let changed = final.replacingOccurrences(of: "number 1 is ready for review. The", with: "number 1 is ready for review, the")
        let reference = await cleaner(EarlyModel("first")).clean(changed, options: options)
        let subject = cleaner(EarlyModel("first"))
        await subject.openEarlyCleaning()
        for group in closedGroups(final) { await subject.cleanEarly(group, options: options) }
        let output = await subject.clean(changed, options: options)
        #expect(output.text == reference.text)
        #expect(output.groupSources == [.fresh, .prewarmHit, .fresh])
        #expect(output.early == EarlyCleanupTally(started: 2, used: 1))
    }

    @Test("the groups cleaned are the final transcript's own, whatever was cleaned early")
    func releasePlanIsTheFinalTranscripts() async {
        let reference = await cleaner(EarlyModel("first")).clean(final, options: options)
        let subject = cleaner(EarlyModel("first"))
        await subject.openEarlyCleaning()
        // A group that straddles two of the final transcript's groups.
        await subject.cleanEarly(sentences[1] + " " + sentences[2], options: options)
        let output = await subject.clean(final, options: options)
        #expect(output.text == reference.text)
        #expect(output.groups.count == TextSegmentation.groups(final).count)
        #expect(output.groupSources == [.fresh, .fresh, .fresh])
        #expect(output.early == EarlyCleanupTally(started: 1, used: 0))
    }

    @Test("an early result made under other options is not reused")
    func otherOptionsAreNotReused() async {
        var release = options
        release.protectedTerms = ["Region"]
        let reference = await cleaner(EarlyModel("first")).clean(final, options: release)
        let subject = cleaner(EarlyModel("first"))
        await subject.openEarlyCleaning()
        for group in closedGroups(final) { await subject.cleanEarly(group, options: options) }
        let output = await subject.clean(final, options: release)
        #expect(output.text == reference.text)
        #expect(output.groupSources == [.fresh, .fresh, .fresh])
        #expect(output.early == EarlyCleanupTally(started: 2, used: 0))
    }

    @Test("nothing is cleaned early before a dictation opens it or after the key release")
    func onlyBetweenStartAndRelease() async {
        let model = EarlyModel("first")
        let subject = cleaner(model)
        let group = closedGroups(final)[0]
        #expect(await subject.cleanEarly(group, options: options) == false)
        #expect(model.calls == 0)
        await subject.openEarlyCleaning()
        _ = await subject.clean(final, options: options)
        let after = model.calls
        #expect(await subject.cleanEarly(group, options: options) == false)
        #expect(model.calls == after)
    }

    @Test("an early call still running at the release is waited for when its group is in the final transcript")
    func runningCallForAPlannedGroupIsAwaited() async {
        let reference = await cleaner(EarlyModel("first")).clean(final, options: options)
        let model = EarlyModel("first", delay: .milliseconds(300))
        let subject = cleaner(model)
        await subject.openEarlyCleaning()
        let group = closedGroups(final)[0]
        let running = Task { await subject.cleanEarly(group, options: options) }
        try? await Task.sleep(for: .milliseconds(60))
        let output = await subject.clean(final, options: options)
        _ = await running.value
        #expect(output.text == reference.text)
        #expect(output.groupSources.first == .prewarmAwaited)
        #expect(model.calls == 3)
    }

    @Test("an early call still running at the release for text the final transcript does not have is left to finish")
    func runningCallForADroppedGroupIsNotStopped() async {
        let reference = await cleaner(EarlyModel("first")).clean(final, options: options)
        let model = EarlyModel("first", delay: .milliseconds(400), slowOnly: "region number 9")
        let subject = cleaner(model)
        await subject.openEarlyCleaning()
        let dropped = "The report for region number 9 is ready for review. The report for region number 8 is ready for review."
        let running = Task { await subject.cleanEarly(dropped, options: options) }
        try? await Task.sleep(for: .milliseconds(60))
        let output = await subject.clean(final, options: options)
        _ = await running.value
        // Stopping it could count against the calls-left-behind limit and cost the release its own calls.
        #expect(model.cancelled == 0)
        #expect(output.text == reference.text)
        #expect(output.groupSources == [.fresh, .fresh, .fresh])
        #expect(output.early == EarlyCleanupTally(started: 1, used: 0))
    }

    @Test("a group cleaned early while the second model could not be called is not kept: the release makes the second pass")
    func secondPassSkippedForAvailabilityIsNotKept() async throws {
        let leftover = "We could like hide the sidebar for new users and move the menu up front."
        let text = ([leftover] + sentences).joined(separator: " ")
        let strip: @Sendable (String) -> String = { $0.replacingOccurrences(of: " like ", with: " ") }
        let reference = await cleaner(EarlyModel("first"), second: EarlyModel("second", strip)).clean(text, options: options)
        let second = EarlyModel("second", strip)
        let subject = cleaner(EarlyModel("first"), second: second)
        await subject.openEarlyCleaning()
        second.isUnavailable = true
        for group in closedGroups(text) { await subject.cleanEarly(group, options: options) }
        second.isUnavailable = false
        #expect(second.calls == 0)
        let output = await subject.clean(text, options: options)
        #expect(second.calls == 1)
        #expect(output.text == reference.text)
        #expect(output.groups.first?.secondPass == .used)
        #expect(output.groupSources.first == .fresh)
    }

    @Test("ending one dictation's early cleaning leaves the next dictation's alone")
    func endingOneDictationKeepsTheNext() async {
        let subject = cleaner(EarlyModel("first"))
        let first = await subject.openEarlyCleaning()
        for group in closedGroups(final) { await subject.cleanEarly(group, options: options) }
        _ = await subject.clean(final, options: options)
        // The next dictation is already being cleaned ahead when the first one's clean-up runs.
        let later = (7...12).map { "The report for region number \($0) is ready for review." }.joined(separator: " ")
        let second = await subject.openEarlyCleaning()
        #expect(second != first)
        for group in closedGroups(later) { await subject.cleanEarly(group, options: options) }
        await subject.endEarlyCleaning(first)
        #expect(await subject.cleanEarly("The report for region number 20 is ready for review. The report for region number 21 is ready for review.", options: options))
        let output = await subject.clean(later, options: options)
        #expect(output.groupSources == [.prewarmHit, .prewarmHit, .fresh])
        #expect(output.early == EarlyCleanupTally(started: 3, used: 2))
        await subject.endEarlyCleaning(second)
        let again = await subject.clean(later, options: options)
        #expect(again.groupSources == [.fresh, .fresh, .fresh])
        #expect(again.early == nil)
    }

    @Test("the second pass still runs for a group cleaned early, once, with the same result")
    func secondPassStillRuns() async throws {
        let leftover = "We could like hide the sidebar for new users and move the menu up front."
        let text = ([leftover] + sentences).joined(separator: " ")
        let strip: @Sendable (String) -> String = { $0.replacingOccurrences(of: " like ", with: " ") }
        let referenceSecond = EarlyModel("second", strip)
        let reference = await cleaner(EarlyModel("first"), second: referenceSecond).clean(text, options: options)
        #expect(referenceSecond.calls == 1)
        #expect(reference.groups.first?.secondPass == .used)

        let second = EarlyModel("second", strip)
        let subject = cleaner(EarlyModel("first"), second: second)
        await subject.openEarlyCleaning()
        for group in closedGroups(text) { await subject.cleanEarly(group, options: options) }
        #expect(second.calls == 1)
        let output = await subject.clean(text, options: options)
        #expect(second.calls == 1)
        #expect(output.text == reference.text)
        #expect(output.groups.first?.secondPass == .used)
        #expect(output.groupSources.first == .prewarmHit)
        #expect(!output.text.lowercased().contains("could like hide"))
    }

    @Test("an early result the model never really answered is not kept: the group is asked again after the release")
    func unansweredEarlyResultIsNotKept() async {
        let reference = await cleaner(EarlyModel("first")).clean(final, options: options)
        let model = EarlyModel("first")
        let subject = cleaner(model)
        await subject.openEarlyCleaning()
        model.isFailing = true
        await subject.cleanEarly(closedGroups(final)[0], options: options)
        model.isFailing = false
        let output = await subject.clean(final, options: options)
        #expect(output.text == reference.text)
        #expect(output.groupSources.first == .fresh)
        #expect(output.groups.first?.outcome == .used)
    }

    @Test("a transcript short enough for one call ignores early results")
    func oneCallTextIgnoresEarlyResults() async {
        let short = sentences.prefix(3).joined(separator: " ")
        let reference = await cleaner(EarlyModel("first")).clean(short, options: options)
        let subject = cleaner(EarlyModel("first"))
        await subject.openEarlyCleaning()
        await subject.cleanEarly(sentences[0] + " " + sentences[1], options: options)
        let output = await subject.clean(short, options: options)
        #expect(output.text == reference.text)
        #expect(output.groups.count == 1)
        #expect(output.early == EarlyCleanupTally(started: 1, used: 0))
    }

    @Test("clearing drops early results, so the next dictation starts with none")
    func clearDropsEarlyResults() async {
        let subject = cleaner(EarlyModel("first"))
        await subject.openEarlyCleaning()
        for group in closedGroups(final) { await subject.cleanEarly(group, options: options) }
        await subject.clearPrewarmedGroups()
        let output = await subject.clean(final, options: options)
        #expect(output.groupSources == [.fresh, .fresh, .fresh])
        #expect(output.early == nil)
    }
}

/// Answers a cleanup request with `transform` of the draft; counts its calls and the ones cancelled under it.
private final class EarlyModel: LanguageModel {
    private let name: String
    private let transform: @Sendable (String) -> String
    private let delay: Duration
    private let slowOnly: String?
    private let state: Mutex<(calls: Int, cancelled: Int, failing: Bool, unavailable: Bool)>

    init(
        _ name: String, delay: Duration = .zero, slowOnly: String? = nil,
        _ transform: @escaping @Sendable (String) -> String = { $0 }
    ) {
        self.name = name
        self.delay = delay
        self.slowOnly = slowOnly
        self.transform = transform
        self.state = Mutex((0, 0, false, false))
    }

    var calls: Int { state.withLock { $0.calls } }
    var cancelled: Int { state.withLock { $0.cancelled } }
    var isFailing: Bool {
        get { state.withLock { $0.failing } }
        set { state.withLock { $0.failing = newValue } }
    }
    var isUnavailable: Bool {
        get { state.withLock { $0.unavailable } }
        set { state.withLock { $0.unavailable = newValue } }
    }
    var identifier: String { name }
    var availability: LanguageModelAvailability { isUnavailable ? .unavailable(reason: "scripted") : .available }
    func supportsLanguage(_ languageCode: String) -> Bool { true }
    func prewarm(instructions: String) {}
    func prefixCache(instructions: String) async {}

    func respond(
        instructions: String, prompt: String, schema: GenerationSchemaSpec, options: LanguageModelOptions
    ) async throws -> String {
        guard schema.name == SmartCleaner.Cleaned.generationSchema.name else { throw LanguageModelError.unsupportedSchema(schema.name) }
        let fails = state.withLock { current -> Bool in
            current.calls += 1
            return current.failing
        }
        if fails { throw LanguageModelError.unsupportedSchema("scripted failure") }
        if delay > .zero, slowOnly.map(prompt.contains) ?? true {
            do {
                try await Task.sleep(for: delay)
            } catch {
                state.withLock { $0.cancelled += 1 }
                throw error
            }
        }
        let draft = prompt.replacingOccurrences(of: "Transcript: ", with: "").replacingOccurrences(of: "\nOutput:", with: "")
        return String(decoding: try JSONEncoder().encode(["text": transform(draft)]), as: UTF8.self)
    }
}
