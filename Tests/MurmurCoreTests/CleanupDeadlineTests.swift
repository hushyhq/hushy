import Foundation
import Synchronization
import Testing
@testable import MurmurCore

/// The wait after the key is released has hard edges: a model that ignores cancellation cannot hold the
/// text back, one absolute deadline covers every call, retry and wait of a dictation, and a model that
/// keeps timing out gets one short attempt per dictation, said so in History, until it answers again.
@Suite("Cleanup deadlines", .timeLimit(.minutes(1)), .serialized)
struct CleanupDeadlineTests {
    /// Distinct sentences, so no group's words match another's (a prewarm is matched by words).
    private func longDictation(sentences: Int = 40) -> String {
        (1...sentences).map { "Part number \($0) says we need to finish the report before Friday and send it to the team." }
            .joined(separator: " ")
    }
    private let short = "we need to finish the report before friday"

    private func seconds(_ since: ContinuousClock.Instant) -> Double { ModelPace.ms(ContinuousClock.now - since) / 1000 }

    /// Time the Mac was awake since `since`. The cleaner's deadlines run on the continuous clock, which also counts
    /// the time a closed lid spends asleep, so a deadline that fires late on waking is not slowness in the code. An
    /// upper bound on a wait is measured here; a lower bound ("it waited at least the limit") stays on `seconds`.
    private func awakeSeconds(_ since: SuspendingClock.Instant) -> Double { ModelPace.ms(SuspendingClock.now - since) / 1000 }

    // MARK: A backend that ignores cancellation

    @Test("a model that never answers and ignores cancellation is left behind at the budget")
    func hardBudget() async {
        // Returning at all is the proof: the model never answers and never notices cancellation, so a call
        // that waited for it would hang until the suite's time limit.
        let result: Result<SmallSpanJudge.Verdict, ModelCallFailure> = await StubbornModel().respondResult(
            instructions: "", prompt: "", generating: SmallSpanJudge.Verdict.self, options: .greedy, budget: .milliseconds(300))
        #expect(result == .failure(.timeout))
    }

    @Test("a cleaner on a model that ignores cancellation still returns the rules text at the deadline")
    func cleanerReturns() async {
        let cleaner = SmartCleaner(
            budget: .seconds(30), correctionBudget: .seconds(30), polishedBudget: .seconds(30), segmentBudget: .seconds(30),
            model: StubbornModel(), health: ModelHealth(), dictationCeiling: .milliseconds(600))
        let output = await cleaner.clean(short, options: CleanupOptions(level: .clean))
        #expect(output.text.lowercased().contains("finish the report"))
        #expect(output.groups.first?.outcome == .timeout)
    }

    // MARK: One absolute deadline per dictation

    /// A retry needs `minimumRetryBudget` (2 s) left when the first call times out. With 3.5 s the first group's retry
    /// has 1.1 s of slack, so a stalled timer cannot take it away; at 2.5 s the slack was 0.1 s and any hiccup did.
    private static let absoluteCeiling: Duration = .milliseconds(3_500)

    @Test("twelve or more fresh groups never run past the dictation deadline, and the rest say so")
    func absoluteDeadline() async {
        let model = PacedModel(delay: .milliseconds(1_600))
        let budget: Duration = .milliseconds(400)
        let cleaner = SmartCleaner(
            budget: budget, correctionBudget: budget, polishedBudget: budget, segmentBudget: budget,
            model: model, health: ModelHealth(), dictationCeiling: Self.absoluteCeiling)
        let start = ContinuousClock.now
        let output = await cleaner.clean(longDictation(), options: CleanupOptions(level: .clean))
        #expect(output.groups.count >= 8)
        #expect(output.groups.first?.outcome == .timeout)
        #expect(output.groups.first?.retries == 1)
        // After a group timed out even with its retry, the next ones ask once.
        #expect(output.groups.dropFirst().first?.retries == 0)
        // Order and outcome, not a duration: every group the deadline allowed asked and timed out, and from the
        // first one it cut off every later group took the rules text.
        let outcomes = output.groups.map(\.outcome)
        let firstCutOff = outcomes.firstIndex(of: .releaseWindow)
        #expect(firstCutOff != nil)
        if let firstCutOff {
            #expect(outcomes[..<firstCutOff].allSatisfy { $0 == .timeout })
            #expect(outcomes[firstCutOff...].allSatisfy { $0 == .releaseWindow })
        }
        // The deadline was used, not undershot (a lower bound cannot flake on a busy machine).
        #expect(seconds(start) >= 3.3)
        let summary = CleanupOutcomeSummary(groups: output.groups, level: .clean)
        #expect(summary?.plainLine.contains("Model pass skipped") == true)
    }

