import Foundation
import os

/// How many sentence groups were cleaned before the key release, and how many of those results the final transcript used.
/// The difference is model work on text that later changed.
public struct EarlyCleanupTally: Sendable, Equatable {
    public let started: Int
    public let used: Int

    public init(started: Int, used: Int) {
        self.started = started
        self.used = used
    }
}

/// Groups cleaned before the key release. Each is kept under its exact text and the exact options it was cleaned with.
struct EarlyStore {
    struct Entry {
        let text: String
        let strategy: SmartCleaner.Strategy
        let options: CleanupOptions
        /// The dictation it was cleaned for (see `SmartCleaner.openEarlyCleaning`).
        let generation: Int
        var result: SmartCleaner.GroupResult?
        var task: Task<SmartCleaner.GroupResult, Never>?
    }

    /// Between the start of a dictation and its key release.
    var isOpen = false
    /// This dictation had early cleaning, so its release is planned on the final transcript alone.
    var wasOpened = false
    var entries: [Entry] = []
    var started = 0
    /// Counts the dictations that opened early cleaning; the latest one's number is its token.
    var generation = 0

    func index(text: String, options: CleanupOptions, strategy: SmartCleaner.Strategy) -> Int? {
        entries.firstIndex { $0.text == text && $0.strategy == strategy && $0.options == options }
    }
}

/// Cleaning sentence groups while the person is still speaking.
///
/// The rule that keeps this safe: it may only save time. The key release cleans the final transcript in that
/// transcript's own groups (`TextSegmentation.groups`), as it would with no early cleaning at all. A group is served
/// from here only when the very same call was already made: the same group text, character for character, under the
/// same options and strategy. The cleanup model decodes greedily, so the same call gives the same answer. A group whose
/// text the recogniser later wrote differently, or that ends up split another way, is cleaned after the release and
/// the early work on it is thrown away.
///
/// This replaces matching by words (`prewarmGroup`, still here for the evals that measure it): that reused a result
/// cleaned from differently punctuated text and kept the earlier transcript's group boundaries, so the delivered text
/// could differ from what cleaning the final transcript gives.
extension SmartCleaner {
    /// A dictation has started: groups may be cleaned ahead until the next `clean`. Returns the dictation's token,
    /// for `endEarlyCleaning` to drop what was cleaned for it and nothing else: the dictation before it may still be
    /// cleaning, and its clean-up must not take this one's early work with it.
    @discardableResult
    public func openEarlyCleaning() -> Int {
        earlyStore.generation += 1
        earlyStore.isOpen = true
        earlyStore.wasOpened = true
        earlyStore.started = 0
        return earlyStore.generation
    }

    /// The dictation with this token is over: its early results are dropped and its calls still running are stopped.
    public func endEarlyCleaning(_ token: Int) {
        for entry in earlyStore.entries where entry.generation == token { entry.task?.cancel() }
        earlyStore.entries.removeAll { $0.generation == token }
        guard earlyStore.generation == token else { return }
        earlyStore.isOpen = false
        earlyStore.wasOpened = false
        earlyStore.started = 0
    }

