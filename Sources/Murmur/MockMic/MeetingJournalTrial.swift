#if DEBUG
import Foundation
import HushyModelsApple
import HushyModelsMLX
import MurmurCore

/// `Murmur --meeting-journal <mode> --report <dir> --clips <dir> [--seconds N] [--trials N]`: the capture journal's
/// gate measurements (meetings schema freeze section 3, task T2), headless, on a throwaway home only.
///
/// - `record`: a two-channel recording (the microphone from BlackHole, the call side synthetic) that runs until it
///   is killed, or for `--seconds`. `scripts/meeting-journal-trials.py` kills it with SIGKILL at a random moment.
/// - `resume`: what a relaunch does: the finalize runner resumes every interrupted note; reports what was kept.
/// - `health`: kills one side (stall or exact zeros) at a random moment, `--trials` times, and times the warning;
///   then a listen-only call of `--seconds` that must raise no capture-health warning.
/// - `memory`: a synthetic two-channel call of `--seconds`, sampling `phys_footprint`, then its finalize.
/// - `dictation`: dictations at idle, during a recording, and while a meeting is finalized.
///
/// `--local-model-dir <dir>` puts dictation cleanup and the meeting summary on one local 4B (the shared-model risk);
/// `--synthetic-mic` replaces BlackHole with a synthetic microphone (every mode but `record` already uses one).
///
/// Clips (16 kHz WAV, invented speech from `say`): `mic.wav`, `call.wav`, `dictation.wav`.
@MainActor
enum MeetingJournalTrial {
    struct Arguments {
        let mode: String
        let report: URL
        let clips: URL
        let seconds: Double?
        let trials: Int
        /// `--local-model-dir <dir>`: dictation cleanup and meeting summaries both on this local 4B, wired the way the
        /// app wires it (`LocalBackendFactory.mlx`, `MeetingLanguageModel` routed to the shared model). Apple FM otherwise.
        let localModel: URL?
        /// `--speed N` (memory): the synthetic call plays N times faster than real time. 1 is the gate measurement.
        let speed: Int
    }

    static func requested(_ arguments: [String]) -> Bool { arguments.contains("--meeting-journal") }

    static func parse(_ arguments: [String]) -> Arguments? {
        func value(_ flag: String) -> String? {
            guard let index = arguments.firstIndex(of: flag), arguments.indices.contains(index + 1) else { return nil }
            return arguments[index + 1]
        }
        guard let mode = value("--meeting-journal"), let report = value("--report"), let clips = value("--clips") else { return nil }
        return Arguments(mode: mode, report: URL(fileURLWithPath: report), clips: URL(fileURLWithPath: clips),
                         seconds: value("--seconds").flatMap(Double.init), trials: value("--trials").flatMap(Int.init) ?? 10,
                         localModel: value("--local-model-dir").map { URL(fileURLWithPath: $0, isDirectory: true) },
                         speed: value("--speed").flatMap(Int.init) ?? 1)
    }

    static func launch(_ arguments: [String]) -> Never {
        guard let parsed = parse(arguments) else {
            FileHandle.standardError.write(Data("usage: Murmur --meeting-journal <mode> --report <dir> --clips <dir>\n".utf8))
            exit(MockMicExit.usage)
        }
        Task { @MainActor in exit(await execute(parsed)) }
        Timer.scheduledTimer(withTimeInterval: 3600, repeats: true) { _ in }
        RunLoop.main.run()
        exit(MockMicExit.failed)
    }