    @Test("a retry is cut to what is left of the group ceiling after the pause, not before it")
    func retryAfterPause() async {
        // The pause before the retry is 0.4 s. A retry sized before it overshoots a 4 s ceiling by 0.4 s; sized
        // after it, the second call is cancelled when the ceiling is reached. The model records when its calls
        // start and when the second is cancelled, so the check compares instants taken on one clock. A late
        // timer on a loaded machine only delays the cancellation, so the run is repeated before failing (the
        // instants are on the clock that stops while the Mac sleeps).
        var worst = 0.0
        for _ in 0..<5 {
            let model = BusyThenHangModel()
            let cleaner = SmartCleaner(
                budget: .seconds(10), correctionBudget: .seconds(10), polishedBudget: .seconds(10), segmentBudget: .seconds(10),
                model: model, health: ModelHealth(), groupCeiling: .seconds(4))
            let output = await cleaner.clean(short, options: CleanupOptions(level: .clean))
            #expect(output.groups.first?.retries == 1)
            #expect(output.groups.first?.outcome == .timeout)
            guard let first = model.firstStart, let cancelled = model.secondCancelled else {
                Issue.record("the model did not see both calls"); return
            }
            let overshoot = ModelPace.ms(cancelled - first) / 1000 - 4.0
            worst = overshoot
            if overshoot < 0.25 { break }
        }
        #expect(worst < 0.25, "the retry ran \(worst) s past the group ceiling")
    }

    @Test("a prewarm still running at the deadline is abandoned and its rules text stands")
    func hungPrewarm() async {
        let cleaner = SmartCleaner(
            budget: .seconds(10), correctionBudget: .seconds(10), polishedBudget: .seconds(10), segmentBudget: .seconds(10),
            model: StubbornModel(), health: ModelHealth(), dictationCeiling: .milliseconds(500))
        let options = CleanupOptions(level: .clean)
        let transcript = longDictation(sentences: 12)
        let groups = TextSegmentation.groups(transcript)
        #expect(groups.count > 1)
        let first = groups[0]
        let prewarm = Task { await cleaner.prewarmGroup(first.text, options: options, continuesSentence: first.continuesSentence) }
        try? await Task.sleep(for: .milliseconds(150))
        let output = await cleaner.clean(transcript, options: options)
        #expect(output.groups.first?.outcome == .prewarmLate)
        #expect(output.groups.first?.source == .prewarmLate)
        #expect(output.groups.dropFirst().allSatisfy { $0.outcome == .releaseWindow })
        prewarm.cancel()
    }

    // MARK: The clock starts at the key release

    @Test("time spent transcribing counts against the deadline")
    func releaseOriginCounts() async {
        let model = PacedModel(delay: .milliseconds(1_600))
        let budget: Duration = .milliseconds(400)
        let cleaner = SmartCleaner(
            budget: budget, correctionBudget: budget, polishedBudget: budget, segmentBudget: budget,
            model: model, health: ModelHealth(), dictationCeiling: .seconds(8))
        // Released 5 s ago: 3 s of an 8 s deadline are left.
        let released = ContinuousClock.now - .seconds(5)
        let output = await cleaner.clean(longDictation(), options: CleanupOptions(level: .clean), released: released)
        // Counting from the start of cleanup instead, the 8 s deadline would outlast all of these groups
        // (about 6 s of timeouts); counting from the release, the last ones are cut off.
        #expect(output.groups.last?.outcome == .releaseWindow)
        #expect(output.groups.first?.outcome == .timeout)
    }

    @Test("a recording whose transcription used the whole deadline still gets the floor of model time")
    func deadlineFloor() async {
        let model = PacedModel(delay: .milliseconds(100))
        let cleaner = SmartCleaner(model: model, health: ModelHealth(), dictationCeiling: .seconds(5))
        let released = ContinuousClock.now - .seconds(30)
        let output = await cleaner.clean(short, options: CleanupOptions(level: .clean), released: released)
        // Not "release-window": the model was asked, and answered.
        #expect(output.groups.first?.outcome == .used)
        #expect(SmartCleaner.deadlineFloor == .seconds(3))
    }

