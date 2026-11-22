#if DEBUG
import FluidAudio
import Foundation
import HushyModelsApple
import MurmurCore

/// What the harness needs and does not have on disk. Nothing here downloads.
enum MockMicPreflight {
    static func missingForDictation() -> [String] {
        var missing: [String] = []
        if !SpeechEngine.isCached(.ultra) { missing.append("speech model") }
        if !SpeechEngine.isVocabularyModelCached { missing.append("vocabulary model") }
        return missing
    }

    static func missingForMeetings() -> [String] {
        var missing: [String] = []
        if !SpeechEngine.isCached(.ultra) { missing.append("speech model") }
        if !diarizerModelsCached { missing.append("speaker model") }
        return missing
    }

    static var diarizerModelsCached: Bool {
        let folder = DiarizerModels.defaultModelsDirectory()
        return DiarizerModels.requiredModelNames.allSatisfy {
            FileManager.default.fileExists(atPath: folder.appendingPathComponent($0).path)
        }
    }

    /// Nemotron 3's compiled bundle for the shipped preset, where FluidAudio keeps it. Existence only; nothing is read.
    static var nemotronModelsCached: Bool {
        let config = SpeakerDiarizerConstants.nemotronConfig
        let repo = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("FluidAudio/Models").appendingPathComponent(Repo.nemotron3Diarization.folderName)
        let bundle = repo.appendingPathComponent(config.hubSubdirectory).appendingPathComponent(config.modelFileName)
        return FileManager.default.fileExists(atPath: bundle.appendingPathComponent("coremldata.bin").path)
    }

    /// Speaker labels run only when every model they would load is already on this Mac, so a trial never downloads.
    static var speakerModelsCached: Bool { diarizerModelsCached && nemotronModelsCached }
}

/// The few pieces of the app the harness builds itself, in place of `AppModel`: no window, menu bar
/// item, hotkey monitor, paste, calendar reader or network client. Settings live in a throwaway
/// defaults suite, keys in memory (the Keychain is never touched), data under the temp home.
@MainActor
final class MockMicRig {
    let settings: AppSettings
    let store: Store
    let encryption: EncryptionController
    let speech: SpeechEngine
    let status = SpeechModelStatus()
    let recorder: NoteRecorder
    let device: MockMicDevice
    let cleanupModel: any LanguageModel
    private let suiteName: String

    var cleanupBackend: String { cleanupModel.availability.isAvailable ? "apple" : "rules" }

    init(device: MockMicDevice) throws {
        self.device = device
        let suiteName = MockMicSuites.path(in: AppPaths.supportDirectory)
        self.suiteName = suiteName
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            throw MockMicAudioError(description: "cannot create the throwaway defaults suite")
        }
        FeatureFlags.source = defaults
        let settings = AppSettings(defaults: defaults, calendarAuthorization: .notDetermined)
        settings.inputDeviceName = device.name
        settings.recordCallAudio = false
        settings.reduceBackgroundNoise = false
        settings.encryptDataAtRest = false
        Self.isolate(settings)
        self.settings = settings
        do {
            store = try Store(url: AppPaths.database)
        } catch {
            MockMicSuites.removePath(suiteName)
            FeatureFlags.source = .standard
            throw error
        }
        encryption = EncryptionController(
            settings: settings, keyManager: EncryptionKeyManager(keyStore: InMemoryKeyStore()))
        let offline = SpeechModelIntegrity(
            fetchManifest: { _ in throw MockMicAudioError(description: "network is off in this mode") },
            defaultsSuiteName: suiteName)
        speech = SpeechEngine(status: status, integrity: offline)
        let apple = AppleFoundationModel()
        LanguageModels.current = apple
        cleanupModel = apple
        recorder = NoteRecorder(
            speech: speech, modelStatus: status, store: store, settings: settings, pill: PillModel(),
            encryption: encryption)
        recorder.requiresSelectedInputDevice = true
    }

    func prepareSpeech() async throws {
        try await speech.prepare(version: settings.speechLanguageMode.modelVersion,
                                 driftGuard: settings.speechLanguageMode.driftGuardEnabled)
    }

    /// The input the app would open for this device name, proven to be the verified virtual device.
    func verifiedDeviceID() -> UInt32? {
        let found = AudioCapture.inputDevices().first { $0.name == settings.inputDeviceName }
        return found?.id == device.id ? device.id : nil
    }

    /// A finished note must not be exported: the defaults are Markdown on, into ~/Documents/Hushy.
    static func isolate(_ settings: AppSettings) {
        settings.exportNotesToMarkdown = false
        settings.saveNotesToAppleNotes = false
        settings.exportDirectory = AppPaths.supportDirectory.appendingPathComponent("mock-mic-export", isDirectory: true)
    }

    static func violations(of settings: AppSettings) -> [String] {
        MockMicIsolation.exportViolations(
            exportsMarkdown: settings.exportNotesToMarkdown, savesToAppleNotes: settings.saveNotesToAppleNotes,
            exportDirectory: settings.exportDirectory, home: AppPaths.supportDirectory)
    }

    /// Everything that would make a run write outside the temp home. Checked before any scenario.
    func isolationViolations() -> [String] {
        Self.violations(of: settings) + MockMicIsolation.entitlementViolations()
    }

    /// Safe to call more than once, from the normal exit, a failed start or a signal handler.
    func dispose() {
        FeatureFlags.source = .standard
        MockMicSuites.removePath(suiteName)
    }
}
#endif
