import Foundation
import MurmurCore
import Testing
@testable import Murmur

/// The dictation controller never drops a take and never sticks. A press while the last take is still being written
/// records at once and only a real hold counts, so a brushed key or the second tap of a double tap opens nothing; the
/// recording's own take is written after the earlier one, in the order the words were spoken, and its clock starts when
/// its turn does. A stalled recogniser fails safe to the saved audio, Esc always returns to idle, and a thrown-away
/// recording leaves nothing behind for the next one.
///
/// A recogniser stall is made by holding the recogniser lane as a live-draft pass would (`claimDraft`): the release
/// pass then waits on the lane exactly as it does behind a hung draft. No microphone, event tap or focused app is
/// involved (`startsWithoutHardwareForTests`, `finishForTests`), and the engine has no model.
@Suite("The dictation controller never loses a take", .serialized, .timeLimit(.minutes(2)))
@MainActor
struct DictationNeverLosesATakeTests {
    typealias Harness = DictationRecoveryControllerTests.Harness

    private static let hold = DictationController.minimumHold + 0.1

    private func stalledTake(_ harness: Harness, heldFor seconds: TimeInterval = 2) async -> Bool {
        guard await harness.controller.recogniserLane.claimDraft() else { return false }
        harness.controller.finishForTests(samples: Harness.speech, heldFor: seconds)
        return harness.controller.isBusy
    }

    private func isProcessing(_ state: PillState) -> Bool {
        if case .processing = state { return true }
        return false
    }

    @Test("a press that is held while the last take is processing records at once, and the last take still finishes")
    func holdDuringProcessing() async throws {
        let harness = try Harness()
        #expect(await stalledTake(harness), "the first take is held in processing")
        harness.controller.startsWithoutHardwareForTests = true

        harness.controller.handle(.pressed)
        #expect(isProcessing(harness.pill.state), "until the key is held, the pill is still the last take's")
        #expect(await harness.eventually { harness.pill.state == .listening },
                "held past the minimum, the recording shows itself instead of being swallowed by the pill that is still writing")

        await harness.controller.recogniserLane.releaseDraft()
        #expect(await harness.eventually { harness.rows.count == 1 }, "the earlier take was not dropped when the next began")

