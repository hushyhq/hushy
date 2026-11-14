import Foundation
import MurmurCore
import Synchronization
import Testing
@testable import Murmur

@Suite("Diarizer fallbacks")
struct SpeakerDiarizerFallbackTests {
    @Test("Nemotron's turns are used when it found someone speaking")
    func usesNemotronTurns() {
        let turns = [DiarizationTurn(speakerLabel: "S1", start: 0, end: 4)]
        #expect(SpeakerDiarizer.usable(turns, noteId: 1) == turns)
    }

    @Test("an empty Nemotron answer, like a failed one, sends the note to the legacy diarizer")
    func emptyFallsBack() {
        #expect(SpeakerDiarizer.usable([], noteId: 1) == nil)
        #expect(SpeakerDiarizer.usable(nil, noteId: 1) == nil)
    }

    @Test("after a failed download the next notes do not try again until the wait is over")
    func backsOffAfterFailure() {
        let start = Date(timeIntervalSince1970: 1_000_000)
        var gate = ModelLoadBackoff()
        #expect(gate.mayTry(at: start))
        gate.failed(at: start)
        #expect(!gate.mayTry(at: start.addingTimeInterval(1)), "the very next note")
        #expect(!gate.mayTry(at: start.addingTimeInterval(9 * 60)))
        #expect(gate.mayTry(at: start.addingTimeInterval(10 * 60)))
    }

    @Test("each failure in a row waits longer, up to six hours; a load that works clears it")
    func waitGrowsThenClears() {
        let start = Date(timeIntervalSince1970: 1_000_000)
        var gate = ModelLoadBackoff()
        gate.failed(at: start)
        gate.failed(at: start)
        #expect(gate.retryAt == start.addingTimeInterval(30 * 60))
        for _ in 0..<10 { gate.failed(at: start) }
        #expect(gate.retryAt == start.addingTimeInterval(6 * 3600))
        gate.succeeded()
        #expect(gate.mayTry(at: start))
        gate.failed(at: start)
        #expect(gate.retryAt == start.addingTimeInterval(10 * 60), "the next failure starts the wait over")
    }

    @Test("offline, the legacy diarizer tries its download once, not again for each meeting until the wait is over")
    func legacyBacksOffOffline() async throws {
        let start = Date(timeIntervalSince1970: 1_000_000)
        let attempts = Mutex(0), clock = Mutex(start)
        let diarizer = SpeakerDiarizer(
            downloadLegacyModels: {
                attempts.withLock { $0 += 1 }
                throw URLError(.notConnectedToInternet)
            },
            now: { clock.withLock { $0 } })
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("diarize-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        try WAVWriter.write([Float](repeating: 0.1, count: 16_000), to: folder.appendingPathComponent("chunk-0000.wav"), key: nil)
        let store = try Store()
        let note = try store.save(Note(title: "meeting", status: .ready, audioPath: folder.path))
        let words = [MurmurCore.WordTiming(word: "hello", start: 0, end: 0.5)]
        for _ in 0..<3 {
            #expect(await !assemble(diarizer, note, words, store))
        }
        #expect(attempts.withLock { $0 } == 1, "three meetings, one download attempt")
        clock.withLock { $0 = start.addingTimeInterval(ModelLoadBackoff.firstWait) }
        _ = await assemble(diarizer, note, words, store)
        #expect(attempts.withLock { $0 } == 2, "once the wait is over it tries again")
    }

    /// A mic-only meeting's assembling step: with no diarization nothing is saved.
    private func assemble(_ diarizer: SpeakerDiarizer, _ note: Note, _ words: [MurmurCore.WordTiming], _ store: Store) async -> Bool {
        await diarizer.assembleAndSave(
            note: note, micWords: words, systemWords: [], isTwoChannel: false, ownerName: nil, diarize: true,
            clean: { $0 }, store: store, loadAudio: { _ in [Float](repeating: 0.1, count: 16_000) })
    }
}
