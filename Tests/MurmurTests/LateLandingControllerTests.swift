import Foundation
import MurmurCore
import Synchronization
import Testing
@testable import Murmur

/// What the controller does with the second look at a paste into a known field. Same isolation as
/// `DictationRecoveryControllerTests`: no microphone, no event tap, an in-memory store and a throwaway defaults
/// suite. The recogniser is scripted and the delivery is replaced, so nothing is pasted into an app and the real
/// clipboard is never read or written: the clipboard is a recorder.
@Suite("Never losing a take, through the dictation controller", .serialized, .timeLimit(.minutes(1)))
@MainActor
struct LateLandingControllerTests {
    typealias Harness = DictationRecoveryControllerTests.Harness

    /// The clipboard as the second look sees it.
    @MainActor
    final class ClipboardRecorder {
        var copied: [String] = []
        var isUntouched = true
        var clipboard: LateLandingClipboard {
            LateLandingClipboard(isUntouched: { self.isUntouched }, copy: { self.copied.append($0) })
        }
    }

    private func insertedRow(_ harness: Harness) throws -> Dictation {
        try harness.store.save(Dictation(rawText: "ship it", text: "Ship it.", durationSeconds: 2, status: .inserted))
    }

    /// A controller whose recogniser says `words` and whose delivery pastes into a known field and offers `look`
    /// as the second look. `looks` counts how many times the controller ran it.
    private func pasting(
        _ harness: Harness, transcriber: ScriptedTranscriber = ScriptedTranscriber(), recorder: ClipboardRecorder,
        look: (@MainActor () async -> LateLanding)?
    ) {
        harness.controller.transcriber = transcriber
        harness.controller.delivery = DictationDelivery(
            deliver: { _, _, _ in TextInserter.Delivered(result: .pasted, answer: .field, field: nil, lateLanding: look) },
            clipboard: recorder.clipboard)
        transcriber.openRelease()
    }

    // MARK: The second look

    @Test("a paste the second look finds missing is listed as not pasted, put on the clipboard, and shown on the card")
    func lostPasteIsRecoverable() async throws {
        let harness = try Harness()
        let row = try insertedRow(harness)
        let recorder = ClipboardRecorder()
        await harness.controller.settleLateLanding({ .notLanded }, text: "Ship it.", savedID: row.id, clipboard: recorder.clipboard)
        #expect(recorder.copied == ["Ship it."])
        #expect(harness.rows.first?.status == .notInserted)
        #expect(harness.pill.state == .noField(.copiedAutomaticallyUnconfirmed))
        #expect(HistoryAttention.isActionable(try #require(harness.rows.first)), "History now asks the person to look at it")
    }

    @Test("a confirmed or unreadable second look changes nothing")
    func otherLooksChangeNothing() async throws {
        let harness = try Harness()
        let row = try insertedRow(harness)
        for look in [LateLanding.confirmed, .unreadable] {
            let recorder = ClipboardRecorder()
            await harness.controller.settleLateLanding({ look }, text: "Ship it.", savedID: row.id, clipboard: recorder.clipboard)
            #expect(recorder.copied.isEmpty, "\(look)")
            #expect(harness.rows.first?.status == .inserted, "\(look)")
            #expect(harness.pill.state == .idle, "\(look)")
        }
    }

    @Test("while another dictation runs, the row is marked but the clipboard and the pill are left to that dictation")
    func busyControllerKeepsTheClipboard() async throws {
        let harness = try Harness()
        let row = try insertedRow(harness)
        harness.controller.finishForTests(samples: Harness.speech)
        #expect(harness.controller.isBusy)
        let recorder = ClipboardRecorder()
        await harness.controller.settleLateLanding({ .notLanded }, text: "Ship it.", savedID: row.id, clipboard: recorder.clipboard)
        #expect(recorder.copied.isEmpty)
        #expect(harness.rows.first { $0.id == row.id }?.status == .notInserted)
        #expect(harness.pill.state == .processing())
    }

