#if DEBUG
import Foundation
import HushyModelsMLX
import MurmurCore
import Synchronization

extension MeetingJournalTrial {
    @MainActor
    final class Runner {
        let rig: MockMicRig
        let arguments: Arguments
        let foreground: ForegroundActivity
        /// Every model call's leg and outcome (never text), so a dictation can tell the 4B answered it.
        let callLog: ModelCallLog
        /// What dictations clean with: the rig's Apple FM, or the local 4B chain.
        let cleanupModel: any LanguageModel
        /// "apple", or "local:<id>" when summaries share the 4B with dictation.
        let summaryModelLabel: String
        /// Summary calls that began on the shared 4B (`MeetingLanguageModel`'s `respondBegins`).
        let summaryCalls: CallCounter
        /// The 4B under the chain, for each dictation's in-engine timings (nil on Apple FM).
        let mlx: MLXLanguageModel?
        var recorder: NoteRecorder { rig.recorder }

        init(rig: MockMicRig, arguments: Arguments) throws {
            self.rig = rig
            self.arguments = arguments
            let foreground = ForegroundActivity(), callLog = ModelCallLog(capacity: 4_096)
            self.foreground = foreground
            self.callLog = callLog
            let counter = CallCounter()
            self.summaryCalls = counter
            rig.recorder.finalizer.foreground = foreground
            guard let directory = arguments.localModel else {
                mlx = nil
                cleanupModel = rig.cleanupModel
                summaryModelLabel = "apple"
                return
            }
            let shared = try MeetingJournalTrial.localModel(directory: directory, callLog: callLog)
            let meeting = MeetingLanguageModel(
                shared: shared.model, apple: rig.cleanupModel, activity: foreground, respondBegins: { counter.add() })
            meeting.route(for: .local(shared.entry.id))
            guard meeting.route == .sharedLocal else { throw MockMicAudioError(description: "summaries would not share the 4B") }
            LanguageModels.current = shared.model
            LanguageModels.meeting = meeting
            rig.recorder.finalizer.summarize = { await SmartCleaner.summarize($0, fallbackTitle: $1, model: meeting) }
            cleanupModel = shared.model
            mlx = shared.mlx
            summaryModelLabel = "local:\(shared.entry.id)"
        }

        func clip(_ name: String) throws -> [Float] {
            try MockMicAudio.readMono(arguments.clips.appendingPathComponent(name), rate: 16_000)
        }

        func synthetic(_ name: String, speed: Int = 1) throws -> SyntheticNoteSource {
            SyntheticNoteSource(samples: try clip(name), speed: speed)
        }

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
            // `--speed N` plays the call N times faster than real time: the note holds `--seconds` of audio either way.
            let speed = max(1, arguments.speed)
            let mic = try synthetic("mic.wav", speed: speed)
            let call = try synthetic("call.wav", speed: speed)
            recorder.makeMicSource = { mic }
            recorder.makeCallSource = { call }
            let base = MeetingJournalTrial.footprintMB()
            try await recorder.start()
            guard let id = recorder.activeNote?.id else { throw MockMicRecordingError.noNote }
            let began = ContinuousClock.now
            let seconds = (arguments.seconds ?? 3_600) / Double(speed)
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
            let steps = StepPeaks()
            let store = rig.store
            let watcher = Task { @MainActor in
                while !Task.isCancelled {
                    let step = (try? store.finalizeState(noteId: id)?.step.rawValue) ?? "none"
                    steps.record(step: step, mb: MeetingJournalTrial.footprintMB(), at: mockMicSeconds(since: finalizeBegan))
                    try? await Task.sleep(for: .milliseconds(100))
                }
            }
            try await waitForFinish(id, timeout: .seconds(3_600))
            watcher.cancel()
            var row = try describe(id)
            row["seconds"] = seconds * Double(speed)
            row["speed"] = speed
            row["baseMB"] = base
            row["capturePeakMB"] = capturePeak
            row["finalizePeakMB"] = steps.peak
            row["finalizeStepPeaksMB"] = steps.peaks
            row["finalizeStepSeconds"] = steps.seconds
            row["finalizeSeconds"] = mockMicSeconds(since: finalizeBegan)
            row["finalizeTimeline"] = steps.timeline
            row["timeline"] = samples
            row["summaryModel"] = summaryModelLabel
            row["speakerLabels"] = FeatureFlags.speakerLabels
            return row
        }
    }
}

/// Peak footprint per finalize step, sampled by the memory trial (counts only).
@MainActor
final class StepPeaks {
    private(set) var peaks: [String: Double] = [:]
    private(set) var seconds: [String: Double] = [:]
    private(set) var timeline: [[String: Any]] = []
    private var last: (step: String, at: Double)?

    var peak: Double { peaks.values.max() ?? 0 }

    func record(step: String, mb: Double, at: Double) {
        peaks[step] = max(peaks[step] ?? 0, mb)
        if let last { seconds[last.step, default: 0] += at - last.at }
        if last?.step != step || timeline.isEmpty || at - ((timeline.last?["at"] as? Double) ?? 0) >= 5 {
            timeline.append(["at": at.rounded(), "step": step, "mb": mb.rounded()])
        }
        last = (step, at)
    }
}
/// Counts summary calls as they begin on the shared model.
final class CallCounter: Sendable {
    private let count = Mutex(0)
    var begun: Int { count.withLock { $0 } }
    func add() { count.withLock { $0 += 1 } }
}
#endif
