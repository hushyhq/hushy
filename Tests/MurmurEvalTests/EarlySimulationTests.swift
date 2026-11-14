import Foundation
import Testing
@testable import MurmurCore
@testable import murmur_eval

/// The clock `murmur-eval early-clean` runs a dictation on: when a recogniser pass runs, which groups get a model call
/// before the key release, and what is still running at it.
@Suite("Early cleanup study: the simulated clock")
struct EarlySimulationTests {
    /// Ten words each: two make a group.
    private let sentences = (1...8).map { "The report for region number \($0) is ready for review." }
    private func text(_ count: Int) -> String { sentences.prefix(count).joined(separator: " ") }
    private func heard(_ t: Double, _ count: Int, ms: Double = 100) -> EarlyRecords.Heard { .init(t: t, text: text(count), ms: ms) }

    @Test("passes start at the first tick at or after the first-pass time and never overlap")
    func passSchedule() {
        let ticks = stride(from: 2.0, through: 20.0, by: 2.0).map { heard($0, 2, ms: $0 == 12 ? 2_500 : 100) }
        let passes = EarlySimulation.passes(ticks, first: 9, stretch: 0, tick: 2)
        #expect(passes.map(\.start) == [10, 12, 16, 18, 20])
        #expect(passes[1].ready == 14.5)
    }

    @Test("with a stretch the gap between passes grows with the length of the recording")
    func stretchedSchedule() {
        let ticks = stride(from: 2.0, through: 60.0, by: 2.0).map { heard($0, 2) }
        let passes = EarlySimulation.passes(ticks, first: 10, stretch: 0.25, tick: 2)
        #expect(passes.map(\.start) == [10, 14, 18, 24, 30, 38, 48, 60])
    }

    @Test("a pass still running at the release holds the final pass for what is left of it")
    func blockedByARunningPass() {
        let passes = [EarlySimulation.Transcript(start: 10, ready: 10.3, text: ""), .init(start: 12, ready: 12.4, text: "")]
        #expect(abs(EarlySimulation.blocked(passes, release: 12.1) - 0.3) < 1e-9)
        #expect(EarlySimulation.blocked(passes, release: 13) == 0)
        #expect(EarlySimulation.blocked(passes, release: 11) == 0)
    }

    @Test("a group is cleaned when its transcript is ready and the model is free, one call at a time")
    func callsAreSerial() async {
        let transcripts = [EarlySimulation.Transcript(start: 20, ready: 20.1, text: text(6))]
        let outcome = await EarlySimulation.run(transcripts, release: 30, sightings: 1) { _ in 0.5 }
        #expect(outcome.calls.map { ($0.start * 10).rounded() } == [201, 206])
        #expect(outcome.started.count == 2)
        #expect(outcome.inFlight == 0)
        #expect(outcome.transcripts == 1)
    }

    @Test("no call starts at or after the release, and one running across it is counted as in flight")
    func nothingStartsAfterTheRelease() async {
        let transcripts = [EarlySimulation.Transcript(start: 20, ready: 20.1, text: text(6))]
        let outcome = await EarlySimulation.run(transcripts, release: 20.4, sightings: 1) { _ in 0.5 }
        #expect(outcome.calls.count == 1)
        #expect(abs(outcome.inFlight - 0.2) < 1e-9)
    }

    @Test("a transcript that is not ready before the release is never heard")
    func lateTranscriptIsNotHeard() async {
        let transcripts = [EarlySimulation.Transcript(start: 20, ready: 20.5, text: text(6))]
        let outcome = await EarlySimulation.run(transcripts, release: 20.4, sightings: 1) { _ in 0.5 }
        #expect(outcome.calls.isEmpty)
        #expect(outcome.transcripts == 0)
    }

    @Test("a group waiting behind a long call is withdrawn when a newer transcript rewrites it")
    func waitingGroupWithdrawn() async {
        let rewritten = text(6).replacingOccurrences(of: "number 3 is", with: "number three is")
        let transcripts = [
            EarlySimulation.Transcript(start: 20, ready: 20, text: text(6)), .init(start: 22, ready: 22, text: rewritten),
        ]
        let outcome = await EarlySimulation.run(transcripts, release: 40, sightings: 1) { _ in 3 }
        #expect(outcome.started.count == 2)
        #expect(outcome.started[1].contains("number three"))
        #expect(outcome.withdrawn == 1)
    }

    @Test("today's app hears nothing before the first tick at or after fifteen seconds, then only confirmed text that grew")
    func legacyTranscripts() {
        let states = [
            EarlyRecords.Sliding(t: 14, confirmed: "", volatile: "a"), .init(t: 16, confirmed: "", volatile: "a"),
            .init(t: 24, confirmed: "a", volatile: "b"), .init(t: 26, confirmed: "a", volatile: "b"),
            .init(t: 36, confirmed: "a b", volatile: "c"),
        ]
        let heard = EarlySimulation.legacyTranscripts(states, activation: 15)
        #expect(heard.map(\.text) == ["a", "a b"])
        #expect(heard.map(\.ready) == [24, 36])
        #expect(EarlySimulation.volatileTranscripts(states).map(\.text) == ["a", "a b", "a b c"])
    }

    @Test("the text-only stand-ins follow speaking pace and the while-speaking recogniser's chunking")
    func textStandIns() {
        let words = (1...100).map { "w\($0)" }.joined(separator: " ")
        let spoken = EarlySimulation.spokenSoFar(words, wordsPerSecond: 2.5, tick: 2)
        #expect(spoken.seconds == 40)
        #expect(spoken.transcripts.first?.text == "w1 w2 w3 w4 w5")
        #expect(spoken.transcripts.count == 19)
        let sliding = EarlySimulation.slidingSoFar(words, wordsPerSecond: 2.5, tick: 2)
        // Nothing is decoded before 13 s; the first chunk (27 words) is confirmed when the second is decoded at 24 s.
        #expect(sliding.first { $0.t == 12 }?.volatile == "")
        #expect(sliding.first { $0.t == 14 }?.confirmed == "")
        #expect(TextStats.wordCount(sliding.first { $0.t == 14 }?.volatile ?? "") == 27)
        #expect(TextStats.wordCount(sliding.first { $0.t == 24 }?.confirmed ?? "") == 27)
    }

    @Test("pauses go after every so many words and never after the last")
    func pausedSpeech() {
        #expect(EarlyTextRunner.paused("a b c d e f", ms: 500, every: 2) == "a b [[slnc 500]] c d [[slnc 500]] e f")
        #expect(EarlyTextRunner.paused("a b c", ms: 0, every: 2) == "a b c")
    }

    @Test("arm names")
    func armNames() {
        #expect(EarlyCleanRunner.ArmSpec("ref")?.kind == .ref)
        #expect(EarlyCleanRunner.ArmSpec("legacy")?.kind == .legacy)
        #expect(EarlyCleanRunner.ArmSpec("early:prefix:2")?.kind == .early(.prefix, sightings: 2))
        #expect(EarlyCleanRunner.ArmSpec("early:volatile:1")?.kind == .early(.volatile, sightings: 1))
        #expect(EarlyCleanRunner.ArmSpec("early:prefix") == nil)
        #expect(EarlyCleanRunner.ArmSpec("early:other:1") == nil)
    }
}