    @Test("the outer deadline is the later of 20 s after the release and the floor after cleanup starts")
    func realBoundOfTheOuterDeadline() async {
        // Transcription took 19 s, so 1 s of the 20 s is left; the floor still gives the model 3 s from now.
        let cleaner = SmartCleaner(
            budget: .seconds(10), correctionBudget: .seconds(10), polishedBudget: .seconds(10), segmentBudget: .seconds(10),
            model: StubbornModel(), health: ModelHealth())
        let released = ContinuousClock.now - .seconds(19)
        let started = ContinuousClock.now
        let awakeStart = SuspendingClock.now
        _ = await cleaner.clean(short, options: CleanupOptions(level: .clean), released: released)
        let waited = ContinuousClock.now - started
        #expect(waited >= .milliseconds(2_500), "the floor was not applied")
        // The model never answers and each call is allowed 10 s, so a wait that ignored the floor's end would run
        // to 10 s or the 20 s deadline. Under 9 s separates those from the 3 s floor with room for a busy machine.
        #expect(awakeSeconds(awakeStart) < 9, "the wait ran past floor, not past a strict 20 s")
    }

    // MARK: The wait ends when no group has been answered for a while

    private func options(_ level: CleanupLevel = .clean) -> CleanupOptions { CleanupOptions(level: level) }

    @Test("a model that never answers costs one group no more than the no-progress limit after release")
    func noProgressOneGroup() async {
        let cleaner = SmartCleaner(
            budget: .seconds(30), correctionBudget: .seconds(30), polishedBudget: .seconds(30), segmentBudget: .seconds(30),
            model: StubbornModel(), health: ModelHealth(), noProgressCeiling: .milliseconds(700))
        let start = ContinuousClock.now
        let awakeStart = SuspendingClock.now
        let output = await cleaner.clean(short, options: options())
        let waited = seconds(start)
        #expect(output.groups.first?.outcome == .timeout)
        #expect(output.text.lowercased().contains("finish the report"))
        #expect(waited >= 0.65, "stopped at \(waited) s, before the limit")
        // The limit is 0.7 s; without it the wait would run to the 20 s dictation deadline (the call budget is
        // 30 s). Under 10 s cannot be mistaken for either.
        #expect(awakeSeconds(awakeStart) < 10, "waited \(waited) s")
    }

    @Test("the same for forty groups: one wait of at most the limit, the rest keep the rules text")
    func noProgressForty() async {
        let cleaner = SmartCleaner(
            budget: .seconds(30), correctionBudget: .seconds(30), polishedBudget: .seconds(30), segmentBudget: .seconds(30),
            model: StubbornModel(), health: ModelHealth(), noProgressCeiling: .milliseconds(700))
        let start = ContinuousClock.now
        let awakeStart = SuspendingClock.now
        let output = await cleaner.clean(longDictation(), options: options())
        let waited = seconds(start)
        #expect(output.groups.count >= 8)
        #expect(output.groups.first?.outcome == .timeout)
        #expect(output.groups.dropFirst().allSatisfy { $0.outcome == .releaseWindow })
        #expect(output.text.contains("Part number 40"))
        // One 0.7 s wait; forty waits, or the 20 s deadline, would be far past 10 s.
        #expect(awakeSeconds(awakeStart) < 10, "waited \(waited) s")
        // History still says what happened, in the same words as for the absolute deadline.
        #expect(CleanupOutcomeSummary(groups: output.groups, level: .clean)?.plainLine.contains("Model pass skipped") == true)
    }

    @Test("every answer that arrives restarts the clock: groups that keep answering are never cut by it")
    func answersRestartTheClock() async {
        // 12 groups at 0.4 s each is 4.8 s in all, far more than the 1 s limit; each answer comes inside it.
        let cleaner = SmartCleaner(
            budget: .seconds(5), correctionBudget: .seconds(5), polishedBudget: .seconds(5), segmentBudget: .seconds(5),
            model: PacedModel(delay: .milliseconds(400)), health: ModelHealth(), noProgressCeiling: .seconds(1))
        let output = await cleaner.clean(longDictation(sentences: 12), options: options(.polished))
        #expect(output.groups.count >= 8)
        let cut = output.groups.filter { $0.outcome == .timeout || $0.outcome == .releaseWindow || $0.outcome == .prewarmLate }
        #expect(cut.isEmpty, "\(cut.count) of \(output.groups.count) groups were cut off")
        #expect(output.groups.contains { $0.outcome == .used })
    }