        harness.controller.finishForTests(samples: Harness.speech, heldFor: 3)
        #expect(await harness.eventually { harness.rows.count == 2 && !harness.controller.isBusy })
    }

    @Test("a tap, a latch or a brushed key while the last take is processing opens no recording and leaves the key state alone")
    func tapDuringProcessingIsIgnored() async throws {
        let harness = try Harness()
        harness.controller.escapeGrace = .milliseconds(200)
        #expect(await stalledTake(harness))
        harness.controller.startsWithoutHardwareForTests = true

        // The second tap of a double tap that ended a hands-free recording: down, then a short release.
        harness.controller.handle(.pressed)
        harness.controller.handle(.latched, at: Date().addingTimeInterval(0.05))
        #expect(harness.hotkeys.isLatched == false, "no hands-free recording, so Enter is not swallowed")
        #expect(harness.hotkeys.isDictationActive, "Esc still reaches the take that is being written")
        #expect(isProcessing(harness.pill.state), "the last take keeps the pill")
        try await Task.sleep(for: .milliseconds(400))
        #expect(isProcessing(harness.pill.state), "the discarded tap did not show a listening pill later")

        // A latch event with no press at all, as a monitor that saw a tap while nothing could start sends.
        harness.hotkeys.isLatched = true
        harness.controller.handle(.latched)
        #expect(harness.hotkeys.isLatched == false)
        harness.controller.toggleHandsFree()
        #expect(isProcessing(harness.pill.state), "the menu's hands-free toggle starts nothing behind a take")

        harness.controller.handle(.cancel)
        #expect(await harness.eventually(within: .seconds(10)) { !harness.controller.isBusy }, "Esc cancels the take")
        #expect(await harness.eventually { harness.rows.map(\.status) == [.cancelled] })
        await harness.controller.recogniserLane.releaseDraft()
    }

    @Test("a take behind another waits for it and starts its clock only then")
    func aTakeBehindStartsItsClockAtItsTurn() async throws {
        let harness = try Harness()
        var started: [(seconds: Int, at: ContinuousClock.Instant)] = []
        harness.controller.processStartedForTests = { seconds, at in started.append((Int(seconds.rounded()), at)) }
        // The first take is held by the test, not by its deadline: the default 15 s is shorter than the 15 to 20 s
        // stalls of the whole test process under full-suite load, and a stall in the wait below would fail it.
        harness.controller.releaseDeadline = { _ in .seconds(600) }
        harness.controller.startsWithoutHardwareForTests = true
        #expect(await stalledTake(harness))
        harness.controller.handle(.pressed)
        let released = ContinuousClock.now
        harness.controller.finishForTests(samples: Harness.speech, heldFor: 3)
        try await Task.sleep(for: .milliseconds(600))
        #expect(started.map(\.seconds) == [2], "the second take has not begun while the first is held")

        await harness.controller.recogniserLane.releaseDraft()
        #expect(await harness.eventually(within: .seconds(10)) { started.count == 2 && !harness.controller.isBusy })
        let second = try #require(started.last)
        #expect(second.at - released >= .milliseconds(500),
                "its release instant, which bounds the cleanup model's time, was stamped after the wait")
    }

    @Test("takes stacked behind one stuck take are written in the order they were spoken once it lets go")
    func chainOfTakesIsWrittenInOrder() async throws {
        let harness = try Harness()
        var events: [String] = []
        harness.controller.processStartedForTests = { seconds, _ in events.append("start \(Int(seconds.rounded()))") }
        harness.controller.processEndedForTests = { seconds in events.append("end \(Int(seconds.rounded()))") }
        harness.controller.startsWithoutHardwareForTests = true
        #expect(await stalledTake(harness))
        harness.controller.handle(.pressed)
        harness.controller.finishForTests(samples: Harness.speech, heldFor: 3)
        harness.controller.handle(.pressed)
        harness.controller.finishForTests(samples: Harness.speech, heldFor: 4)

        await harness.controller.recogniserLane.releaseDraft()
        #expect(await harness.eventually(within: .seconds(10)) { harness.rows.count == 3 && !harness.controller.isBusy },
                "three takes, none held for a wait on a later take")
        #expect(events == ["start 2", "end 2", "start 3", "end 3", "start 4", "end 4"],
                "each take was delivered before the next one began")
    }

    @Test("a failure that lands in the moment before a hold is confirmed is still shown when the recording ends")
    func failureInTheHoldWindowSurvivesTheReveal() async throws {
        let harness = try Harness()
        harness.controller.releaseDeadline = { _ in .milliseconds(50) }
        harness.controller.startsWithoutHardwareForTests = true
        #expect(await stalledTake(harness))
        harness.controller.handle(.pressed)
        #expect(await harness.eventually(within: .seconds(10)) { harness.rows.map(\.status) == [.failed] },
                "the earlier take failed before the key had been held long enough to show")
        #expect(await harness.eventually { harness.pill.state == .listening }, "the hold was confirmed")

        harness.controller.handle(.cancel)
        #expect(harness.pill.state == .failed(.transcription(recordingKept: true)),
                "the reveal did not wipe the failure; its Try again is up once the pill is free")
        await harness.controller.recogniserLane.releaseDraft()
    }

    @Test("two takes that fail behind a newer recording are both shown, one after the other")
    func twoParkedFailuresAreBothShown() async throws {
        let harness = try Harness()
        harness.controller.releaseDeadline = { _ in .milliseconds(50) }
        harness.controller.startsWithoutHardwareForTests = true
        #expect(await stalledTake(harness))
        harness.controller.finishForTests(samples: Harness.speech, heldFor: 3)
        harness.controller.handle(.pressed)
        #expect(await harness.eventually(within: .seconds(10)) { harness.rows.count == 2 && harness.pill.state == .listening })
        harness.controller.handle(.cancel)

        let failed = PillState.failed(.transcription(recordingKept: true))
        #expect(harness.pill.state == failed, "the older failure first")
        harness.pill.dismissFailure()
        #expect(await harness.eventually { harness.pill.state == failed }, "then the next one, when the pill is free")
        harness.pill.dismissFailure()
        try await Task.sleep(for: .milliseconds(200))
        #expect(harness.pill.state == .idle, "and nothing more")
        await harness.controller.recogniserLane.releaseDraft()
    }

    @Test("a take left behind as stuck is saved as a failed row, and waking later neither saves nor delivers it again")
    func droppedStuckTakeIsKept() async throws {
        let harness = try Harness()
        harness.controller.releaseDeadline = { _ in .seconds(600) }
        harness.controller.turnSlack = .seconds(-599.6)
        #expect(await stalledTake(harness))
        harness.controller.finishForTests(samples: Harness.speech, heldFor: 3)

        #expect(await harness.eventually(within: .seconds(10)) { harness.rows.map(\.status) == [.failed] },
                "the stuck take was left behind, and its words are in History")

        await harness.controller.recogniserLane.releaseDraft()
        #expect(await harness.eventually(within: .seconds(10)) { harness.rows.count == 2 && !harness.controller.isBusy },
                "the take behind it was written")
        try await Task.sleep(for: .milliseconds(300))
        #expect(harness.rows.count == 2, "the stuck take waking up did not write a second row of its own")
        #expect(harness.pill.state == .failed(.transcription(recordingKept: true)),
                "the dropped take's Try again is offered")
    }

    @Test("a take that fails behind a newer recording leaves that recording's pill alone, and says so when the recording ends")
    func failingBehindWaitsForThePill() async throws {
        let harness = try Harness()
        harness.controller.releaseDeadline = { _ in .milliseconds(300) }
        #expect(await stalledTake(harness))
        harness.controller.startsWithoutHardwareForTests = true
        harness.controller.handle(.pressed)
        #expect(await harness.eventually { harness.pill.state == .listening })

        #expect(await harness.eventually(within: .seconds(10)) { harness.rows.map(\.status) == [.failed] },
                "the earlier take failed past its deadline and its audio is in History")
        #expect(harness.pill.state == .listening, "the failure did not replace the pill of the recording in progress")
        #expect(harness.controller.isBusy)

        harness.controller.handle(.cancel)
        #expect(harness.pill.state == .failed(.transcription(recordingKept: true)),
                "the person is told the earlier take failed, with its Try again, once the pill is free")
        #expect(!harness.controller.isBusy)
        await harness.controller.recogniserLane.releaseDraft()
    }

    @Test("a press that cannot start a recording leaves the take being written, and Esc, alone")
    func failedStartBehindATakeChangesNothing() async throws {
        let harness = try Harness()
        harness.controller.escapeGrace = .milliseconds(200)
        #expect(await stalledTake(harness))
        // Hardware checks are real here: the engine has no model, so a press cannot start.
        harness.controller.handle(.pressed)
        #expect(isProcessing(harness.pill.state), "no error row over the take that is being written")
        #expect(harness.hotkeys.isDictationActive, "Esc still reaches that take")

        harness.controller.handle(.cancel)
        #expect(await harness.eventually(within: .seconds(10)) { !harness.controller.isBusy })
        #expect(await harness.eventually { harness.rows.map(\.status) == [.cancelled] })
        await harness.controller.recogniserLane.releaseDraft()
    }

    @Test("while any take is still in flight the controller is busy, even when the newest one has been cancelled")
    func busyWhileATakeIsInFlight() async throws {
        let harness = try Harness()
        harness.controller.escapeGrace = .milliseconds(200)
        harness.controller.releaseDeadline = { _ in .seconds(600) }
        harness.controller.startsWithoutHardwareForTests = true
        #expect(await stalledTake(harness))
        harness.controller.handle(.pressed)
        harness.controller.finishForTests(samples: Harness.speech, heldFor: 3)
        harness.controller.handle(.cancel)
        try await Task.sleep(for: .milliseconds(600))
        #expect(harness.controller.isBusy, "the first take is still being written: History retry, voice actions and uninstall wait")
        await harness.controller.recogniserLane.releaseDraft()
        #expect(await harness.eventually(within: .seconds(10)) { !harness.controller.isBusy })
    }

    @Test("the recogniser's allowance is long enough for the waits inside the pass")
    func releaseAllowanceCoversTheWaitsInsideThePass() {
        #expect(DictationController.defaultReleaseDeadline(forAudio: 2) >= .seconds(15))
        #expect(DictationController.defaultReleaseDeadline(forAudio: 10_000) == .seconds(600))
    }

    @Test("Esc on a take and on the take behind it cancels both, not only the later one")
    func escapeOnTwoTakes() async throws {
        let harness = try Harness()
        harness.controller.escapeGrace = .seconds(30)
        harness.controller.releaseDeadline = { _ in .seconds(600) }
        harness.controller.startsWithoutHardwareForTests = true
        #expect(await stalledTake(harness))
        harness.controller.handle(.cancel)
        harness.controller.handle(.pressed)
        harness.controller.finishForTests(samples: Harness.speech, heldFor: 3)
        harness.controller.handle(.cancel)

        await harness.controller.recogniserLane.releaseDraft()
        #expect(await harness.eventually(within: .seconds(10)) { harness.rows.count == 2 && !harness.controller.isBusy })
        #expect(harness.rows.map(\.status) == [.cancelled, .cancelled], "the first Esc was not forgotten by the second")
    }

    @Test("a recogniser that never answers fails the take to its saved audio, and the controller is free again")
    func stalledRecogniserFailsSafe() async throws {
        let harness = try Harness()
        harness.controller.releaseDeadline = { _ in .milliseconds(300) }
        #expect(await stalledTake(harness))
        #expect(await harness.eventually(within: .seconds(10)) {
            harness.pill.state == .failed(.transcription(recordingKept: true)) && !harness.controller.isBusy
        }, "past the deadline the row offers Try again on the kept audio")
        #expect(await harness.eventually { harness.rows.map(\.status) == [.failed] })
        await harness.controller.recogniserLane.releaseDraft()
    }

    @Test("the release deadline covers the recogniser the controller is given, not only a wait for the lane")
    func stalledInjectedRecogniserFailsSafe() async throws {
        let harness = try Harness()
        let transcriber = ScriptedTranscriber()
        harness.controller.transcriber = transcriber
        harness.controller.releaseDeadline = { _ in .milliseconds(300) }
        harness.controller.finishForTests(samples: Harness.speech)
        #expect(await harness.eventually { transcriber.releasePasses == 1 }, "the pass reached the recogniser and hangs there")
        #expect(await harness.eventually(within: .seconds(10)) {
            harness.pill.state == .failed(.transcription(recordingKept: true)) && !harness.controller.isBusy
        })
        #expect(await harness.eventually { harness.rows.map(\.status) == [.failed] })
        #expect(transcriber.rereads == 0, "a failed take keeps its audio for Try again; it is not read as a cancelled one")
    }

    @Test("Esc on a take stuck in processing returns to idle, and the audio is kept")
    func escapeLeavesAStuckTake() async throws {
        let harness = try Harness()
        harness.controller.releaseDeadline = { _ in .seconds(600) }
        harness.controller.escapeGrace = .milliseconds(200)
        #expect(await stalledTake(harness))

        harness.controller.handle(.cancel)
        #expect(await harness.eventually(within: .seconds(10)) { !harness.controller.isBusy }, "Esc always gets out")
        #expect(harness.pill.state == .idle)
        #expect(await harness.eventually { harness.rows.map(\.status) == [.cancelled] }, "the words are not lost")

        await harness.controller.recogniserLane.releaseDraft()
        try await Task.sleep(for: .milliseconds(300))
        #expect(harness.rows.count == 1, "the stuck step waking up later does not save the take twice")
        #expect(!harness.controller.isBusy)
    }

    @Test("a cancelled or discarded recording leaves no live draft for the next one")
    func staleDraftIsCleared() throws {
        let harness = try Harness()
        harness.controller.startsWithoutHardwareForTests = true

        harness.controller.handle(.pressed)
        harness.controller.lastLiveDraftText = "words from a take that was cancelled"
        harness.controller.handle(.cancel)
        #expect(harness.controller.lastLiveDraftText == nil)

        harness.controller.handle(.pressed)
        harness.controller.lastLiveDraftText = "words from a tap that was discarded"
        harness.controller.handle(.released)
        #expect(harness.controller.lastLiveDraftText == nil)
        #expect(!harness.controller.isBusy)
    }
}
