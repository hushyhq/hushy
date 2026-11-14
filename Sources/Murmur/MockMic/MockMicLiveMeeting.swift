#if DEBUG
import Foundation
import MurmurCore

/// The meeting screens' path through a real recording: a line typed a few seconds in, the consent
/// note, the capture check and the transcript progress while recording, then the page built from
/// what was stored and a replay from the typed line's moment. Nothing here is the UI; it is what
/// the UI reads, checked on the same `NoteRecorder` and store the app uses.
struct MockMicLiveMeeting {
    var typedLine: MeetingJot?
    var consentKept = false
    var microphoneHeard = false
    var transcribedBeforeStop: Double = 0
    var liveTurns = 0
}

extension MockMicHarness {
    static let typedLineAfter: Duration = .seconds(6)
    static let typedLine = "budget question for later"

    /// Types one line and taps "I said it", as a person would a few seconds into the call.
    func typeDuringMeeting(_ noteID: Int64) async -> MockMicLiveMeeting {
        var live = MockMicLiveMeeting()
        try? await Task.sleep(for: Self.typedLineAfter)
        live.typedLine = try? rig.store.addJot(noteId: noteID, text: Self.typedLine, atSeconds: rig.recorder.elapsedSeconds)
        try? rig.store.recordConsent(MeetingConsent(noteId: noteID, method: .saidAloud))
        live.consentKept = (try? rig.store.consent(forNote: noteID)) != nil
        return live
    }

    /// A real `NoteRecorder` recording with speaker labels off (so nothing is downloaded), checked
    /// the way the meeting screens read it. Moments need speaker turns, so that check is left to
    /// the full scenario.
    func runMeetingPageWithoutSpeakers(_ meeting: MockMicManifest.Meeting) async -> MockMicScenarioResult {
        let id = "meeting.\(meeting.id).page", title = "Meeting page from a real recording (no speaker model)"
        let start = ContinuousClock.now
        FeatureFlags.source.set(false, forKey: "feature.speakerLabels")
        defer { FeatureFlags.source.removeObject(forKey: "feature.speakerLabels") }
        do {
            try await rig.prepareSpeech()
            let files = try resolve(meeting.wavs)
            guard rig.verifiedDeviceID() != nil else { throw MockMicRecordingError.failed("capture device could not be verified") }
            try await rig.recorder.start()
            guard let noteID = rig.recorder.activeNote?.id else { throw MockMicRecordingError.noNote }
            try await Task.sleep(for: Self.captureLeadIn)
            let typing = Task { await self.typeDuringMeeting(noteID) }
            try await config.player.play(files)
            try await Task.sleep(for: Self.captureTail)
            var live = await typing.value
            live.microphoneHeard = rig.recorder.capture?.microphoneLastHeard != nil
            live.transcribedBeforeStop = rig.recorder.transcribedSeconds
            live.liveTurns = rig.recorder.liveTurns.count
            rig.recorder.stop()
            try await waitUntil("note ready", Self.readyTimeout) {
                let status = try self.rig.store.note(id: noteID)?.status
                if status == .failed { throw MockMicRecordingError.failed("the note finished as failed") }
                return status == .ready
            }
            guard let note = try rig.store.note(id: noteID) else { throw MockMicRecordingError.noNote }
            let recorded = MockMicRecorded(note: note, rows: [], offset: 0, captureSilent: false,
                                           readySeconds: mockMicSeconds(since: start), diarizationSeconds: 0, live: live)
            let checks = meetingPageChecks(recorded, needsMoments: false)
            return MockMicScenarioResult(
                id: id, title: title, status: MockMicReport.status(for: checks), seconds: mockMicSeconds(since: start),
                detail: "\(note.wordCount) words, ready in \(String(format: "%.1f", recorded.readySeconds)) s",
                checks: checks, metrics: ["readySeconds": recorded.readySeconds, "transcribedBeforeStop": live.transcribedBeforeStop],
                texts: nil)
        } catch {
            return failed(id, title, error, seconds: mockMicSeconds(since: start))
        }
    }

    /// The checks a meeting page must pass for a recorded meeting.
    func meetingPageChecks(_ recorded: MockMicRecorded, needsMoments: Bool = true) -> [MockMicCheck] {
        let note = recorded.note
        let id = note.id ?? 0
        let lines = MeetingLine.lines(from: recorded.rows)
        let page = MeetingPage.build(
            rows: StoredSummaryDigest().rows(for: note), lines: lines, jots: (try? rig.store.jots(noteId: id)) ?? [],
            doneIndexes: [], myNames: MeetingPage.myNames(userName: ""))
        let typed = page.yourNotes.first
        let replay = note.audioPath.flatMap { path -> Data? in
            let key = rig.encryption.currentKey
            let spans = MeetingAudioPlayer.spans(in: URL(fileURLWithPath: path, isDirectory: true), key: key)
            return MeetingAudioPlayer.excerpt(spans: spans, from: recorded.live.typedLine?.atSeconds ?? 0, key: key)
        }
        let clipSeconds = note.durationSeconds
        let timed: [MockMicCheck] = needsMoments ? [
            check("typed line opens its moment", typed?.moment?.lineIndex != nil,
                  typed?.moment.map { "\($0.label), line \($0.lineIndex.map(String.init) ?? "none")" } ?? "no moment"),
            check("page has a timed transcript", page.hasTimedTranscript, "\(page.transcript.count) lines"),
        ] : [check("transcript stored", !note.transcript.isEmpty, "\(note.wordCount) words")]
        return timed + [
            check("typed line kept as yours", typed?.text == Self.typedLine && typed?.author == .you, typed?.text ?? "none"),
            check("consent note kept", recorded.live.consentKept, recorded.live.consentKept ? "said aloud" : "missing"),
            check("capture check heard the microphone", recorded.live.microphoneHeard, recorded.live.microphoneHeard ? "heard" : "never heard"),
            check("written down while recording", clipSeconds < NoteRecorder.chunkSeconds + 5 || recorded.live.transcribedBeforeStop > 0,
                  String(format: "%.0f s of %.0f s, %d live turns", recorded.live.transcribedBeforeStop, clipSeconds, recorded.live.liveTurns)),
            check("replay from the typed line has audio", (replay?.count ?? 0) > HistoryPlaybackAudio.headerByteCount,
                  "\(replay?.count ?? 0) bytes"),
        ]
    }
}
#endif
