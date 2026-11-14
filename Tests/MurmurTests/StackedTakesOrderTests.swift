import Foundation
import MurmurCore
import Observation
import Synchronization
import Testing
@testable import Murmur

/// Takes stacked behind a stuck take, checked against a stall of the main actor and against later takes that are
/// ready before the earlier one. Under full-suite load the test process stalls for a moment at a time; these tests
/// make that stall happen at a chosen instant (`stallOnNextModeRead`), so a failure that showed up only under load
/// shows up on every run.
@Suite("Stacked takes keep their own audio and their order", .serialized, .timeLimit(.minutes(2)))
@MainActor
struct StackedTakesOrderTests {
    typealias Harness = DictationRecoveryControllerTests.Harness

    /// How long the main actor is held, past the half second that would round a take's length up a second.
    private nonisolated static let stall: TimeInterval = 0.6

    /// Blocks the main actor once, inside the next take handed in: reading its settings consumes the one-shot manual
    /// mode, and the change is reported synchronously, between the take's start stamp and its length being taken.
    /// The override names no mode, so the take's settings are what they would have been.
    private func stallOnNextModeRead(_ harness: Harness) -> Locked<Bool> {
        let fired = Locked(false)
        harness.settings.manualModeOverrideID = UUID()
        withObservationTracking { _ = harness.settings.manualModeOverrideID } onChange: {
            fired.withLock { $0 = true }
            Thread.sleep(forTimeInterval: Self.stall)
        }
        return fired
    }

    private func record(_ harness: Harness) -> () -> [String] {
        let events = Locked<[String]>([])
        harness.controller.processStartedForTests = { seconds, _ in
            events.withLock { $0.append("start \(Int(seconds.rounded()))") }
        }
        harness.controller.processEndedForTests = { seconds in
            events.withLock { $0.append("end \(Int(seconds.rounded()))") }
        }
        return { events.withLock { $0 } }
    }

    @Test("a stall while the second of three stacked takes is handed in does not make it look like the third")
    func stallInsideTheSecondTake() async throws {
        let harness = try Harness()
        let events = record(harness)
        harness.controller.startsWithoutHardwareForTests = true
        #expect(await harness.controller.recogniserLane.claimDraft())
        harness.controller.finishForTests(samples: Harness.speech, heldFor: 2)
        harness.controller.handle(.pressed)
        let fired = stallOnNextModeRead(harness)
        harness.controller.finishForTests(samples: Harness.speech, heldFor: 3)
        #expect(fired.withLock { $0 }, "the main actor was held inside the take's hand-in")
        harness.controller.handle(.pressed)
        harness.controller.finishForTests(samples: Harness.speech, heldFor: 4)

        await harness.controller.recogniserLane.releaseDraft()
        #expect(await harness.eventually(within: .seconds(10)) { harness.rows.count == 3 && !harness.controller.isBusy })
        #expect(events() == ["start 2", "end 2", "start 3", "end 3", "start 4", "end 4"])
        #expect(harness.rows.map { Int($0.durationSeconds.rounded()) } == [2, 3, 4], "each row keeps its own take's length")
    }

    @Test("a stall while the stuck take is handed in leaves its length, and the take behind it waits")
    func stallInsideTheStuckTake() async throws {
        let harness = try Harness()
        var started: [Int] = []
        harness.controller.processStartedForTests = { seconds, _ in started.append(Int(seconds.rounded())) }
        harness.controller.startsWithoutHardwareForTests = true
        #expect(await harness.controller.recogniserLane.claimDraft())
        let fired = stallOnNextModeRead(harness)
        harness.controller.finishForTests(samples: Harness.speech, heldFor: 2)
        #expect(fired.withLock { $0 })
        harness.controller.handle(.pressed)
        harness.controller.finishForTests(samples: Harness.speech, heldFor: 3)
        try await Task.sleep(for: .milliseconds(300))
        #expect(started == [2], "the second take has not begun while the first is held")

        await harness.controller.recogniserLane.releaseDraft()
        #expect(await harness.eventually(within: .seconds(10)) { started.count == 2 && !harness.controller.isBusy })
        #expect(started == [2, 3])
    }