    @Test("a clipboard the person changed since the paste is never overwritten, and the card does not claim it was copied")
    func changedClipboardIsLeftAlone() async throws {
        let harness = try Harness()
        let row = try insertedRow(harness)
        let recorder = ClipboardRecorder()
        recorder.isUntouched = false
        await harness.controller.settleLateLanding({ .notLanded }, text: "Ship it.", savedID: row.id, clipboard: recorder.clipboard)
        #expect(recorder.copied.isEmpty)
        #expect(harness.pill.state == .idle)
        #expect(harness.rows.first?.status == .notInserted, "History still lists the take as not pasted, so the words stay recoverable")
    }

    @Test("a look that was cancelled never alarms, even if it came back saying not landed")
    func cancelledLookIsSilent() async throws {
        let harness = try Harness()
        let row = try insertedRow(harness)
        let recorder = ClipboardRecorder()
        let task = Task { @MainActor in
            await harness.controller.settleLateLanding(
                { try? await Task.sleep(for: .seconds(30)); return .notLanded },
                text: "Ship it.", savedID: row.id, clipboard: recorder.clipboard)
        }
        task.cancel()
        await task.value
        #expect(recorder.copied.isEmpty)
        #expect(harness.rows.first?.status == .inserted)
    }

    // MARK: A dictation hands the look over

    @Test("a finished take pasted into a known field runs the look TextInserter handed back, and acts on a lost paste")
    func processHandsTheLookOver() async throws {
        let harness = try Harness()
        let recorder = ClipboardRecorder()
        pasting(harness, recorder: recorder, look: { .notLanded })
        harness.controller.finishForTests(samples: Harness.speech)
        #expect(await harness.eventually { harness.rows.first?.status == .notInserted && !recorder.copied.isEmpty })
        let row = try #require(harness.rows.first)
        #expect(!row.text.isEmpty)
        #expect(recorder.copied == [row.text], "the cleaned words, not the raw ones")
        #expect(harness.pill.state == .noField(.copiedAutomaticallyUnconfirmed))
    }

    @Test("a take whose look says the text is there stays inserted, and one with no look to run is left as it was")
    func processLeavesAConfirmedPasteAlone() async throws {
        let looks: [(@MainActor () async -> LateLanding)?] = [{ .confirmed }, nil]
        for look in looks {
            let harness = try Harness()
            let recorder = ClipboardRecorder()
            pasting(harness, recorder: recorder, look: look)
            harness.controller.finishForTests(samples: Harness.speech)
            #expect(await harness.eventually { harness.rows.count == 1 && !harness.controller.isBusy })
            try await Task.sleep(for: .milliseconds(150))
            #expect(harness.rows.first?.status == .inserted)
            #expect(recorder.copied.isEmpty)
        }
    }

    @Test("the next dictation ends a look that is still running, and the look does not alarm afterwards")
    func nextDictationEndsTheLook() async throws {
        let harness = try Harness()
        let recorder = ClipboardRecorder()
        let sawCancellation = Mutex(false)
        pasting(harness, recorder: recorder, look: {
            do { try await Task.sleep(for: .seconds(30)) } catch { sawCancellation.withLock { $0 = true } }
            return .notLanded
        })
        harness.controller.finishForTests(samples: Harness.speech)
        #expect(await harness.eventually { harness.controller.lateLandingTask != nil && !harness.controller.isBusy })
        #expect(sawCancellation.withLock { $0 } == false, "the look is still polling")
        harness.controller.handle(.pressed)
        #expect(harness.controller.lateLandingTask == nil)
        #expect(await harness.eventually { sawCancellation.withLock { $0 } }, "pressing the key ended it")
        try await Task.sleep(for: .milliseconds(100))
        #expect(recorder.copied.isEmpty)
        #expect(harness.rows.first?.status == .inserted)
    }
}
