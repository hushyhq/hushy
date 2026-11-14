import Foundation
import MurmurCore
import Testing
@testable import Murmur

/// When the pill may say it is hearing: a clock the test moves by hand, and levels fed in.
@Suite("Input cue: the pill says a headset is connecting until sound arrives")
@MainActor
struct InputCueTrackerTests {
    /// Each `sleep` waits for the next `advance`.
    private actor Clock {
        private var sleepers: [CheckedContinuation<Void, Never>] = []
        private var watchers: [CheckedContinuation<Void, Never>] = []
        private(set) var asked: [Duration] = []
        func sleep(_ duration: Duration) async {
            asked.append(duration)
            await withCheckedContinuation { continuation in
                sleepers.append(continuation)
                watchers.forEach { $0.resume() }
                watchers = []
            }
        }
        func waitForSleeper() async {
            if !sleepers.isEmpty { return }
            await withCheckedContinuation { watchers.append($0) }
        }
        func advance() {
            sleepers.forEach { $0.resume() }
            sleepers = []
        }
    }

    private final class Seen {
        var cues: [PillModel.InputCue] = []
        var heard = 0
    }

    private func tracker(_ clock: Clock, transport: InputTransport?, seen: Seen) -> InputCueTracker {
        let tracker = InputCueTracker(sleep: { await clock.sleep($0) })
        tracker.begin(transport: transport, show: { seen.cues.append($0) }, onHeard: { seen.heard += 1 })
        return tracker
    }

    /// Lets the tracker's task run up to its next wait.
    private func settle(_ clock: Clock) async {
        await clock.waitForSleeper()
        await Task.yield()
    }

    @Test("a headset that sends zeros past the grace: the pill says connecting, then hearing when sound arrives")
    func headsetConnects() async {
        let clock = Clock(), seen = Seen()
        let tracker = tracker(clock, transport: .bluetooth, seen: seen)
        #expect(seen.cues == [.hearing], "nothing is claimed during the grace")
        tracker.level(0)
        tracker.level(0)
        await clock.waitForSleeper()
        await clock.advance()
        await settle(clock)
        #expect(seen.cues == [.hearing, .connectingHeadset])
        #expect(await clock.asked.first == InputCueTracker.grace)
        tracker.level(0)
        #expect(seen.heard == 0, "zeros are not sound")
        tracker.level(0.000_4)
        #expect(seen.cues == [.hearing, .connectingHeadset, .hearing])
        #expect(seen.heard == 1)
        tracker.level(0.2)
        #expect(seen.heard == 1, "the start of sound is reported once")
        await clock.advance()
    }

    @Test("a headset whose sound arrives inside the grace never shows the cue")
    func headsetAlreadyUp() async {
        let clock = Clock(), seen = Seen()
        let tracker = tracker(clock, transport: .bluetooth, seen: seen)
        tracker.level(0.01)
        await clock.waitForSleeper()
        await clock.advance()
        await settle(clock)
        await clock.advance()
        #expect(seen.cues == [.hearing, .hearing])
        #expect(!seen.cues.contains(.connectingHeadset))
        #expect(seen.heard == 1)
    }

    @Test("any other microphone gets no cue, however long it is silent",
          arguments: [InputTransport.builtIn, .usb, .virtual, .aggregate, .other] as [InputTransport])
    func otherMicrophones(transport: InputTransport) async {
        let clock = Clock(), seen = Seen()
        let tracker = tracker(clock, transport: transport, seen: seen)
        tracker.level(0)
        #expect(seen.cues == [.hearing])
        #expect(await clock.asked.isEmpty, "no timer is even started")
        #expect(!InputCueTracker.waitsForSound(on: transport))
        tracker.level(0.1)
        #expect(seen.heard == 1)
    }

    @Test("an unknown microphone gets no cue")
    func unknownMicrophone() {
        #expect(!InputCueTracker.waitsForSound(on: nil))
        #expect(InputCueTracker.waitsForSound(on: .bluetooth))
    }

    @Test("a headset that never sends sound: the pill stops saying connecting after a few seconds")
    func givesUp() async {
        let clock = Clock(), seen = Seen()
        _ = tracker(clock, transport: .bluetooth, seen: seen)
        await clock.waitForSleeper()
        await clock.advance()
        await settle(clock)
        await clock.advance()
        for _ in 0..<5 { await Task.yield() }
        #expect(seen.cues == [.hearing, .connectingHeadset, .hearing])
        #expect(await clock.asked == [InputCueTracker.grace, InputCueTracker.giveUp - InputCueTracker.grace])
        #expect(seen.heard == 0, "and the start sound is never played for sound that never came")
    }

    @Test("the wait is bounded: after five seconds without sound the recording is told to end, once")
    func boundedWaitEndsTheRecording() async {
        let clock = Clock(), seen = Seen()
        var gaveUp = 0
        let tracker = InputCueTracker(sleep: { await clock.sleep($0) })
        tracker.begin(transport: .bluetooth, show: { seen.cues.append($0) }, onHeard: { seen.heard += 1 }, onGaveUp: { gaveUp += 1 })
        await clock.waitForSleeper()
        await clock.advance()
        await settle(clock)
        #expect(gaveUp == 0, "not at the grace")
        await clock.advance()
        for _ in 0..<5 { await Task.yield() }
        #expect(gaveUp == 1)
        #expect(InputCueTracker.giveUp == .seconds(5))
        tracker.level(0.01)
        #expect(gaveUp == 1)
    }

    @Test("sound that arrives in time means the recording is never ended for silence")
    func soundInTimeNeverGivesUp() async {
        let clock = Clock(), seen = Seen()
        var gaveUp = 0
        let tracker = InputCueTracker(sleep: { await clock.sleep($0) })
        tracker.begin(transport: .bluetooth, show: { seen.cues.append($0) }, onHeard: { seen.heard += 1 }, onGaveUp: { gaveUp += 1 })
        await clock.waitForSleeper()
        await clock.advance()
        await settle(clock)
        tracker.level(0.01)
        await clock.advance()
        for _ in 0..<5 { await Task.yield() }
        #expect(gaveUp == 0)
    }

    @Test("a recording that ended is left alone by its timer, and the next recording starts clean")
    func endedRecording() async {
        let clock = Clock(), seen = Seen()
        let tracker = tracker(clock, transport: .bluetooth, seen: seen)
        tracker.end()
        await clock.waitForSleeper()
        await clock.advance()
        for _ in 0..<5 { await Task.yield() }
        #expect(seen.cues == [.hearing, .hearing], "ending clears the cue, and the timer adds nothing")
        tracker.level(0.3)
        #expect(seen.heard == 0)

        let again = Seen()
        tracker.begin(transport: .bluetooth, show: { again.cues.append($0) }, onHeard: { again.heard += 1 })
        #expect(!tracker.hasHeardSound)
        tracker.level(0.3)
        #expect(again.heard == 1)
        await clock.advance()
    }

    @Test("the words, and that only the wait has any")
    func words() {
        #expect(PillModel.InputCue.hearing.label == nil)
        #expect(PillModel.InputCue.connectingHeadset.label == "Connecting to headset…")
    }
}