    @Test("when the model stops answering partway, the wait ends one limit after its last answer")
    func stopsAfterLastAnswer() async {
        let model = AnswerThenHangModel(answers: 4, delay: .milliseconds(300))
        let cleaner = SmartCleaner(
            budget: .seconds(30), correctionBudget: .seconds(30), polishedBudget: .seconds(30), segmentBudget: .seconds(30),
            model: model, health: ModelHealth(), noProgressCeiling: .seconds(1))
        let start = ContinuousClock.now
        let awakeStart = SuspendingClock.now
        let output = await cleaner.clean(longDictation(sentences: 12), options: options())
        let waited = seconds(start)
        let outcomes = output.groups.map(\.outcome)
        #expect(outcomes.prefix(4).allSatisfy { $0 == .used || $0 == .rejectedByGuard }, "\(outcomes)")
        #expect(outcomes.dropFirst(4).first == .timeout)
        #expect(outcomes.dropFirst(5).allSatisfy { $0 == .releaseWindow })
        // 4 answers take 1.2 s, then one more limit of waiting: not the 30 s call budget, not the 20 s deadline.
        #expect(waited >= 2.1, "waited only \(waited) s")
        // The 30 s call budget and the 20 s deadline are what a missing limit would run to; 10 s is below both.
        #expect(awakeSeconds(awakeStart) < 10, "waited \(waited) s")
    }

    @Test("a slow single answer inside the per-call ceiling is still used")
    func slowAnswerStillUsed() async {
        let cleaner = SmartCleaner(
            budget: .seconds(3), correctionBudget: .seconds(3), polishedBudget: .seconds(3), segmentBudget: .seconds(3),
            model: PacedModel(delay: .milliseconds(1_800)), health: ModelHealth(), noProgressCeiling: .seconds(4))
        let output = await cleaner.clean(short, options: options())
        #expect(output.groups.first?.outcome == .used)
    }

    @Test("when the wait ends before the model answers, its late reply is not applied")
    func lateAnswerNotApplied() async {
        let model = LateReturnModel(returnsAfter: .milliseconds(5_000))
        let cleaner = SmartCleaner(
            budget: .seconds(30), correctionBudget: .seconds(30), polishedBudget: .seconds(30), segmentBudget: .seconds(30),
            model: model, health: ModelHealth(), noProgressCeiling: .milliseconds(700))
        let awakeStart = SuspendingClock.now
        let output = await cleaner.clean(short, options: options())
        #expect(output.groups.first?.outcome == .timeout)
        #expect(output.text.lowercased().contains("before friday"))
        #expect(!output.text.hasSuffix("the report."))
        #expect(awakeSeconds(awakeStart) < 2, "waited past no-progress cap")
        try? await Task.sleep(for: .milliseconds(5_500))
        #expect(model.started == 1)
    }

    @Test("the limit is one named constant, inside the absolute deadline, and above what real answers need")
    func noProgressConstant() {
        #expect(SmartCleaner.noProgressCeiling == .seconds(8))
        #expect(SmartCleaner.noProgressCeiling < SmartCleaner.defaultDictationCeiling)
        // Measured answers: Clean at most 2.7 s and Polished at most 3.5 s with the machine at load average 147.
        #expect(SmartCleaner.noProgressCeiling >= .seconds(6))
    }

    // MARK: One shared, atomic count of calls left behind

    @Test("overlapping calls against a backend that never returns leave at most the limit behind")
    func overlappingCallsAreBounded() async {
        let counter = AbandonedCalls()
        let model = StubbornModel()
        let results = await withTaskGroup(of: Result<SmallSpanJudge.Verdict, ModelCallFailure>.self) { group in
            for _ in 0..<8 {
                group.addTask {
                    await model.respondResult(
                        instructions: "", prompt: "", generating: SmallSpanJudge.Verdict.self, options: .greedy,
                        budget: .milliseconds(200), abandoned: counter)
                }
            }
            var all: [Result<SmallSpanJudge.Verdict, ModelCallFailure>] = []
            for await result in group { all.append(result) }
            return all
        }
        // The check and the reservation are one step: exactly the limit got to start, the rest were refused.
        #expect(results.filter { $0 == .failure(.timeout) }.count == AbandonedCalls.limit)
        #expect(results.filter { $0 == .failure(.notResponding) }.count == 8 - AbandonedCalls.limit)
        #expect(counter.outstanding == AbandonedCalls.limit)
        #expect(counter.inFlight == 0)
    }

