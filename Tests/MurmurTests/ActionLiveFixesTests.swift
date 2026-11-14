import Foundation
import Testing
import MurmurCore
@testable import Murmur

/// Build 1483 hands-on (2026-10-07): the file search must release its Spotlight query on the main
/// thread; an explicitly started voice action never pastes; explicit actions have their own
/// patience; fillers do not change what a command means.

// MARK: A. The Spotlight query is created, run and released on the main thread

private final class DeinitThread: @unchecked Sendable {
    private let lock = NSLock()
    private var onMain: Bool?
    func record(_ value: Bool) { lock.lock(); onMain = value; lock.unlock() }
    var value: Bool? { lock.lock(); defer { lock.unlock() }; return onMain }
}

@MainActor
private final class DeinitQuery: MetadataQueryDriving {
    private let onDeinit: @Sendable (Bool) -> Void
    private let finishes: Bool
    private var handler: (@MainActor () -> Void)?
    init(finishes: Bool = true, onDeinit: @escaping @Sendable (Bool) -> Void) {
        self.finishes = finishes
        self.onDeinit = onDeinit
    }
    deinit { onDeinit(Thread.isMainThread) }
    func setFinishHandler(_ handler: (@MainActor () -> Void)?) { self.handler = handler }
    func start() -> Bool {
        if finishes { Task { @MainActor [weak self] in self?.handler?() } }
        return true
    }
    func disableUpdates() {}
    func stop() {}
    var resultCount: Int { 0 }
    func candidate(at index: Int) -> FileCandidate? { nil }
}

@Suite("Live fixes: the file search")
struct FileSearchThreadTests {
    @Test("the metadata query is released on the main thread, whatever thread asked")
    func queryReleasedOnMain() async {
        let seen = DeinitThread()
        let finder = SpotlightFileFinder(makeDriver: { _, _ in DeinitQuery(onDeinit: { seen.record($0) }) })
        let spec = FileSearchSpec(
            pass: .nameAll, termGroups: [["resume"]], kind: .any, roots: [URL(fileURLWithPath: NSTemporaryDirectory())],
            limit: 5, timeBox: .seconds(2))
        _ = await Task.detached { await finder.search(spec) }.value
        for _ in 0..<300 where seen.value == nil { try? await Task.sleep(for: .milliseconds(10)) }
        #expect(seen.value == true, "NSMetadataQuery must not be deallocated off the main thread")
    }

    private func spec(box: Duration) -> FileSearchSpec {
        FileSearchSpec(
            pass: .nameAll, termGroups: [["resume"]], kind: .any, roots: [URL(fileURLWithPath: NSTemporaryDirectory())],
            limit: 5, timeBox: box)
    }

    @Test("the same when the time box ends the search")
    func releasedOnMainAfterTimeBox() async {
        let seen = DeinitThread()
        let finder = SpotlightFileFinder(makeDriver: { _, _ in DeinitQuery(finishes: false, onDeinit: { seen.record($0) }) })
        let search = spec(box: .milliseconds(60))
        _ = await Task.detached { await finder.search(search) }.value
        for _ in 0..<300 where seen.value == nil { try? await Task.sleep(for: .milliseconds(10)) }
        #expect(seen.value == true)
    }

    @Test("the same when the search is cancelled")
    func releasedOnMainAfterCancel() async {
        let seen = DeinitThread()
        let finder = SpotlightFileFinder(makeDriver: { _, _ in DeinitQuery(finishes: false, onDeinit: { seen.record($0) }) })
        let search = spec(box: .seconds(30))
        let task = Task.detached { await finder.search(search) }
        try? await Task.sleep(for: .milliseconds(80))
        task.cancel()
        _ = await task.value
        for _ in 0..<300 where seen.value == nil { try? await Task.sleep(for: .milliseconds(10)) }
        #expect(seen.value == true)
    }
}

// MARK: B. An explicit voice action never pastes

@Suite("Live fixes: explicit actions")
@MainActor
struct ExplicitActionTests {
    private func rig(extracting result: ActionExtractionResult, heard: String = "hmm that is a thing") throws
        -> (rig: VoiceActionOutcomeTests.Rig, inserted: Box, extractions: Box) {
        let rig = try VoiceActionOutcomeTests.Rig()
        let inserted = Box()
        let extractions = Box()
        rig.controller.insertFallbackText = { inserted.items.append($0) }
        rig.controller.transcribeSamples = { _ in heard }
        rig.controller.extract = { text, _ in
            extractions.items.append(text)
            return ActionExtractor.Output(result: result, usedModel: true)
        }
        return (rig, inserted, extractions)
    }

