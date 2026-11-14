import AppKit
import Foundation
import MurmurCore
import Observation
import os

/// Drives the Voice Lab recording flow: walks through `VoiceLabPrompts`, captures each take
/// through the exact production `AudioCapture` (same device + voice-processing settings as
/// real dictation), and saves 16 kHz mono WAV + JSON sidecar pairs under
/// `~/Library/Application Support/Murmur/VoiceLab/<session-date>/`.
///
/// Deliberately never uploads or transmits anything: the only I/O this type performs is
/// reading the bundled prompt file and writing to the local VoiceLab folder.
@MainActor
@Observable
final class VoiceLabModel {
    enum LoadState {
        case loading
        case ready
        case failed(String)
    }

    private(set) var loadState: LoadState = .loading
    private(set) var prompts: [VoiceLabPrompt] = []
    private(set) var currentIndex = 0
    private(set) var isRecording = false
    private(set) var level: Float = 0
    /// The take just recorded, awaiting Keep/Re-record/Skip.
    private(set) var pendingTake: PendingTake?
    /// Prompt ids already saved this run, so progress reflects real completions, not just position.
    private(set) var completedIDs: Set<String> = []

    @ObservationIgnored private let audio = AudioCapture()
    @ObservationIgnored private let settings: AppSettings
    @ObservationIgnored private let log = Logger(subsystem: "app.hushy", category: "voicelab")
    @ObservationIgnored private(set) var sessionDirectory: URL

    struct PendingTake {
        let samples: [Float]
        let peak: Float
        let rms: Float
        let audioURL: URL
        let sidecarURL: URL
        let take: VoiceLabTake
    }

    var currentPrompt: VoiceLabPrompt? {
        prompts.indices.contains(currentIndex) ? prompts[currentIndex] : nil
    }

    var progressText: String {
        "\(min(currentIndex + 1, prompts.count))/\(prompts.count)"
    }

    var completedCount: Int { completedIDs.count }

    init(settings: AppSettings) {
        self.settings = settings
        // Takes recorded with noise reduction off go to their own folder, so an A/B pass never
        // overwrites the main session and the eval can compare the two capture chains.
        let base = VoiceLabStorage.sessionDirectory()
        sessionDirectory = settings.reduceBackgroundNoise
            ? base : base.deletingLastPathComponent().appendingPathComponent(base.lastPathComponent + "-nr-off", isDirectory: true)
        load()
    }

    private func load() {
        // The prompt file lives in `Evals/` (checked into the repo, not app-bundled), so it's
        // located by walking up from either the source file (development builds run from the
        // build folder inside the checkout) or the current working directory (`Murmur.app` is
        // typically launched from `scripts/build-app.sh` inside the repo). `MURMUR_EVAL_HOME`
        // overrides both, matching `murmur-eval`'s own override, so the app and the eval
        // command always agree on where prompts and recordings live.
        guard let url = Self.repoPromptsURL() else {
            loadState = .failed("Could not find Evals/voicelab-prompts.json")
            return
        }
        do {
            prompts = try VoiceLabPrompts.load(from: url)
            loadState = .ready
        } catch {
            loadState = .failed(error.localizedDescription)
        }
    }

    private static func repoPromptsURL() -> URL? {
        if let override = ProcessInfo.processInfo.environment["MURMUR_EVAL_HOME"] {
            let candidate = URL(fileURLWithPath: override).appendingPathComponent("voicelab-prompts.json")
            if FileManager.default.fileExists(atPath: candidate.path) { return candidate }
        }
        let searchRoots = [URL(fileURLWithPath: #filePath), URL(fileURLWithPath: FileManager.default.currentDirectoryPath)]
        for root in searchRoots {
            var directory = root.deletingLastPathComponent()
            for _ in 0..<10 {
                let candidate = directory.appendingPathComponent("Evals/voicelab-prompts.json")
                if FileManager.default.fileExists(atPath: candidate.path) { return candidate }
                directory.deleteLastPathComponent()
            }
        }
        return nil
    }

    // MARK: Recording

    func startRecording() {
        guard currentPrompt != nil, !isRecording else { return }
        pendingTake = nil
        level = 0
        MicrophoneSelector.shared.prepare(audio, picked: settings.inputDeviceName)
        audio.voiceProcessing = settings.reduceBackgroundNoise
        do {
            try audio.start { [weak self] rms in
                Task { @MainActor in self?.level = rms }
            }
            isRecording = true
        } catch {
            log.error("Voice Lab capture failed to start: \(error.localizedDescription)")
        }
    }

    func stopRecording() {
        guard isRecording else { return }
        isRecording = false
        let samples = audio.stop()
        guard let prompt = currentPrompt, !samples.isEmpty else { return }
        let peak = samples.reduce(Float(0)) { max($0, abs($1)) }
        let rms = StreamingResampler.rms(samples)
        guard VoiceLabPrompts.isSafeID(prompt.id) else { return }
        let base = sessionDirectory.appendingPathComponent(prompt.id)
        let audioURL = base.appendingPathExtension("wav")
        let sidecarURL = base.appendingPathExtension("json")
        let deviceName = AudioCapture.inputDevices().first { $0.id == audio.preferredDeviceID }?.name
            ?? settings.inputDeviceName ?? audio.choice?.using?.name ?? "System default"
        let take = VoiceLabTake(
            promptID: prompt.id, category: prompt.category, style: prompt.style, timestamp: Date(),
            deviceName: deviceName, voiceProcessingEnabled: audio.voiceProcessing,
            osVersion: ProcessInfo.processInfo.operatingSystemVersionString,
            capturePeak: peak, captureRMS: rms, durationSeconds: Double(samples.count) / AudioCapture.sampleRate)
        pendingTake = PendingTake(samples: samples, peak: peak, rms: rms, audioURL: audioURL, sidecarURL: sidecarURL, take: take)
    }

    /// Saves the pending take to disk and advances. Re-recording the same prompt overwrites
    /// its previous take.
    func keepPendingTake() {
        guard let pending = pendingTake else { return }
        do {
            try WAVWriter.write(pending.samples, to: pending.audioURL)
            try VoiceLabStorage.write(pending.take, to: pending.sidecarURL)
            completedIDs.insert(pending.take.promptID)
        } catch {
            log.error("Voice Lab save failed: \(error.localizedDescription)")
        }
        pendingTake = nil
        advance()
    }

    func discardPendingTake() {
        pendingTake = nil
    }

    func skip() {
        pendingTake = nil
        advance()
    }

    func goToPrevious() {
        pendingTake = nil
        guard currentIndex > 0 else { return }
        currentIndex -= 1
    }

    private func advance() {
        guard currentIndex + 1 < prompts.count else {
            currentIndex = prompts.count
            return
        }
        currentIndex += 1
    }

    func openFolder() {
        try? FileManager.default.createDirectory(at: sessionDirectory, withIntermediateDirectories: true)
        NSWorkspace.shared.open(sessionDirectory)
    }

    var isFinished: Bool { currentIndex >= prompts.count }
}