    @Test("a call that finishes in time is never counted as left behind, at any point")
    func successLeavesNothingBehind() async {
        let counter = AbandonedCalls()
        let model = ProbingModel(counter)
        let sampler = Task { () -> Int in
            var highest = 0
            while !Task.isCancelled {
                highest = max(highest, counter.outstanding)
                try? await Task.sleep(for: .milliseconds(1))
            }
            return highest
        }
        for _ in 0..<40 {
            let result: Result<SmallSpanJudge.Verdict, ModelCallFailure> = await model.respondResult(
                instructions: "", prompt: "", generating: SmallSpanJudge.Verdict.self, options: .greedy,
                budget: .seconds(5), abandoned: counter)
            #expect(result == .success(SmallSpanJudge.Verdict(meaning: .same)))
            #expect(counter.outstanding == 0 && counter.inFlight == 0)
        }
        sampler.cancel()
        #expect(await sampler.value == 0)
        #expect(model.highestSeenInside == 0)
        #expect(model.highestInFlightInside == 1)
    }

    @Test("a finished call has given its slot back before the caller runs on: back-to-back calls with one slot free are never refused")
    func slotIsReleasedBeforeTheCallerResumes() async {
        let counter = AbandonedCalls()
        // One of the two slots is taken by a call left behind, so a slot still held by the call that just answered
        // would make the next call hit the limit.
        #expect(counter.tryBegin())
        counter.abandoned()
        #expect(counter.outstanding == 1)
        let model = ProbingModel(counter)
        for round in 0..<1_000 {
            let result: Result<SmallSpanJudge.Verdict, ModelCallFailure> = await model.respondResult(
                instructions: "", prompt: "", generating: SmallSpanJudge.Verdict.self, options: .greedy,
                budget: .seconds(5), abandoned: counter)
            guard result == .success(SmallSpanJudge.Verdict(meaning: .same)) else {
                Issue.record("round \(round) got \(result)"); return
            }
            guard counter.inFlight == 0 else { Issue.record("round \(round): the finished call still holds its slot"); return }
        }
        #expect(counter.outstanding == 1)
    }

    @Test("the rerank call and the grammar verifier count against the same limit")
    func auxiliaryCallsAreCounted() async {
        let counter = AbandonedCalls()
        let reranked = await SmartCleaner.rerank(
            using: StubbornModel(), raw: "a b c", rules: "a b c", model: "a b", remaining: .milliseconds(400), abandoned: counter)
        #expect(reranked == nil)
        #expect(counter.outstanding == 1)
        let verified = await GeneralGrammarVerifier.assess(
            model: StubbornModel(), transcript: "a b c", rulesDraft: "a b c", candidate: "a b",
            budget: .milliseconds(300), abandoned: counter)
        #expect(verified == nil)
        #expect(counter.outstanding == 2)
        // The limit is shared: a cleanup call is now refused outright.
        let refused: Result<SmallSpanJudge.Verdict, ModelCallFailure> = await StubbornModel().respondResult(
            instructions: "", prompt: "", generating: SmallSpanJudge.Verdict.self, options: .greedy,
            budget: .milliseconds(300), abandoned: counter)
        #expect(refused == .failure(.notResponding))
    }

    // MARK: Repeated failure is remembered, visibly

    @Test("the real caps: Clean 4 s and Polished 5 s in short attempts, never longer than the ordinary limit")
    func realCaps() {
        #expect(SmartCleaner.callLimit(ordinary: .seconds(6), shortAttempt: true, polished: false) == .seconds(4))
        #expect(SmartCleaner.callLimit(ordinary: .seconds(8), shortAttempt: true, polished: true) == .seconds(5))
        #expect(SmartCleaner.callLimit(ordinary: .seconds(6), shortAttempt: false, polished: false) == .seconds(6))
        #expect(SmartCleaner.callLimit(ordinary: .seconds(3), shortAttempt: true, polished: false) == .seconds(3))
        #expect(SmartCleaner.failedDictationsBeforeShortAttempts == 2 && SmartCleaner.fullAttemptEvery == 3)
    }

    @Test("a model that answers in a steady in-between time recovers: every third dictation gets the full allowance")
    func slowButWorkingModelRecovers() async {
        let model = SwitchModel(.hang)
        let cleaner = SmartCleaner(
            budget: .milliseconds(800), correctionBudget: .milliseconds(800), polishedBudget: .milliseconds(800),
            segmentBudget: .milliseconds(800), model: model, health: ModelHealth(),
            shortAttemptCeilings: (.milliseconds(300), .milliseconds(300)))
        let options = CleanupOptions(level: .clean)
        _ = await cleaner.clean(short, options: options)
        _ = await cleaner.clean(short, options: options)
        #expect(await cleaner.currentFailureStreak == 2)
        // Now the model answers, but takes 0.5 s: longer than the short cap, shorter than the full one.
        model.mode = .answer(after: .milliseconds(500))
        let third = await cleaner.clean(short, options: options)
        let fourth = await cleaner.clean(short, options: options)
        #expect(third.groups[0].shortAttempt && third.groups[0].outcome == .timeout)
        #expect(fourth.groups[0].shortAttempt && fourth.groups[0].outcome == .timeout)
        let fifth = await cleaner.clean(short, options: options)
        #expect(!fifth.groups[0].shortAttempt)
        #expect(fifth.groups[0].outcome == .used)
        #expect(await cleaner.currentFailureStreak == 0)
        let sixth = await cleaner.clean(short, options: options)
        #expect(sixth.groups[0].outcome == .used && !sixth.groups[0].shortAttempt)
    }

