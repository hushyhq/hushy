import Foundation
import MurmurCore
import os

extension DictationController {
    /// Feeds one recording, while it is still going, to its `EarlyCleanupSession` and to the pill's `LiveDraftSession`.
    /// One tick a second drains the audio captured since the last tick: the draft gets it every tick, and the early
    /// session every second tick, all of it, exactly as when the tick came every two seconds. Owned per recording,
    /// so a late tick can never reach another recording's sessions.
    @MainActor
    final class StreamingCoordinator {
        private nonisolated static let log = Logger(subsystem: "app.hushy", category: "dictation")
        let recordingID: UUID
        private var session: EarlyCleanupSession?
        private var draft: LiveDraftSession?
        private var drainTimer: Timer?
        private var feedChain: Task<Void, Never> = Task {}
        /// Audio drained on an odd tick, waiting for the early session's two-second feed.
        private var pendingEarly: [Float] = []
        private var ticks = 0

        init(recordingID: UUID) {
            self.recordingID = recordingID
        }

        /// A single `Timer` (main-actor, like `NoteRecorder`'s `chunkTimer`), so there is exactly one place audio
        /// leaves `AudioCapture` for this recording. `drain()` only hands out what is new; `stop()` still returns
        /// the whole recording.
        func begin(session: EarlyCleanupSession?, draft: LiveDraftSession?, audio: AudioCapture) {
            guard session != nil || draft != nil else { return }
            self.session = session
            self.draft = draft
            drainTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
                Task { @MainActor in self?.drainAndFeed(audio) }
            }
        }

        private func drainAndFeed(_ audio: AudioCapture) {
            guard session != nil || draft != nil else { return }
            ticks += 1
            let fresh = audio.drain()
            pendingEarly.append(contentsOf: fresh)
            let early = ticks.isMultiple(of: 2) ? earlyFeed() : []
            guard !fresh.isEmpty || !early.isEmpty else { return }
            let session = self.session, draft = self.draft
            // Chained, so the audio always reaches each session in the order it was captured.
            feedChain = Task { [feedChain] in
                await feedChain.value
                if let draft, !fresh.isEmpty { await draft.add(fresh) }
                if let session, !early.isEmpty { await session.add(early) }
            }
        }

        private func earlyFeed() -> [Float] {
            defer { pendingEarly = [] }
            return session == nil ? [] : pendingEarly
        }

        /// Stops the ticks, closes the draft at once (it shows nothing more and no draft starts), and returns the
        /// early session (if there was one) for the caller to close.
        func detach() -> EarlyCleanupSession? {
            drainTimer?.invalidate()
            drainTimer = nil
            pendingEarly = []
            if let draft {
                draft.close()
                Task {
                    let line = Self.line(await draft.finish())
                    Self.log.notice("\(line, privacy: .public)")
                }
            }
            draft = nil
            let result = session
            session = nil
            return result
        }

        /// Counts and milliseconds, never a word.
        nonisolated static func line(_ stats: LiveDraftSession.Stats) -> String {
            "live draft: \(stats.passes) passes, \(stats.skippedBusy) skipped busy, \(stats.skippedSilent) silent, "
                + "\(stats.failures) failed, mean \(Int(stats.meanPassMs.rounded())) ms, "
                + "longest \(Int(stats.longestPassMs.rounded())) ms"
        }
    }
}