    @Test("later takes whose words are ready first are still pasted after the stuck one, each once, with its own words")
    func laterTakesReadyFirstWaitTheirTurn() async throws {
        let harness = try Harness()
        let transcriber = WordsByLength(held: Self.tone(seconds: 2).count)
        harness.controller.transcriber = transcriber
        harness.controller.releaseDeadline = { _ in .seconds(600) }
        let pasted = Locked<[String]>([])
        harness.controller.delivery = DictationDelivery(
            deliver: { text, _, _ in
                pasted.withLock { $0.append(text) }
                return TextInserter.Delivered(result: .pasted, answer: .field, field: nil, lateLanding: nil)
            },
            clipboard: LateLandingClipboard(isUntouched: { true }, copy: { _ in }))
        harness.controller.startsWithoutHardwareForTests = true

        harness.controller.finishForTests(samples: Self.tone(seconds: 2), heldFor: 2)
        #expect(await harness.eventually { transcriber.passes == 1 }, "the first take is held in its recognition")
        harness.controller.handle(.pressed)
        harness.controller.finishForTests(samples: Self.tone(seconds: 3), heldFor: 3)
        harness.controller.handle(.pressed)
        harness.controller.finishForTests(samples: Self.tone(seconds: 4), heldFor: 4)
        try await Task.sleep(for: .milliseconds(300))
        #expect(transcriber.passes == 1, "the later takes, ready at once, did not run ahead of the held one")
        #expect(pasted.withLock { $0 }.isEmpty)

        transcriber.release()
        #expect(await harness.eventually(within: .seconds(10)) { harness.rows.count == 3 && !harness.controller.isBusy })
        let words = pasted.withLock { $0 }.map { $0.lowercased() }
        #expect(words.count == 3, "each take was pasted exactly once")
        #expect(zip(words, WordsByLength.words).allSatisfy { $0.contains($1) },
                "pasted in the order spoken, each with its own words: \(words)")
        #expect(harness.rows.map { Int($0.durationSeconds.rounded()) } == [2, 3, 4])
        #expect(transcriber.passes == 3)
    }

    /// A clear tone of the given length: it passes the speech gate, and its length tells the takes apart.
    static func tone(seconds: Int) -> [Float] {
        (0..<(16_000 * seconds)).map { 0.2 * sin(2 * Float.pi * 220 * Float($0) / 16_000) }
    }
}

/// A value shared with `@Sendable` callbacks; copyable, unlike `Mutex`, so it can be handed back.
final class Locked<Value: Sendable>: Sendable {
    private let mutex: Mutex<Value>
    init(_ value: Value) { mutex = Mutex(value) }
    func withLock<R>(_ body: (inout Value) -> R) -> R { mutex.withLock { body(&$0) } }
}

/// A recogniser that knows each take by its audio's length, answers at once, and holds one take until `release()`.
final class WordsByLength: Transcriber, @unchecked Sendable {
    static let words = ["alpha", "bravo", "charlie"]
    private let held: Int
    private let state = Mutex((passes: 0, isReleased: false))

    init(held: Int) { self.held = held }

    var passes: Int { state.withLock { $0.passes } }
    func release() { state.withLock { $0.isReleased = true } }

    func transcribe(_ samples: [Float]) async throws -> String {
        Self.words[min(Self.words.count - 1, max(0, samples.count / 16_000 - 2))] + " report is ready"
    }

    func transcribeWithConfidence(_ samples: [Float], vocabulary: VocabularyContext) async throws -> TranscriptionResult {
        state.withLock { $0.passes += 1 }
        if samples.count == held {
            while !state.withLock({ $0.isReleased }) { try await Task.sleep(for: .milliseconds(5)) }
        }
        return TranscriptionResult(text: try await transcribe(samples))
    }
}
