import Foundation
import MurmurCore
import Synchronization
import Testing
@testable import Murmur

/// Diarization of a finished meeting yields to a dictation (meetings T4b): it feeds one side window by window and
/// waits before each window while a dictation is in progress, keeping its speaker state, so a pause loses or repeats
/// nothing.
@Suite("Streamed diarization yields to dictation", .timeLimit(.minutes(1)))
struct StreamedDiarizationTests {
    /// Counts what it was fed; one frame per 160 samples (10 ms at 16 kHz), one "speaker".
    final class Recording: StreamingDiarizerSession, @unchecked Sendable {
        let fed = Mutex<[Float]>([])
        var windows: Int { fedWindows.withLock { $0 } }
        let fedWindows = Mutex(0)
        private var carried = 0

        func feed(_ samples: [Float]) throws -> (probabilities: [Float], frames: Int) {
            fed.withLock { $0 += samples }
            fedWindows.withLock { $0 += 1 }
            carried += samples.count
            let frames = carried / 160
            carried -= frames * 160
            return ([Float](repeating: 1, count: frames), frames)
        }

        func finish() throws -> (probabilities: [Float], frames: Int) {
            let frames = carried > 0 ? 1 : 0
            carried = 0
            return ([Float](repeating: 1, count: frames), frames)
        }
    }

    @Test("a dictation that starts mid-way pauses the feed at the next window; afterwards every sample arrives once, in order")
    func pausesAndResumes() async throws {
        let side = (0..<48_000).map { Float($0 % 1_000) / 1_000 }
        let audio = SideAudio.constant(side, window: 8_000)
        let session = Recording()
        let activity = ForegroundActivity()
        let resumed = Mutex(false)
        let run = Task {
            try await StreamedDiarization.run(audio.windows(.system), session: session, yield: {
                if session.windows == 2 { activity.set(busy: true) }   // the key press lands after the second window
                await activity.waitUntilIdle(pollInterval: .milliseconds(5))
                if session.windows == 2 { resumed.withLock { $0 = true } }
            })
        }
        while !activity.isBusy { try await Task.sleep(for: .milliseconds(5)) }
        try await Task.sleep(for: .milliseconds(200))
        #expect(session.windows == 2, "no window is fed while the dictation is in progress")
        activity.set(busy: false)
        let result = try await run.value
        #expect(resumed.withLock { $0 })
        #expect(session.fed.withLock { $0 } == side, "every sample fed once, in order")
        #expect(result.samples == side.count)
        #expect(result.windows == 6)
        #expect(result.frames == side.count / 160)
    }

    @Test("windows from the journal are the side on the note clock, so frame times match the turns' word times")
    func journalWindowsAreTheTimeline() async throws {
        let store = try Store()
        let note = try store.save(Note(title: "call", status: .processing))
        let id = try #require(note.id)
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("diarize-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        for seq in 0..<4 {
            let name = CaptureJournalWriter.fileName(seq: seq, stream: .system)
            let appender = try HsegAppender(creating: folder.appendingPathComponent(name), key: nil)
            try appender.append([Float](repeating: 0.25, count: 32_000))
            try appender.close()
            _ = try store.insertSegment(CaptureSegment(
                noteId: id, stream: .system, seq: seq, kind: .audio, t0: Double(seq) * 3, duration: 2, sampleCount: 32_000,
                file: name, format: .hseg1, state: .transcribed))
        }
        let journal = try store.captureJournal(noteId: id)
        let audio = SideAudio.journal(journal, folder: folder, key: nil, readLegacy: FinalizeRunner.readLegacy)
        let session = Recording()
        let result = try await StreamedDiarization.run(audio.windows(.system), session: session, yield: {})
        let whole = try audio.whole(.system)
        #expect(session.fed.withLock { $0 } == whole)
        #expect(result.samples == 11 * 16_000, "four 2 s segments 3 s apart: 11 s on the note clock")
        #expect(audio.hasAudio(.system))
        #expect(!audio.hasAudio(.mic))
    }
}
