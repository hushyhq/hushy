#if DEBUG
import Foundation

/// The run mode: apply the safety rules in order, then hand over to the scenarios. Every refusal
/// happens before any audio device or model is opened.
@MainActor
enum MockMicRun {
    static func run(report reportDir: URL, arguments: MockMicArguments) async -> Int32 {
        if let reason = homeRefusal() { return stop("refused: \(reason)", MockMicExit.refused) }
        guard case .use(let device) = MockMicDeviceRule.decide(MockMicDevices.inputDevices()) else {
            return stop("skipped: no usable BlackHole 2ch input device", MockMicExit.skipped)
        }
        guard let config = prepare(report: reportDir, arguments: arguments) else {
            return stop("usage: --clips <dir> with a clips.json, and --player <audio-loopback binary>", MockMicExit.usage)
        }
        do {
            let removed = MockMicSuites.sweep()
            if removed > 0 { print("mock-mic: removed \(removed) defaults suites left by earlier runs") }
            let rig = try MockMicRig(device: device)
            defer { rig.dispose() }
            MockMicSignals.install { rig.dispose() }
            let violations = rig.isolationViolations()
            guard violations.isEmpty else {
                return stop("refused: not isolated from the real machine: \(violations.joined(separator: "; "))", MockMicExit.refused)
            }
            let harness = MockMicHarness(config: config, rig: rig)
            let report = ProcessInfo.processInfo.environment["HUSHY_MOCK_MIC_APP_E2E"] == "1"
                ? await harness.runAppE2E() : await harness.run()
            try report.write(to: reportDir)
            print("mock-mic: \(report.scenarios.count) scenarios, report at \(reportDir.path)/mock-mic.json")
            return report.exitCode
        } catch {
            return stop("failed to start: \(error)", MockMicExit.failed)
        }
    }

    /// The home rule, applied to every mode of the launcher (the run, the job list and the assembly).
    static func homeRefusal(environment: [String: String] = ProcessInfo.processInfo.environment,
                            realSupport: URL = MockMicHome.realSupport) -> String? {
        if case .refused(let reason) = MockMicHome.evaluate(environment: environment, realSupport: realSupport) { return reason }
        return nil
    }

    private static func prepare(report: URL, arguments: MockMicArguments) -> MockMicConfig? {
        guard let clipsPath = arguments.clips, let playerPath = arguments.player else { return nil }
        let clips = URL(fileURLWithPath: clipsPath)
        guard MockMicManifest.isAllowedAudioPath(clips.path, realSupport: MockMicHome.realSupport.path),
              let manifest = try? MockMicManifest.load(from: clips) else { return nil }
        return MockMicConfig(manifest: manifest, clips: clips, reportDir: report,
                             player: MockMicPlayer(executable: URL(fileURLWithPath: playerPath)))
    }

    private static func stop(_ message: String, _ code: Int32) -> Int32 {
        print("mock-mic: \(message)")
        return code
    }
}

/// Removes the throwaway defaults suite when the run is interrupted, then exits with the shell's code for the signal.
@MainActor
enum MockMicSignals {
    private static var sources: [DispatchSourceSignal] = []

    static func install(onSignal: @escaping @MainActor () -> Void) {
        for number in [SIGINT, SIGTERM, SIGHUP] {
            signal(number, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: number, queue: .main)
            source.setEventHandler {
                MainActor.assumeIsolated { onSignal() }
                exit(128 + number)
            }
            source.resume()
            sources.append(source)
        }
    }
}
#endif
