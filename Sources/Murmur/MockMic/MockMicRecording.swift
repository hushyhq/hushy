#if DEBUG
import Foundation
import MurmurCore

/// One meeting as the real `NoteRecorder` stored it, plus what the harness measured around it.
struct MockMicRecorded {
    let note: Note
    let rows: [NoteSegmentWithSpeaker]
    /// Seconds from the start of the played clip to the same moment in the capture (note time = clip time + offset).
    let offset: Double
    let captureSilent: Bool
    let readySeconds: Double
    let diarizationSeconds: Double
    /// What the live meeting screen read while the clip played (`MockMicLiveMeeting`).
    var live = MockMicLiveMeeting()

    var speakers: [NoteSpeaker] {
        var seen = Set<Int64>()
        return rows.compactMap(\.speaker).filter { speaker in
            guard let id = speaker.id else { return false }
            return seen.insert(id).inserted
        }
    }

    var segments: [MockMicNoteSegment] {
        rows.compactMap { row in
            row.segment.speakerId.map {
                MockMicNoteSegment(speaker: String($0), start: row.segment.startTime, end: row.segment.endTime)
            }
        }
    }

    var transcript: String {
        let joined = rows.map(\.segment.text).joined(separator: " ")
        return joined.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? note.transcript : joined
    }
}

enum MockMicRecordingError: Error, CustomStringConvertible {
    case noNote, timedOut(String), failed(String)
    var description: String {
        switch self {
        case .noNote: "the recorder did not start a note"
        case .timedOut(let stage): "timed out waiting for \(stage)"
        case .failed(let why): why
        }
    }
}

extension MockMicHarness {
    static let readyTimeout: Duration = .seconds(240)
    static let diarizationTimeout: Duration = .seconds(240)
    /// Diarization saves the speakers, then (in the same task) the voice suggestions; give the second step time.
    static let suggestionSettle: Duration = .seconds(6)

    /// Starts `NoteRecorder`, plays the clip into the virtual device, stops, and waits for the note.
    func recordMeeting(_ meeting: MockMicManifest.Meeting) async throws -> MockMicRecorded {
        let files = try resolve(meeting.wavs)
        guard rig.verifiedDeviceID() != nil else { throw MockMicRecordingError.failed("capture device could not be verified") }
        let began = ContinuousClock.now
        try await rig.recorder.start()
        guard let noteID = rig.recorder.activeNote?.id else { throw MockMicRecordingError.noNote }
        try await Task.sleep(for: Self.captureLeadIn)
        let typing = Task { await self.typeDuringMeeting(noteID) }
        try await config.player.play(files)
        try await Task.sleep(for: Self.captureTail)
        var live = await typing.value
        live.microphoneHeard = rig.recorder.capture?.microphoneLastHeard != nil
        live.transcribedBeforeStop = rig.recorder.transcribedSeconds
        live.liveTurns = (try? rig.store.turnCount(noteId: noteID, origin: .capture)) ?? 0
        rig.recorder.stop()
        try await waitUntil("note ready", Self.readyTimeout, describe: { self.noteState(noteID) }) {
            let note = try self.rig.store.note(id: noteID)
            // A failed note never becomes ready: say so now instead of waiting out the timeout.
            if let note, note.status == .failed {
                throw MockMicRecordingError.failed(
                    "the note finished as failed (transcript \(note.transcript.count) characters, \(self.noteState(noteID)))")
            }
            return note?.status == .ready
        }
        let ready = mockMicSeconds(since: began)
        // Diarization needs the turns' word timings; with none it is skipped silently, so fail at once and say so.
        let timingCount = ((try? rig.store.turns(noteId: noteID)) ?? []).reduce(0) { $0 + ($1.words?.count ?? 0) }
        guard timingCount > 0 else {
            let why = await timingProbe(noteID)
            throw MockMicRecordingError.failed("note is ready but its turns hold 0 word timings, so diarization is never started (\(why))")
        }
        try await waitUntil("speaker segments", Self.diarizationTimeout,
                            describe: { "turns hold \(timingCount) word timings" }) {
            try self.rig.store.hasSpeakerSegments(noteId: noteID)
        }
        try await Task.sleep(for: Self.suggestionSettle)
        var recorded = try await collect(noteID, files: files, readySeconds: ready, began: began)
        recorded.live = live
        return recorded
    }