    @MainActor final class Box { var items: [String] = [] }

    private func failure(_ rig: VoiceActionOutcomeTests.Rig) -> (question: String, message: String, suggestion: String?)? {
        guard case .answer(let card) = rig.pill.state, case .failure(let content) = card.phase else { return nil }
        return (card.question, content.message, content.suggestion)
    }

    @Test("not an action: nothing is pasted; the pill says so with the words heard and offers a retry")
    func notAnActionNeverPastes() async throws {
        let (rig, inserted, extractions) = try rig(extracting: .notAnAction)
        await rig.controller.process([0.1], followUp: nil)
        #expect(inserted.items.isEmpty, "an explicit action never pastes into the front app")
        let shown = try #require(failure(rig), "the pill must say it did not understand")
        #expect(shown.question == "hmm that is a thing")
        #expect(shown.message.lowercased().contains("understand"))
        #expect(shown.suggestion == "Try again")
        // The offer runs the same words again.
        rig.controller.takeAnswerSuggestion()
        await rig.settle { extractions.items.count == 2 }
        #expect(extractions.items == ["hmm that is a thing", "hmm that is a thing"])
        #expect(inserted.items.isEmpty)
    }

    @Test("rejected (budget, breaker, model error): nothing is pasted; the pill says the assistant was busy")
    func rejectedNeverPastes() async throws {
        for reason in ["timeout", "skipped: breaker-open", "model error"] {
            let (rig, inserted, _) = try rig(extracting: .rejected(reason))
            await rig.controller.process([0.1], followUp: nil)
            #expect(inserted.items.isEmpty, "\(reason)")
            let shown = try #require(failure(rig), "\(reason)")
            #expect(shown.message.lowercased().contains("busy"), "\(reason)")
            #expect(shown.suggestion == "Try again", "\(reason)")
        }
    }

    // MARK: Retry goes through the same task and flag as a first attempt

    private func reminderResult() -> ActionExtractionResult {
        .actions([ProposedAction(kind: .createReminder, title: "Call Dana", sourceText: "remind me to call dana")])
    }

    @Test("Esc while a retry works means nothing executes")
    func escDuringRetry() async throws {
        let (rig, _, extractions) = try rig(extracting: .notAnAction)
        await rig.controller.process([0.1], followUp: nil)
        rig.controller.extract = { text, _ in
            extractions.items.append(text)
            try? await Task.sleep(for: .milliseconds(200))
            return ActionExtractor.Output(result: self.reminderResult(), usedModel: true)
        }
        rig.controller.takeAnswerSuggestion()
        try? await Task.sleep(for: .milliseconds(40))
        #expect(rig.pill.state == .actionProcessing)
        rig.controller.cancelProcessing()
        try? await Task.sleep(for: .milliseconds(400))
        #expect(await rig.calendar.createdReminders.isEmpty, "a cancelled retry never acts")
        #expect(rig.pill.state == .idle)
    }

    @Test("a retry whose card was dismissed never starts")
    func dismissedCardNeverRetries() async throws {
        let (rig, _, extractions) = try rig(extracting: .notAnAction)
        await rig.controller.process([0.1], followUp: nil)
        #expect(extractions.items.count == 1)
        rig.pill.state = .idle // the person closed the card
        await rig.controller.retryAction("hmm that is a thing")
        try? await Task.sleep(for: .milliseconds(80))
        #expect(extractions.items.count == 1)
    }

    @Test("two fast Try again taps run one extraction")
    func doubleTapRunsOnce() async throws {
        let (rig, _, extractions) = try rig(extracting: .notAnAction)
        await rig.controller.process([0.1], followUp: nil)
        rig.controller.takeAnswerSuggestion()
        rig.controller.takeAnswerSuggestion()
        await rig.settle { extractions.items.count >= 2 }
        try? await Task.sleep(for: .milliseconds(150))
        #expect(extractions.items.count == 2, "the first attempt plus one retry")
    }

    @Test("the explicit extractor has its own health gate and a longer patience than cleanup")
    func explicitExtractor() {
        let extractor = ActionExtractor.explicit(model: NullLanguageModel())
        #expect(extractor.health !== ModelHealth.shared, "a run of slow cleanups must not make an action skip the model")
        #expect(extractor.budget == ActionExtractor.explicitBudget)
        #expect(ActionExtractor.explicitBudget == .seconds(8))
    }
}
