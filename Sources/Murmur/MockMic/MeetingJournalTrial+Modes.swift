#if DEBUG
import Foundation
import MurmurCore

extension MeetingJournalTrial {
    @MainActor
    final class Runner {
        let rig: MockMicRig
        let arguments: Arguments
        let foreground = ForegroundActivity()
        var recorder: NoteRecorder { rig.recorder }

        init(rig: MockMicRig, arguments: Arguments) {
            self.rig = rig
            self.arguments = arguments
            rig.recorder.finalizer.foreground = foreground
        }

        func clip(_ name: String) throws -> [Float] {
            try MockMicAudio.readMono(arguments.clips.appendingPathComponent(name), rate: 16_000)
        }

        func synthetic(_ name: String) throws -> SyntheticNoteSource { SyntheticNoteSource(samples: try clip(name)) }

        // MARK: record / resume

        /// Two channels: the microphone through BlackHole (the real capture path), the call side synthetic.
        func record() async throws -> [String: Any] {
            if ProcessInfo.processInfo.arguments.contains("--synthetic-mic") {
                // The journal's durability does not depend on the device; this keeps the trial when BlackHole is down.
                let mic = try synthetic("mic.wav")
                recorder.makeMicSource = { mic }
            } else {
                guard rig.verifiedDeviceID() != nil else { throw MockMicRecordingError.failed("capture device could not be verified") }
            }
            let call = try synthetic("call.wav")
            recorder.makeCallSource = { call }
            try await recorder.start()
            guard let id = recorder.activeNote?.id else { throw MockMicRecordingError.noNote }
            let marker: [String: Any] = ["noteId": id, "startedAt": Date().timeIntervalSince1970]
            try JSONSerialization.data(withJSONObject: marker).write(to: arguments.report.appendingPathComponent("recording.json"))
            print("meeting-journal: recording \(id)")
            fflush(stdout)
            try await Task.sleep(for: .seconds(arguments.seconds ?? 3_600))
            recorder.stop()
            try await waitForFinish(id)
            return try describe(id)
        }

        /// A relaunch: no click, the runner finishes every interrupted note.
        func resume() async throws -> [String: Any] {
            let began = ContinuousClock.now
            let ids = recorder.finalizer.resumeInterrupted()
            for id in ids { try await waitForFinish(id) }
            var notes: [[String: Any]] = []
            for id in ids { notes.append(try describe(id)) }
            return ["resumed": ids.count, "seconds": mockMicSeconds(since: began), "notes": notes]
        }

        func waitForFinish(_ id: Int64, timeout: Duration = .seconds(900)) async throws {
            let deadline = ContinuousClock.now + timeout
            while ContinuousClock.now < deadline {
                let step = try rig.store.finalizeState(noteId: id)?.step
                if step == .done || step == .needsAttention, !recorder.finalizer.runningNoteIDs.contains(id) { return }
                try await Task.sleep(for: .milliseconds(250))
            }
            throw MockMicRecordingError.timedOut("finalize of note \(id)")
        }

        /// Counts only: never text.
        func describe(_ id: Int64) throws -> [String: Any] {
            let journal = try rig.store.captureJournal(noteId: id)
            let turns = try rig.store.turns(noteId: id)
            let note = try rig.store.note(id: id)
            let gaps = journal.segments.filter { $0.kind == .gap }
            return [
                "noteId": id, "status": note?.status.rawValue ?? "missing",
                "step": try rig.store.finalizeState(noteId: id)?.step.rawValue ?? "none",
                "micSealedSeconds": journal.sealedSeconds(.mic), "callSealedSeconds": journal.sealedSeconds(.system),
                "segments": journal.segments.filter { $0.kind == .audio }.count,
                "failedSegments": journal.segments.filter { $0.state == .failed }.count,
                "gaps": gaps.map { ["stream": $0.stream.rawValue, "reason": $0.gapReason?.rawValue ?? "", "seconds": $0.duration] },
                "turns": turns.count, "words": turns.reduce(0) { $0 + ($1.words?.count ?? 0) },
                "micTurns": turns.filter { $0.stream == .mic }.count, "callTurns": turns.filter { $0.stream == .system }.count,
                "transcriptCharacters": note?.transcript.count ?? 0,
            ]
        }

        // MARK: health

        func health() async throws -> [String: Any] {
            let faults: [(CaptureStream, SyntheticNoteSource.Fault)] = [(.system, .zeros), (.system, .stall), (.mic, .stall), (.mic, .zeros)]
            var trials: [[String: Any]] = []
            for index in 0..<arguments.trials {
                let (side, fault) = faults[index % faults.count]
                trials.append(try await healthTrial(side: side, fault: fault, cures: index % 2 == 1))
            }
            let listen = try await listenOnly(seconds: arguments.seconds ?? 600)
            let latencies = trials.compactMap { $0["warnedAfterSeconds"] as? Double }
            return [
                "trials": trials, "warnedWithin20s": latencies.filter { $0 <= 20 }.count, "trialCount": trials.count,
                "worstSeconds": latencies.max() ?? -1, "listenOnly": listen,
            ]
        }