    @Test("only a dictation where every attempt timed out counts; a refusal or an error in between ends the streak")
    func streakRules() async {
        let model = SwitchModel(.hang)
        let cleaner = SmartCleaner(
            budget: .milliseconds(300), correctionBudget: .milliseconds(300), polishedBudget: .milliseconds(300),
            segmentBudget: .milliseconds(300), model: model, health: ModelHealth())
        let options = CleanupOptions(level: .clean)
        _ = await cleaner.clean(short, options: options)
        #expect(await cleaner.currentFailureStreak == 1)
        model.mode = .refuse
        _ = await cleaner.clean(short, options: options)
        #expect(await cleaner.currentFailureStreak == 0)
        model.mode = .hang
        _ = await cleaner.clean(short, options: options)
        let again = await cleaner.clean(short, options: options)
        #expect(await cleaner.currentFailureStreak == 2)
        #expect(!again.groups[0].shortAttempt)
        model.mode = .fail
        _ = await cleaner.clean(short, options: options)
        #expect(await cleaner.currentFailureStreak == 0)
    }

    @Test("a dictation that never asks the model leaves the streak alone")
    func neverAskedLeavesItAlone() async {
        let model = SwitchModel(.hang)
        let cleaner = SmartCleaner(
            budget: .milliseconds(300), correctionBudget: .milliseconds(300), polishedBudget: .milliseconds(300),
            segmentBudget: .milliseconds(300), model: model, health: ModelHealth())
        _ = await cleaner.clean(short, options: CleanupOptions(level: .clean))
        _ = await cleaner.clean(short, options: CleanupOptions(level: .clean))
        _ = await cleaner.clean(short, options: CleanupOptions(level: .verbatim))
        #expect(await cleaner.currentFailureStreak == 2)
    }

    @Test("dictations are accounted in the order they started, not the order they finished")
    func accountedInStartOrder() async {
        let model = SwitchModel(.answer(after: .zero))
        model.slowMarker = "slowone"
        let cleaner = SmartCleaner(
            budget: .milliseconds(300), correctionBudget: .milliseconds(300), polishedBudget: .milliseconds(300),
            segmentBudget: .milliseconds(300), model: model, health: ModelHealth())
        let options = CleanupOptions(level: .clean)
        let slow = Task { await cleaner.clean("slowone we need to finish the report", options: options) }
        try? await Task.sleep(for: .milliseconds(100))
        let fast = await cleaner.clean("we need to finish the report before friday", options: options)
        #expect(fast.groups[0].outcome == .used)
        _ = await slow.value
        // The slow one started first and failed; the fast one started second and answered: streak 0, not 1.
        #expect(await cleaner.currentFailureStreak == 0)
    }

    // MARK: A backend that keeps hanging

    @Test("with calls left behind and still stuck, no further call is started, and the record says so")
    func boundedAbandonedCalls() async {
        let model = LateReturnModel(returnsAfter: .milliseconds(2_500))
        let cleaner = SmartCleaner(
            budget: .milliseconds(300), correctionBudget: .milliseconds(300), polishedBudget: .milliseconds(300),
            segmentBudget: .milliseconds(300), model: model, health: ModelHealth())
        let options = CleanupOptions(level: .clean)
        let first = await cleaner.clean(short, options: options)
        #expect(first.groups[0].outcome == .timeout)
        #expect(first.groups[0].retries == 1)
        #expect(cleaner.abandonedCalls.outstanding == 2)
        for _ in 0..<5 {
            let output = await cleaner.clean(short, options: options)
            #expect(output.groups[0].outcome == .notResponding)
            #expect(output.text.lowercased().contains("finish the report"))
            #expect(CleanupOutcomeSummary(groups: output.groups, level: .clean)?.plainLine.contains("not responding") == true)
        }
        #expect(cleaner.abandonedCalls.outstanding <= SmartCleaner.maximumAbandoned)
        #expect(model.started == 2)
        // Once the stuck calls return, the model is asked again.
        for _ in 0..<1_000 where cleaner.abandonedCalls.outstanding > 0 { try? await Task.sleep(for: .milliseconds(10)) }
        #expect(cleaner.abandonedCalls.outstanding == 0)
        let later = await cleaner.clean(short, options: options)
        #expect(later.groups[0].outcome == .timeout)
    }



