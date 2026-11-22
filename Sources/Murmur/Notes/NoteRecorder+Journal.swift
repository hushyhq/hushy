import Foundation
import MurmurCore

/// The journal tick, capture health and live recognition of sealed segments.
extension NoteRecorder {
    /// Placeholder copy until the founder's batch review (decision #12 style); content-free.
    static let captureNoticeLine = "[placeholder]"

    /// One journal tick: each side's new audio to its segment file, health checked, sealed segments recognised.
    func tick() {
        guard let session, isRecording else { return }
        let mic = session.mic.drain()
        let call = session.callSource?.drain()
        let now = session.elapsed()
        session.account(mic: mic, call: call, at: now)
        resumeAfterSleep(session, at: now)
        handleHealth(session.health.evaluate(at: now), in: session, at: now)
        let journal = session.journal
        session.chain { [weak self] in
            do {
                let sealed = try await journal.tick(mic: mic, system: call)
                self?.recognize(sealed, in: session)
            } catch {
                self?.log.error("journal tick failed: \(error.localizedDescription)")
            }
        }
        persistDuration(session, at: now)
    }

    /// Ticks stop while the Mac sleeps with the lid closed. The time it slept is an `interrupted` gap on both sides,
    /// and health starts its clocks again, so waking is never reported as a dead side.
    private func resumeAfterSleep(_ session: CaptureSession, at now: Double) {
        let jump = now - session.lastTickAt
        session.lastTickAt = now
        guard jump > CaptureSession.sleepJump else { return }
        log.notice("recording resumed after \(Int(jump)) s without ticks (the Mac slept)")
        for stream in [CaptureStream.mic, .system] where session.source(stream) != nil {
            session.health.restarted(stream, at: now)
            session.recordGap(stream, at: now, reason: .interrupted) { [weak self] sealed in self?.recognize(sealed, in: session) }
        }
    }

    private func persistDuration(_ session: CaptureSession, at now: Double) {
        guard var note = activeNote else { return }
        note.durationSeconds = now
        activeNote = note
        guard now - session.lastPersistedDuration >= 10 else { return }
        session.lastPersistedDuration = now
        do { try store.setRecordingDuration(id: session.noteId, seconds: now) }
        catch { log.error("saving note duration failed: \(error.localizedDescription)") }
    }

    /// Stop and quit: the last audio to the journal, a stalled side's missing time as a gap, every segment sealed,
    /// and the note moved to `sealing` so a runner (now, or at the next launch) finishes it.
    func finishCapture(_ session: CaptureSession) async {
        let mic = session.mic.drain()
        let call = session.callSource?.drain()
        let now = session.elapsed()
        session.account(mic: mic, call: call, at: now)
        let journal = session.journal
        session.chain { [weak self] in
            do {
                let sealed = try await journal.tick(mic: mic, system: call)
                self?.recognize(sealed, in: session)
            } catch {
                self?.log.error("last journal tick failed: \(error.localizedDescription)")
            }
        }
        for stream in [CaptureStream.mic, .system] where session.health.problem(stream) == .stalled {
            session.recordGap(stream, at: now, reason: .stall) { [weak self] sealed in self?.recognize(sealed, in: session) }
        }
        session.chain { [weak self] in
            do {
                let sealed = try await journal.sealAll()
                self?.recognize(sealed, in: session)
            } catch {
                self?.log.error("sealing the journal failed: \(error.localizedDescription)")
            }
        }
        await session.waitForWrites()
        do {
            try store.setRecordingDuration(id: session.noteId, seconds: now)
            try store.advanceFinalize(noteId: session.noteId, from: .capturing, to: .sealing,
                                      pipelineVersion: Store.finalizePipelineVersion)
            try store.setNoteStatus(id: session.noteId, .processing)
        } catch {
            log.error("moving the note to sealing failed: \(error.localizedDescription)")
        }
    }

    // MARK: - Capture health

    func handleHealth(_ events: [CaptureHealth.Event], in session: CaptureSession, at now: Double) {
        for event in events {
            session.events.append(event)
            let problem = event.problem?.rawValue ?? "recovered"
            log.notice("capture health: \(event.stream.rawValue, privacy: .public) \(problem, privacy: .public) at \(Int(now)) s")
            switch event.problem {
            case .stalled:
                rebuild(event.stream, in: session, at: now, reason: "stalled")
            case .digitalSilence:
                // A reset tap delivers zeros (notes audit B4); one rebuild is worth it. A zeroed mic is warned only.
                if event.stream == .system { rebuild(.system, in: session, at: now, reason: "digital silence") }
            case nil:
                session.recordGap(event.stream, at: now, reason: .stall) { [weak self] sealed in
                    self?.recognize(sealed, in: session)
                }
            }
        }
        guard !events.isEmpty else { return }
        let micProblem = session.health.problem(.mic)
        let callProblem = session.health.problem(.system)
        capture?.microphoneProblem = micProblem
        capture?.callProblem = callProblem
        if micProblem != nil || callProblem != nil {
            pill.banner = .captureNotice(line: Self.captureNoticeLine)
        } else {
            clearCaptureNotice()
        }
    }