    /// Cleans one closed sentence group ahead of the key release, under the options the release will use.
    /// Returns whether a model call was started for it. Does nothing outside a dictation's recording, for a group
    /// already cleaned or being cleaned, in a code context, or at a level that asks no model.
    @discardableResult
    public func cleanEarly(
        _ group: String, options: CleanupOptions, personalizer: Personalizer = Personalizer(), strategy: Strategy? = nil
    ) async -> Bool {
        guard earlyStore.isOpen, allowsEarlyCleaning, !group.isEmpty else { return false }
        let chosen = strategy ?? Self.strategy(for: options.level)
        let effective = Self.effectiveOptions(options, personalizer: personalizer)
        guard chosen != .rules, !effective.isCodeContext else { return false }
        if let index = earlyStore.index(text: group, options: effective, strategy: chosen) {
            if let running = earlyStore.entries[index].task { _ = await running.value }
            return false
        }
        earlyStore.started += 1
        // The call the release would make for this group (`cleanSegmented`), minus the release's deadline.
        // Early cleaning is only for the rules-draft prompt (`allowsEarlyCleaning`), and the group keeps to it throughout.
        let task = Task {
            await Self.$dictationTakesWholeTranscript.withValue(false) {
                await self.cleanGroup(group, confidences: nil, options: effective, strategy: chosen, isSegment: true, previousDraft: nil)
            }
        }
        earlyStore.entries.append(.init(
            text: group, strategy: chosen, options: effective, generation: earlyStore.generation, result: nil, task: task))
        let result = await task.value
        // The store may have been cleared, or this call cancelled at the release, while it ran.
        guard let index = earlyStore.index(text: group, options: effective, strategy: chosen),
              earlyStore.entries[index].task == task else { return true }
        if task.isCancelled || !isSettled(result, options: effective, strategy: chosen) {
            earlyStore.entries.remove(at: index)
        } else {
            earlyStore.entries[index].task = nil
            earlyStore.entries[index].result = result
        }
        return true
    }

    /// Whether a group's result is what the models decided, and not an accident of the moment. A call that timed out,
    /// failed or found the model busy says nothing about what the model would answer after the release, so its result
    /// is not kept: the group is asked again then, as it would have been. The same goes for a group whose text calls
    /// for the second pass when none was made (the second model was not available just then): the release would make
    /// it, so the release must.
    func isSettled(_ result: GroupResult, options: CleanupOptions, strategy: Strategy) -> Bool {
        let settled: Set<ModelOutcome> = [.used, .rejectedByGuard]
        guard settled.contains(result.trace.outcome), result.rejection?.hasPrefix("timeout") != true else { return false }
        if let second = result.trace.measured.secondPassOutcome { return settled.contains(second) }
        return !secondPassIsDue(on: result.text, options: options, strategy: strategy)
    }

    /// The key is up: nothing more is cleaned ahead. Returns whether this dictation had early cleaning and how many
    /// groups it started. Early calls still running are left to finish. Stopping one would count it as a call left
    /// behind (`AbandonedCalls`) if the model is slow to stop, and that count can keep the release's own calls from
    /// being made; a few seconds of the model's time is the cheaper risk.
    func closeEarlyCleaning() -> (had: Bool, started: Int) {
        earlyStore.isOpen = false
        return (earlyStore.wasOpened, earlyStore.started)
    }

    /// The early result for one of the final transcript's groups, if the same call was made before the release: at
    /// once when it has finished, after waiting (no longer than the dictation's deadline) when it is still running.
    func earlyResult(
        for text: String, options: CleanupOptions, strategy: Strategy, deadline: WaitClock
    ) async -> (GroupResult, GroupSource)? {
        guard let index = earlyStore.index(text: text, options: options, strategy: strategy) else { return nil }
        if let done = earlyStore.entries[index].result { return (done, .prewarmHit) }
        guard let running = earlyStore.entries[index].task,
              let finished = await HardDeadline.value(of: running, until: deadline.instant),
              !running.isCancelled, isSettled(finished, options: options, strategy: strategy)
        else { return nil }
        return (finished, .prewarmAwaited)
    }

    /// Counts only: how much was cleaned ahead and how much of it this transcript used.
    func earlyTally(started: Int, sources: [GroupSource]) -> EarlyCleanupTally {
        let used = sources.filter { $0 == .prewarmHit || $0 == .prewarmAwaited }.count
        let tally = EarlyCleanupTally(started: started, used: used)
        Self.log.notice("early cleanup started=\(tally.started, privacy: .public) used=\(tally.used, privacy: .public)")
        return tally
    }

    /// Forgets everything cleaned ahead, for every dictation, and stops what is still running.
    func dropEarlyResults() {
        for entry in earlyStore.entries { entry.task?.cancel() }
        let generation = earlyStore.generation
        earlyStore = EarlyStore()
        earlyStore.generation = generation
    }
}