    @Test("after two timed-out dictations the next makes one short attempt, says so, and recovery is immediate")
    func shortAttemptsAfterRepeatedFailure() async {
        let model = PacedModel(delay: .milliseconds(1_600))
        let budget: Duration = .milliseconds(400)
        let cleaner = SmartCleaner(
            budget: budget, correctionBudget: budget, polishedBudget: budget, segmentBudget: budget,
            model: model, health: ModelHealth())
        let options = CleanupOptions(level: .clean)
        let first = await cleaner.clean(short, options: options)
        let second = await cleaner.clean(short, options: options)
        #expect(first.groups[0].retries == 1 && !first.groups[0].shortAttempt)
        #expect(second.groups[0].retries == 1 && !second.groups[0].shortAttempt)

        let third = await cleaner.clean(short, options: options)
        #expect(third.groups[0].outcome == .timeout)
        #expect(third.groups[0].retries == 0)
        #expect(third.groups[0].shortAttempt)
        let summary = CleanupOutcomeSummary(groups: third.groups, level: .clean)
        #expect(summary?.code == "timeout-short")
        #expect(summary?.plainLine.contains("tried once") == true)
        #expect(CleanupOutcomeSummary(code: "timeout-short") == summary)

        // One answer ends it: no session-long switch-off, nothing to reset by hand.
        model.delay = .milliseconds(5)
        let recovered = await cleaner.clean(short, options: options)
        #expect(recovered.usedModel)
        let after = await cleaner.clean(short, options: options)
        #expect(!after.groups[0].shortAttempt)
    }
}

/// Never answers and never notices cancellation: the continuation is simply never resumed.
private final class StubbornModel: LanguageModel {
    var identifier: String { "stubborn" }
    var availability: LanguageModelAvailability { .available }
    func supportsLanguage(_ languageCode: String) -> Bool { true }
    func prewarm(instructions: String) {}
    func prefixCache(instructions: String) async {}
    func respond(
        instructions: String, prompt: String, schema: GenerationSchemaSpec, options: LanguageModelOptions
    ) async throws -> String {
        await withUnsafeContinuation { (_: UnsafeContinuation<Void, Never>) in }
        return ""
    }
}

/// Behaviour chosen per test, and changed between dictations.
private final class SwitchModel: LanguageModel {
    enum Mode: Sendable { case hang, refuse, fail, answer(after: Duration) }
    private let state = Mutex<(mode: Mode, slowMarker: String?)>((.hang, nil))
    init(_ mode: Mode) { state.withLock { $0.mode = mode } }
    var mode: Mode {
        get { state.withLock { $0.mode } }
        set { state.withLock { $0.mode = newValue } }
    }
    /// A prompt containing this text hangs, whatever the mode says.
    var slowMarker: String? {
        get { state.withLock { $0.slowMarker } }
        set { state.withLock { $0.slowMarker = newValue } }
    }
    var identifier: String { "switch" }
    var availability: LanguageModelAvailability { .available }
    func supportsLanguage(_ languageCode: String) -> Bool { true }
    func prewarm(instructions: String) {}
    func prefixCache(instructions: String) async {}
    func respond(
        instructions: String, prompt: String, schema: GenerationSchemaSpec, options: LanguageModelOptions
    ) async throws -> String {
        let (mode, marker) = state.withLock { ($0.mode, $0.slowMarker) }
        if let marker, prompt.contains(marker) { try await Task.sleep(for: .seconds(30)) }
        switch mode {
        case .hang: try await Task.sleep(for: .seconds(30)); return ""
        case .refuse: throw LanguageModelError.refused("scripted")
        case .fail: throw LanguageModelError.malformedOutput("scripted")
        case .answer(let delay):
            if delay > .zero { try await Task.sleep(for: delay) }
            return #"{"text": "We need to finish the report before Friday."}"#
        }
    }
}