        private func healthTrial(side: CaptureStream, fault: SyntheticNoteSource.Fault, cures: Bool) async throws -> [String: Any] {
            let mic = try synthetic("mic.wav")
            let call = try synthetic("call.wav")
            let target = side == .mic ? mic : call
            target.rebuildCures = cures
            recorder.makeMicSource = { mic }
            recorder.makeCallSource = { call }
            try await recorder.start()
            guard let id = recorder.activeNote?.id else { throw MockMicRecordingError.noNote }
            let faultAt = Double.random(in: 15...40)
            try await Task.sleep(for: .seconds(faultAt))
            let injected = ContinuousClock.now
            target.setFault(fault)
            var warned: Double?
            let expected: CaptureHealth.Problem = fault == .stall ? .stalled : .digitalSilence
            while mockMicSeconds(since: injected) < 40 {
                if recorder.session?.events.contains(where: { $0.stream == side && $0.problem == expected }) == true,
                   recorder.capture?.warning(now: Date()) != nil {
                    warned = mockMicSeconds(since: injected)
                    break
                }
                try await Task.sleep(for: .milliseconds(100))
            }
            try await Task.sleep(for: .seconds(cures ? 15 : 5))
            let events = recorder.session?.events.map { "\($0.stream.rawValue):\($0.problem?.rawValue ?? "recovered")@\(Int($0.at))" } ?? []
            recorder.stop()
            try await waitForFinish(id)
            var row = try describe(id)
            row["side"] = side.rawValue
            row["fault"] = fault.rawValue
            row["rebuildCures"] = cures
            row["faultAtSeconds"] = faultAt
            row["warnedAfterSeconds"] = warned ?? -1
            row["rebuilds"] = target.rebuildCount
            row["events"] = events
            recorder.makeMicSource = nil
            recorder.makeCallSource = nil
            return row
        }

        /// A person listening: room noise on the microphone, the call talking. No capture-health warning may come.
        private func listenOnly(seconds: Double) async throws -> [String: Any] {
            var noise = [Float](repeating: 0, count: 16_000 * 7)
            for index in noise.indices { noise[index] = Float.random(in: -0.004...0.004) }
            let mic = SyntheticNoteSource(samples: noise)
            let call = try synthetic("call.wav")
            recorder.makeMicSource = { mic }
            recorder.makeCallSource = { call }
            try await recorder.start()
            guard let id = recorder.activeNote?.id else { throw MockMicRecordingError.noNote }
            let began = ContinuousClock.now
            var analogWarningSeconds = 0
            while mockMicSeconds(since: began) < seconds {
                try await Task.sleep(for: .seconds(1))
                if let warning = recorder.capture?.warning(now: Date()), warning.title != "[placeholder]" { analogWarningSeconds += 1 }
            }
            let problems = recorder.session?.events.filter { $0.problem != nil }.count ?? -1
            recorder.stop()
            try await waitForFinish(id)
            var row = try describe(id)
            row["healthWarnings"] = problems
            row["analogQuietWarningSeconds"] = analogWarningSeconds
            row["seconds"] = seconds
            return row
        }

        // MARK: memory

        func memory() async throws -> [String: Any] {
            let mic = try synthetic("mic.wav")
            let call = try synthetic("call.wav")
            recorder.makeMicSource = { mic }
            recorder.makeCallSource = { call }
            let base = MeetingJournalTrial.footprintMB()
            try await recorder.start()
            guard let id = recorder.activeNote?.id else { throw MockMicRecordingError.noNote }
            let began = ContinuousClock.now
            let seconds = arguments.seconds ?? 3_600
            var capturePeak = 0.0
            var samples: [[Double]] = []
            var ticks = 0
            while mockMicSeconds(since: began) < seconds {
                try await Task.sleep(for: .seconds(2))
                let now = MeetingJournalTrial.footprintMB()
                capturePeak = max(capturePeak, now)
                if ticks % 30 == 0 { samples.append([mockMicSeconds(since: began).rounded(), now.rounded()]) }
                ticks += 1
            }
            recorder.stop()
            let finalizeBegan = ContinuousClock.now
            var finalizePeak = 0.0
            let watcher = Task { @MainActor in
                while !Task.isCancelled {
                    finalizePeak = max(finalizePeak, MeetingJournalTrial.footprintMB())
                    try? await Task.sleep(for: .milliseconds(500))
                }
            }
            try await waitForFinish(id, timeout: .seconds(3_600))
            watcher.cancel()
            var row = try describe(id)
            row["seconds"] = seconds
            row["baseMB"] = base
            row["capturePeakMB"] = capturePeak
            row["finalizePeakMB"] = finalizePeak
            row["finalizeSeconds"] = mockMicSeconds(since: finalizeBegan)
            row["timeline"] = samples
            return row
        }
    }
}
#endif
