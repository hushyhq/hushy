import Foundation
import MurmurCore
import Synchronization
import Testing
@testable import Murmur

/// A recogniser that answers from a script, so a take can have words. The release pass (`transcribeWithConfidence`)
/// waits until `openRelease()` and then returns the words or fails; a cancellation while it waits throws, as a
/// recognition does when its take is cancelled. The plain `transcribe` is the re-read of a cancelled take.
final class ScriptedTranscriber: Transcriber, @unchecked Sendable {
    enum AfterRelease { case words, failure }
    struct Failure: Error {}

    private struct State {
        var releasePasses = 0
        var rereads = 0
        var isReleaseOpen = false
        var isRereadOpen = true
    }

    let words: String
    private let afterRelease: AfterRelease
    private let state = Mutex(State())

    /// `rereadGated` holds every re-read until `openReread()`, as a long recording keeps the recogniser busy. A
    /// cancellation while it waits throws, as a recognition does when its take is cancelled.
    init(words: String = "ship it on thursday", afterRelease: AfterRelease = .words, rereadGated: Bool = false) {
        self.words = words
        self.afterRelease = afterRelease
        state.withLock { $0.isRereadOpen = !rereadGated }
    }

    var releasePasses: Int { state.withLock { $0.releasePasses } }
    var rereads: Int { state.withLock { $0.rereads } }
    func openRelease() { state.withLock { $0.isReleaseOpen = true } }
    func openReread() { state.withLock { $0.isRereadOpen = true } }

    func transcribe(_ samples: [Float]) async throws -> String {
        state.withLock { $0.rereads += 1 }
        while !state.withLock({ $0.isRereadOpen }) { try await Task.sleep(for: .milliseconds(5)) }
        return words
    }

    func transcribeWithConfidence(_ samples: [Float], vocabulary: VocabularyContext) async throws -> TranscriptionResult {
        state.withLock { $0.releasePasses += 1 }
        while !state.withLock({ $0.isReleaseOpen }) { try await Task.sleep(for: .milliseconds(5)) }
        switch afterRelease {
        case .words: return TranscriptionResult(text: words)
        case .failure: throw Failure()
        }
    }
}

/// What Esc during recognition leaves behind: the take's words, read again from the recording without making the next
/// take wait. Same isolation as `DictationRecoveryControllerTests`: no microphone, no event tap, an in-memory store,
/// a throwaway defaults suite and a scripted recogniser, so nothing is delivered, pasted or copied.
@Suite("Esc during recognition keeps the take", .serialized, .timeLimit(.minutes(1)))
@MainActor
struct EscRereadControllerTests {
    typealias Harness = DictationRecoveryControllerTests.Harness

    @Test("Esc while the recording is being read keeps the words, read from the recording again")
    func escDuringProcessingKeepsTheWords() async throws {
        let harness = try Harness()
        let transcriber = ScriptedTranscriber()
        harness.controller.transcriber = transcriber
        harness.controller.finishForTests(samples: Harness.speech)
        #expect(await harness.eventually { transcriber.releasePasses == 1 })
        harness.controller.handle(.cancel)
        #expect(await harness.eventually { harness.rows.count == 1 && !harness.controller.isBusy })
        let row = try #require(harness.rows.first)
        #expect(row.status == .cancelled)
        #expect(row.rawText == transcriber.words, "the take's own words, not an empty row")
        #expect(row.text.lowercased().contains("ship it on thursday"))
        #expect(DictationRecovery.action(for: row) == .copy, "Recover has something to copy")
        #expect(transcriber.rereads == 1)
    }

    @Test("the re-read of a cancelled take waits while another recognition has the lane, and the take is kept after")
    func rereadWaitsForTheLane() async throws {
        let harness = try Harness()
        let transcriber = ScriptedTranscriber()
        harness.controller.transcriber = transcriber
        harness.controller.finishForTests(samples: Harness.speech)
        #expect(await harness.eventually { transcriber.releasePasses == 1 })
        let lane = harness.controller.recogniserLane
        let nextTake = Task { try await lane.exclusive { try await Task.sleep(for: .seconds(2)) } }
        defer { nextTake.cancel() }
        try await Task.sleep(for: .milliseconds(30))
        harness.controller.handle(.cancel)
        try await Task.sleep(for: .milliseconds(300))
        #expect(transcriber.rereads == 0, "the next take's recognition is running; the re-read does not start")
        #expect(harness.rows.isEmpty)
        _ = try await nextTake.value
        #expect(await harness.eventually { harness.rows.count == 1 })
        #expect(harness.rows.first?.rawText == transcriber.words)
        #expect(transcriber.rereads == 1)
    }