    private func rebuild(_ stream: CaptureStream, in session: CaptureSession, at now: Double, reason: String) {
        guard let source = session.source(stream), session.rebuilds < CaptureSession.maxRebuilds,
              now - (session.lastRebuild[stream] ?? -.infinity) >= CaptureSession.rebuildCooldown else { return }
        session.rebuilds += 1
        session.lastRebuild[stream] = now
        Task { [weak self] in
            let ok = await source.rebuild(reason: "capture health: \(reason)")
            session.health.restarted(stream, at: session.elapsed())
            self?.log.notice("capture health: rebuilt \(stream.rawValue, privacy: .public) (\(ok ? "up" : "failed", privacy: .public))")
        }
    }

    func clearCaptureNotice() {
        if case .captureNotice = pill.banner { pill.banner = nil }
    }

    // MARK: - Live recognition

    /// Recognises segments sealed during the recording, in order, both sides of a part at once.
    func recognize(_ sealed: [CaptureJournalWriter.Sealed], in session: CaptureSession) {
        guard !sealed.isEmpty, !session.isCancelled else { return }
        judgeSystemAudio(sealed, in: session)
        let transcriber = SegmentTranscriber(
            pipeline: pipeline, store: store, vocabulary: PipelineSettings(personalizer: personalizer).vocabulary,
            clean: Self.cleaner(level: settings.noteCleanupLevel))
        let previous = session.recognitions
        let noteId = session.noteId
        let foreground = finalizer.foreground
        session.recognitions = Task { @MainActor [weak self] in
            await previous?.value
            var outcomes: [(CaptureSegment, SegmentTranscriber.Outcome)] = []
            // One segment at a time, and a dictation in progress goes first before each: recognition waits for it,
            // never the other way round (both share the one speech engine).
            for part in sealed.sorted(by: { ($0.segment.seq, $0.segment.stream.rawValue) < ($1.segment.seq, $1.segment.stream.rawValue) }) {
                await foreground?.waitUntilIdle(pollInterval: .milliseconds(50))
                guard !session.isCancelled else { return }
                outcomes.append((part.segment, await transcriber.transcribe(part.segment, samples: part.samples)))
            }
            guard let self, !session.isCancelled else { return }
            self.showLive(outcomes, noteId: noteId)
        }
    }

    /// How far the recording has been written down. The turns themselves are in the store, where the live screen
    /// reads them (`LiveTurnReader`).
    private func showLive(_ outcomes: [(CaptureSegment, SegmentTranscriber.Outcome)], noteId: Int64) {
        for (segment, _) in outcomes {
            transcribedSeconds = max(transcribedSeconds, segment.t0 + segment.duration)
        }
        guard activeNote?.id == noteId, outcomes.contains(where: { if case .turn = $0.1 { true } else { false } }),
              let transcript = try? store.transcript(noteId: noteId) else { return }
        activeNote = activeNote?.caching(transcript)
        onChange?()
    }

    /// Learns from the first part with enough evidence whether macOS let Hushy hear the call's audio. Only for the
    /// real tap: what it learns is remembered in the app's defaults.
    private func judgeSystemAudio(_ sealed: [CaptureJournalWriter.Sealed], in session: CaptureSession) {
        guard !session.systemVerdictReached, session.callSource is CallNoteSource,
              let call = sealed.first(where: { $0.segment.stream == .system }),
              let mic = sealed.first(where: { $0.segment.stream == .mic }) else { return }
        let peak = call.samples.reduce(0) { max($0, abs($1)) }
        guard let verdict = SystemAudioVerdict.verdict(
            systemPeak: peak, systemSeconds: Double(call.samples.count) / AudioCapture.sampleRate,
            micRMS: StreamingResampler.rms(mic.samples)) else { return }
        session.systemVerdictReached = true
        SystemAudioCapture.remember(verdict)
        if verdict == .denied { log.error("call audio is silent while the mic hears speech: permission likely refused") }
    }
}