    static func execute(_ arguments: Arguments) async -> Int32 {
        if let reason = MockMicRun.homeRefusal() { return say("refused: \(reason)", MockMicExit.refused) }
        let device: MockMicDevice
        if case .use(let found) = MockMicDeviceRule.decide(MockMicDevices.inputDevices()) {
            device = found
        } else if ProcessInfo.processInfo.arguments.contains("--synthetic-mic") || arguments.mode != "record" {
            // Only `record` opens a device; the other modes feed synthetic sources, so a missing BlackHole costs nothing.
            device = MockMicDevice(id: 0, name: "synthetic", isVirtual: true, inputChannels: 0)
        } else {
            return say("skipped: no BlackHole 2ch input", MockMicExit.skipped)
        }
        guard MockMicManifest.isAllowedAudioPath(arguments.clips.path, realSupport: MockMicHome.realSupport.path),
              MockMicManifest.isAllowedAudioPath(arguments.report.path, realSupport: MockMicHome.realSupport.path) else {
            return say("refused: clips and report must be outside the real data folder", MockMicExit.refused)
        }
        do {
            try FileManager.default.createDirectory(at: arguments.report, withIntermediateDirectories: true)
            let rig = try MockMicRig(device: device)
            defer { rig.dispose() }
            MockMicSignals.install { rig.dispose() }
            let violations = rig.isolationViolations()
            guard violations.isEmpty else { return say("refused: \(violations.joined(separator: "; "))", MockMicExit.refused) }
            guard SpeechEngine.isCached(.ultra) else { return say("skipped: speech model missing", MockMicExit.skipped) }
            // Nothing downloads here: speaker labels run only when their models (the legacy diarizer's and Nemotron 3's)
            // are already on this Mac; otherwise a two-channel note is assembled as You and Speaker 1 without
            // diarization. The report says which (`speakerLabels`).
            FeatureFlags.source.set(MockMicPreflight.speakerModelsCached, forKey: "feature.speakerLabels")
            try await rig.prepareSpeech()
            let trial = try Runner(rig: rig, arguments: arguments)
            let report: [String: Any]
            switch arguments.mode {
            case "record": report = try await trial.record()
            case "resume": report = try await trial.resume()
            case "health": report = try await trial.health()
            case "memory": report = try await trial.memory()
            case "dictation": report = try await trial.dictation()
            case "dictation-paired": report = try await trial.pairedDictation()
            default: return say("unknown mode \(arguments.mode)", MockMicExit.usage)
            }
            let data = try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
            try data.write(to: arguments.report.appendingPathComponent("\(arguments.mode).json"))
            return say("\(arguments.mode) done", MockMicExit.ok)
        } catch {
            return say("failed: \(error)", MockMicExit.failed)
        }
    }

    /// The app's local cleanup chain (`LocalBackendFactory.mlx`: the 4B in front of Apple FM), from a model folder on
    /// disk. The 4B is the only entry whose summaries share the cleanup model (`ModelTierPolicy.meetingUsesCleanupModel`).
    static func localModel(directory: URL, callLog: ModelCallLog) throws
        -> (model: any LanguageModel, entry: LocalModelEntry, mlx: MLXLanguageModel?) {
        guard let entry = ModelRegistry.entry(id: ModelRegistry.hushyCleanup4B) else {
            throw MockMicAudioError(description: "no registry entry for the 4B")
        }
        let factory = LocalBackendFactory.mlx
        guard factory.isRuntimeAvailable() else { throw MockMicAudioError(description: "mlx.metallib is not beside the binary") }
        guard FileManager.default.fileExists(atPath: directory.appendingPathComponent("config.json").path) else {
            throw MockMicAudioError(description: "no model at --local-model-dir")
        }
        let built = factory.make(entry, directory, AppleFoundationModel(), nil, callLog, nil)
        return (built.model, entry, built.memory as? MLXLanguageModel)
    }

    static func say(_ message: String, _ code: Int32) -> Int32 {
        print("meeting-journal: \(message)")
        fflush(stdout)
        return code
    }

    /// The process's physical footprint, as Activity Monitor's Memory column shows it.
    static func footprintMB() -> Double {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count) }
        }
        return result == KERN_SUCCESS ? Double(info.phys_footprint) / 1_048_576 : -1
    }

    static func percentile(_ values: [Double], _ p: Double) -> Double {
        let sorted = values.sorted()
        guard !sorted.isEmpty else { return 0 }
        return sorted[min(sorted.count - 1, Int((Double(sorted.count - 1) * p).rounded()))]
    }
}
#endif