    @Test("the re-read of a cancelled take does not start while a dictation is under way, even with the lane free")
    func rereadWaitsForAnIdleController() async throws {
        let harness = try Harness()
        let transcriber = ScriptedTranscriber()
        transcriber.openRelease()
        let isDeliveryOpen = Mutex(false)
        harness.controller.transcriber = transcriber
        harness.controller.delivery = DictationDelivery(
            deliver: { _, _, _ in
                while !isDeliveryOpen.withLock({ $0 }) { try? await Task.sleep(for: .milliseconds(5)) }
                return TextInserter.Delivered(result: .copied(.app), answer: .noField, field: nil, lateLanding: nil)
            },
            clipboard: LateLandingControllerTests.ClipboardRecorder().clipboard)
        harness.controller.finishForTests(samples: Harness.speech)
        #expect(await harness.eventually { transcriber.releasePasses == 1 })
        try await Task.sleep(for: .milliseconds(200))
        #expect(harness.controller.isBusy, "the take is waiting to be delivered; the recogniser lane is free")
        let controller = harness.controller
        let reread = Task { @MainActor in await controller.rereadCancelled(Harness.speech) }
        try await Task.sleep(for: .milliseconds(600))
        #expect(transcriber.rereads == 0)
        isDeliveryOpen.withLock { $0 = true }
        #expect(await reread.value == transcriber.words)
        #expect(transcriber.rereads == 1)
    }

    @Test("a take begun while a re-read waits for the lane gets its drafts, and the re-read runs after")
    func aNewTakeGetsItsDraftsWhileARereadWaits() async throws {
        let harness = try Harness()
        let transcriber = ScriptedTranscriber(rereadGated: true)
        harness.controller.transcriber = transcriber
        let controller = harness.controller
        let lane = controller.recogniserLane
        let isLaneReleased = Mutex(false)
        let running = Task {
            try await lane.exclusive { while !isLaneReleased.withLock({ $0 }) { try await Task.sleep(for: .milliseconds(5)) } }
        }
        defer { running.cancel() }
        try await Task.sleep(for: .milliseconds(30))
        let reread = Task { @MainActor in await controller.rereadCancelled(Harness.speech) }
        try await Task.sleep(for: .milliseconds(60))
        #expect(transcriber.rereads == 0, "the lane is busy, so the re-read waits in it")
        controller.handle(.pressed)
        controller.startPending = true
        isLaneReleased.withLock { $0 = true }
        _ = try await running.value
        #expect(await lane.claimDraft(), "the new take's first draft")
        await lane.releaseDraft()
        try await Task.sleep(for: .milliseconds(60))
        #expect(await lane.claimDraft(), "and its next: the re-read is not waiting for a gap between drafts")
        await lane.releaseDraft()
        #expect(transcriber.rereads == 0)
        controller.startPending = false
        #expect(await harness.eventually { transcriber.rereads == 1 }, "the controller is idle again, so the re-read goes on")
        transcriber.openReread()
        #expect(await reread.value == transcriber.words)
    }

    @Test("a re-read already running when a take begins is cancelled and runs again once the controller is idle")
    func aRunningRereadStepsAsideForANewTake() async throws {
        let harness = try Harness()
        let transcriber = ScriptedTranscriber(rereadGated: true)
        harness.controller.transcriber = transcriber
        let controller = harness.controller
        let lane = controller.recogniserLane
        let reread = Task { @MainActor in await controller.rereadCancelled(Harness.speech) }
        #expect(await harness.eventually { transcriber.rereads == 1 }, "the re-read holds the lane")
        controller.handle(.pressed)
        controller.startPending = true
        var claimed = false
        for _ in 0..<200 where !claimed {
            claimed = await lane.claimDraft()
            if !claimed { try await Task.sleep(for: .milliseconds(10)) }
        }
        #expect(claimed, "the new take's draft is not refused for the whole of an old take's re-read")
        await lane.releaseDraft()
        #expect(transcriber.rereads == 1)
        controller.startPending = false
        #expect(await harness.eventually { transcriber.rereads == 2 })
        transcriber.openReread()
        #expect(await reread.value == transcriber.words, "the take's words are not lost to the interruption")
    }

    @Test("Esc while the recording is being read keeps a take History can read again")
    func escDuringProcessingKeepsTheTake() async throws {
        try #require(Harness.hasTempHome, "needs a temp HUSHY_HOME; never writes audio to the real one")
        let harness = try Harness(keepAudio: true)
        harness.controller.finishForTests(samples: Harness.speech)
        harness.controller.handle(.cancel)
        #expect(await harness.eventually { harness.rows.count == 1 && !harness.controller.isBusy })
        let row = try #require(harness.rows.first)
        #expect(row.status == .cancelled)
        let path = try #require(row.audioPath, "the audio is kept, as the audio setting says")
        #expect(FileManager.default.fileExists(atPath: path))
        #expect(DictationRecovery.action(for: row) == .retryTranscription, "no words yet, so History offers to read it again")
        try? FileManager.default.removeItem(atPath: path)
    }

    @Test("with audio kept off, Esc leaves no audio file and the take is a text row only")
    func escWithAudioOffWritesNoAudio() async throws {
        let harness = try Harness(keepAudio: false)
        harness.controller.finishForTests(samples: Harness.speech)
        harness.controller.handle(.cancel)
        #expect(await harness.eventually { !harness.controller.isBusy })
        try await Task.sleep(for: .milliseconds(300))
        #expect(harness.rows.allSatisfy { $0.audioPath == nil }, "the audio setting is honoured for cancelled takes too")
    }
}
