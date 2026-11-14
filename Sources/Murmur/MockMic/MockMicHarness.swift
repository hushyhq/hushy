#if DEBUG
import Foundation
import MurmurCore

/// Pass marks for the synthetic (`say`) clips. External clips are scored and reported against these
/// but never enforced. Chosen from measured runs: see docs/guide/MOCK-MIC.md, "Thresholds".
enum MockMicThresholds {
    static let dictationWordError = 0.15
    static let meetingWordError = 0.10
    /// A speaker needs this much speech in the note to count as found.
    static let minimumSpeakerSeconds = 3.0
}

struct MockMicConfig {
    let manifest: MockMicManifest
    let clips: URL
    let reportDir: URL
    let player: MockMicPlayer
}

/// Runs the scenarios in order and collects the report. All state is the rig and what the scenarios
/// record into `meetings`; nothing outlives the process except the report file.
@MainActor
final class MockMicHarness {
    let config: MockMicConfig
    let rig: MockMicRig
    var meetings: [String: MockMicMeetingOutcome] = [:]
    private var results: [MockMicScenarioResult] = []

    init(config: MockMicConfig, rig: MockMicRig) {
        self.config = config
        self.rig = rig
    }

    var manifest: MockMicManifest { config.manifest }
    var enforcesQuality: Bool { manifest.enforcesThresholds }

    func run() async -> MockMicReport {
        // HUSHY_MOCK_MIC_SKIP_DICTATION=1 goes straight to the meetings, for quicker diagnosis.
        if ProcessInfo.processInfo.environment["HUSHY_MOCK_MIC_SKIP_DICTATION"] != "1" { await runDictationScenarios() }
        if !isBlocked { await runMeetingScenarios() }
        if !isBlocked { await runVoiceScenarios() }
        return report()
    }

    func record(_ result: MockMicScenarioResult) {
        results.append(result)
        print(result.summaryLine)
    }

    var isBlocked: Bool { results.contains { $0.status == .blocked } }

    func report() -> MockMicReport {
        let full = MockMicReport(
            version: 1, source: manifest.source, scoring: manifest.scoringMode.rawValue,
            device: rig.device.name, cleanupBackend: rig.cleanupBackend, scenarios: results)
        return enforcesQuality ? full : full.withoutTexts()
    }

    // MARK: - Shared helpers

    func skipped(_ id: String, _ title: String, _ reason: String) -> MockMicScenarioResult {
        MockMicScenarioResult(id: id, title: title, status: .skipped, seconds: 0, detail: reason,
                              checks: [], metrics: [:], texts: nil)
    }

    func blockedResult(_ id: String, _ title: String, seconds: Double) -> MockMicScenarioResult {
        MockMicScenarioResult(
            id: id, title: title, status: .blocked, seconds: seconds,
            detail: "the capture was all zeros: microphone permission is blocking this process. Nothing was changed.",
            checks: [MockMicCheck(name: "capture is not silent", passed: false, enforced: true, value: "all zeros", threshold: nil)],
            metrics: [:], texts: nil)
    }

    func failed(_ id: String, _ title: String, _ error: Error, seconds: Double) -> MockMicScenarioResult {
        MockMicScenarioResult(
            id: id, title: title, status: .fail, seconds: seconds, detail: "error: \(error)",
            checks: [MockMicCheck(name: "scenario ran", passed: false, enforced: true, value: "\(error)", threshold: nil)],
            metrics: [:], texts: nil)
    }

    func resolve(_ names: [String]) throws -> [URL] {
        try names.map { name in
            guard let url = MockMicManifest.resolve(name, in: config.clips),
                  MockMicManifest.isAllowedAudioPath(url.path, realSupport: MockMicHome.realSupport.path) else {
                throw MockMicManifestError(message: "refusing to open \(name)")
            }
            return url
        }
    }

    func check(_ name: String, _ passed: Bool, _ value: String, threshold: String? = nil,
               quality: Bool = false) -> MockMicCheck {
        MockMicCheck(name: name, passed: passed, enforced: quality ? enforcesQuality : true,
                     value: value, threshold: threshold)
    }

    func wordError(_ value: Double) -> String { String(format: "%.1f%%", value * 100) }
}

/// Seconds elapsed since `start`, for scenario timing.
func mockMicSeconds(since start: ContinuousClock.Instant) -> Double {
    let parts = (ContinuousClock.now - start).components
    return Double(parts.seconds) + Double(parts.attoseconds) / 1e18
}
#endif