    private func collect(_ noteID: Int64, files: [URL], readySeconds: Double,
                         began: ContinuousClock.Instant) async throws -> MockMicRecorded {
        guard let note = try rig.store.note(id: noteID) else { throw MockMicRecordingError.noNote }
        let rows = try rig.store.noteSegments(noteId: noteID)
        let captured = try capturedSamples(of: note)
        let silent = captured.isEmpty || captured.allSatisfy { $0 == 0 }
        let rate = 16_000.0
        let source = try MockMicAudio.readMono(files[0], rate: rate)
        let heard = MockMicAudio.onset(captured, rate: rate) ?? 0
        let sent = MockMicAudio.onset(source, rate: rate) ?? 0
        let offset = silent ? 0 : heard - sent
        return MockMicRecorded(note: note, rows: rows, offset: offset, captureSilent: silent, readySeconds: readySeconds,
                               diarizationSeconds: mockMicSeconds(since: began))
    }

    /// The mic side the journal kept, on the note clock (16 kHz).
    func capturedSamples(of note: Note) throws -> [Float] {
        guard let path = note.audioPath, let id = note.id else { return [] }
        return try CaptureSegmentAudio.timeline(
            rig.store.captureJournal(noteId: id), stream: .mic, folder: URL(fileURLWithPath: path, isDirectory: true),
            key: rig.encryption.currentKey, readLegacy: FinalizeRunner.readLegacy)
    }

    /// Re-transcribes the note's first chunk twice, with and without the vocabulary the recorder passes, and
    /// counts the word timings each gives. Pins a "no timings" failure on the vocabulary step or the engine.
    func timingProbe(_ id: Int64) async -> String {
        do {
            guard let path = try rig.store.note(id: id)?.audioPath,
                  let first = try rig.store.captureJournal(noteId: id).audio(.mic).first else { return "no segment to probe" }
            let samples = try CaptureSegmentAudio.samples(
                first, folder: URL(fileURLWithPath: path, isDirectory: true), key: rig.encryption.currentKey,
                readLegacy: FinalizeRunner.readLegacy)
            let vocabulary = PipelineSettings(personalizer: rig.recorder.personalizer).vocabulary
            let plain = try await rig.speech.transcribeWithConfidence(samples, vocabulary: .empty)
            let boosted = try await rig.speech.transcribeWithConfidence(samples, vocabulary: vocabulary)
            return "chunk 0: \(plain.timings?.count ?? -1) timings without vocabulary, "
                + "\(boosted.timings?.count ?? -1) with the recorder's \(vocabulary.terms.count)-term vocabulary"
        } catch { return "probe failed: \(error)" }
    }

    /// Status, recorder phase and pill state, for a timeout message (no transcript text).
    func noteState(_ id: Int64) -> String {
        let status = (try? rig.store.note(id: id))?.map { "\($0.status)" } ?? "missing"
        return "note status \(status), recorder finishing \(rig.recorder.isFinishing)"
    }

    func waitUntil(_ stage: String, _ timeout: Duration, describe: () -> String = { "" },
                   _ condition: () throws -> Bool) async throws {
        let began = ContinuousClock.now
        let deadline = began + timeout
        while ContinuousClock.now < deadline {
            if try condition() { return }
            try await Task.sleep(for: .milliseconds(500))
        }
        throw MockMicRecordingError.timedOut("\(stage) after \(Int(mockMicSeconds(since: began))) s (\(describe()))")
    }
}
#endif