/// Ignores cancellation, and returns on its own after `returnsAfter`: a stuck backend that eventually frees up.
private final class LateReturnModel: LanguageModel {
    private let delay: Duration
    private let count = Mutex(0)
    init(returnsAfter: Duration) { delay = returnsAfter }
    var started: Int { count.withLock { $0 } }
    var identifier: String { "late" }
    var availability: LanguageModelAvailability { .available }
    func supportsLanguage(_ languageCode: String) -> Bool { true }
    func prewarm(instructions: String) {}
    func prefixCache(instructions: String) async {}
    func respond(
        instructions: String, prompt: String, schema: GenerationSchemaSpec, options: LanguageModelOptions
    ) async throws -> String {
        count.withLock { $0 += 1 }
        let seconds = Double(delay.components.seconds) + Double(delay.components.attoseconds) / 1e18
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            DispatchQueue.global().asyncAfter(deadline: .now() + seconds) { continuation.resume() }
        }
        return #"{"text": "We need to finish the report."}"#
    }
}

/// The first call fails as "busy" after 100 ms; every later call hangs until cancelled. Records when the first
/// call started and when the second was cancelled, on the clock that does not run while the Mac sleeps.
private final class BusyThenHangModel: LanguageModel {
    private struct State { var calls = 0; var firstStart: SuspendingClock.Instant?; var secondCancelled: SuspendingClock.Instant? }
    private let state = Mutex(State())
    var firstStart: SuspendingClock.Instant? { state.withLock { $0.firstStart } }
    var secondCancelled: SuspendingClock.Instant? { state.withLock { $0.secondCancelled } }
    var identifier: String { "busy-then-hang" }
    var availability: LanguageModelAvailability { .available }
    func supportsLanguage(_ languageCode: String) -> Bool { true }
    func prewarm(instructions: String) {}
    func prefixCache(instructions: String) async {}
    func respond(
        instructions: String, prompt: String, schema: GenerationSchemaSpec, options: LanguageModelOptions
    ) async throws -> String {
        let call = state.withLock { state -> Int in
            state.calls += 1
            if state.calls == 1 { state.firstStart = .now }
            return state.calls
        }
        if call == 1 {
            try await Task.sleep(for: .milliseconds(100))
            throw LanguageModelError.busy("scripted")
        }
        do { try await Task.sleep(for: .seconds(60)) } catch {
            state.withLock { $0.secondCancelled = .now }
            throw error
        }
        return ""
    }
}

/// Answers at once, and reports what the shared counter looked like while the call was running.
private final class ProbingModel: LanguageModel {
    private let counter: AbandonedCalls
    private struct State { var highestSeen = 0; var highestInFlight = 0 }
    private let state = Mutex(State())
    init(_ counter: AbandonedCalls) { self.counter = counter }
    var highestSeenInside: Int { state.withLock { $0.highestSeen } }
    var highestInFlightInside: Int { state.withLock { $0.highestInFlight } }
    var identifier: String { "probing" }
    var availability: LanguageModelAvailability { .available }
    func supportsLanguage(_ languageCode: String) -> Bool { true }
    func prewarm(instructions: String) {}
    func prefixCache(instructions: String) async {}
    func respond(
        instructions: String, prompt: String, schema: GenerationSchemaSpec, options: LanguageModelOptions
    ) async throws -> String {
        state.withLock { state in
            state.highestSeen = max(state.highestSeen, counter.outstanding)
            state.highestInFlight = max(state.highestInFlight, counter.inFlight)
        }
        return #"{"meaning": "same"}"#
    }
}

/// Answers every call about the first `answers` distinct sentences (as `PacedModel` does, after `delay`) and never answers
/// the ones after, ignoring cancellation. A sentence can take more than one call (a retry, a tie-break).
private final class AnswerThenHangModel: LanguageModel {
    private let seen = Mutex<[String]>([])
    private let paced: PacedModel
    private let answers: Int
    init(answers: Int, delay: Duration) { self.answers = answers; paced = PacedModel(delay: delay) }
    var identifier: String { "answer-then-hang" }
    var availability: LanguageModelAvailability { .available }
    func supportsLanguage(_ languageCode: String) -> Bool { true }
    func prewarm(instructions: String) {}
    func prefixCache(instructions: String) async {}
    func respond(
        instructions: String, prompt: String, schema: GenerationSchemaSpec, options: LanguageModelOptions
    ) async throws -> String {
        let id = Regex.firstMatch(prompt, "Part number [0-9]+").map { (prompt as NSString).substring(with: $0.range) } ?? prompt
        let known = seen.withLock { ids -> Bool in
            if !ids.contains(id) { ids.append(id) }
            return ids.firstIndex(of: id)! < answers
        }
        if !known {
            await withUnsafeContinuation { (_: UnsafeContinuation<Void, Never>) in }
            return ""
        }
        return try await paced.respond(instructions: instructions, prompt: prompt, schema: schema, options: options)
    }
}
