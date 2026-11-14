import Foundation
import MurmurCore
import Synchronization
import Testing
@testable import Murmur

/// The speech side, already cached: the required asset turns ready at once so optional assets run.
@MainActor
final class ReadySpeech: SpeechModelDownloading {
    let status: SpeechModelStatus
    init(status: SpeechModelStatus) { self.status = status }
    var isRequiredModelCached: Bool { true }
    var isVocabularyModelCached: Bool { true }
    func prepareRequired() async throws { status.markReady() }
    func pauseRequired() async {}
    func prefetchVocabularyModel() async throws {}
}

/// A backend that answers with its own name, so a test can tell which one ran.
final class NamedModel: UnloadableLanguageModel {
    let identifier: String
    private let counters = Mutex((calls: 0, unloads: 0))

    init(_ identifier: String) { self.identifier = identifier }

    var calls: Int { counters.withLock { $0.calls } }
    var unloads: Int { counters.withLock { $0.unloads } }
    var availability: LanguageModelAvailability { .available }
    func supportsLanguage(_ languageCode: String) -> Bool { true }
    func prewarm(instructions: String) {}
    func prefixCache(instructions: String) async {}
    func unload() async { counters.withLock { $0.unloads += 1 } }
    func respond(instructions: String, prompt: String, schema: GenerationSchemaSpec, options: LanguageModelOptions) async throws -> String {
        counters.withLock { $0.calls += 1 }
        return #"{"text":"\#(identifier)"}"#
    }
}

/// Thread-safe list the factory appends to.
final class Collected<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [T] = []
    func append(_ item: T) { lock.withLock { items.append(item) } }
    var all: [T] { lock.withLock { items } }
}

struct NoSleepClock: DownloadClock {
    func now() -> Date { Date() }
    func sleep(for seconds: TimeInterval) async throws {}
}

/// A download that writes sparse files of the entry's exact sizes (no real bytes, no network),
/// optionally holding until released so a test can act mid-download.
final class FakeFetch: @unchecked Sendable {
    private let lock = NSLock()
    private var gate: CheckedContinuation<Void, Never>?
    private(set) var fetches = 0
    /// Asset ids in the order their downloads began (pre-installed models are not downloads).
    private var order: [String] = []
    var holds = false
    var requested: [String] { lock.withLock { order } }

    /// The files a finished download leaves behind, written straight away (no await).
    private static func writeFiles(of entry: LocalModelEntry, root: URL) throws {
        let directory = ModelRegistry.directory(for: entry, root: root)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for file in entry.files {
            let url = directory.appendingPathComponent(file.relativePath)
            FileManager.default.createFile(atPath: url.path, contents: nil)
            let handle = try FileHandle(forWritingTo: url)
            try handle.truncate(atOffset: UInt64(file.bytes))
            try handle.close()
        }
    }

    /// A model that is already on disk, counted as one fetch like a real one. Done on the calling thread: the
    /// rig used to start a task and block the main thread on a semaphore until the task ran, which stalled the
    /// whole run whenever the cooperative pool was busy.
    func preinstall(_ entry: LocalModelEntry, root: URL) {
        lock.withLock { fetches += 1 }
        try? Self.writeFiles(of: entry, root: root)
    }

    func release() {
        let pending = lock.withLock { () -> CheckedContinuation<Void, Never>? in defer { gate = nil }; return gate }
        pending?.resume()
    }

    func fetch(root: URL) -> @Sendable (DownloadableAsset, @escaping @Sendable (Int64) -> Void) async throws -> Void {
        { [self] asset, progress in
            lock.withLock { fetches += 1; order.append(asset.id) }
            guard let id = LocalModelEntry.entryID(forAssetID: asset.id), let entry = ModelRegistry.entry(id: id) else { return }
            progress(entry.downloadBytes / 3)
            if holds {
                await withCheckedContinuation { continuation in lock.withLock { gate = continuation } }
            }
            try Task.checkCancellation()
            try Self.writeFiles(of: entry, root: root)
            progress(entry.downloadBytes)
        }
    }
}

@Suite("Cleanup model setting (M5/M6)")
@MainActor
struct CleanupModelControllerTests {
    struct Rig {
        let controller: CleanupModelController
        let settings: AppSettings
        let downloads: DownloadCoordinator
        let apple: NamedModel
        let locals: Collected<NamedModel>
        let residencies: Collected<LocalModelResidency>
        let fetch: FakeFetch
        let root: URL
    }

    /// An 8 GB base-chip Mac (recommended: the 0.8B, a 645 MB sparse "download").
    func rig(choice: CleanupBackendChoice = .apple, preinstalled: Bool = false, holds: Bool = false,
                     machine: MachineProfile = Self.small, useStoredChoice: Bool = true,
                     useIntentModels: Bool = false, verificationSucceeds: Bool = true,
                     alsoInstalled: [String] = [], fourBOptIn: Bool = false, preferTwoB: Bool = false,
                     runtimeAvailable: Bool = true, useSealedModels: Bool = false, keys: ModelKeyProvider? = nil,
                     sealedOpens: (@Sendable (LocalModelEntry, URL) async -> Bool)? = nil) -> Rig {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("hushy-cleanup-\(UUID().uuidString)", isDirectory: true)
        let defaults = UserDefaults(suiteName: "hushy-cleanup-tests-\(UUID().uuidString)")!
        let settings = AppSettings(defaults: defaults, systemRegion: nil, machine: machine)
        if useStoredChoice { settings.cleanupBackend = choice }
        if fourBOptIn { settings.useIntentCleanup4B = true }
        if preferTwoB { settings.preferIntentCleanup2B = true }
        let status = SpeechModelStatus()
        let downloads = DownloadCoordinator(
            status: status, speech: ReadySpeech(status: status), requiredBytes: 1, clock: NoSleepClock(),
            backoff: RetryBackoff(initialDelay: 0, multiplier: 1, maximumDelay: 0, maximumAttempts: 1, jitter: 0))
        let apple = NamedModel("apple")
        let locals = Collected<NamedModel>()
        let residencies = Collected<LocalModelResidency>()
        let factory = LocalBackendFactory(isRuntimeAvailable: { runtimeAvailable }, make: { entry, _, fallback, idle, log, _ in
            let local = NamedModel("local:\(entry.id)")
            locals.append(local)
            let residency = LocalModelResidency(idleSeconds: idle, clock: NoSleepClock(), unload: { await local.unload() })
            residencies.append(residency)
            let managed = ManagedLocalModel(base: local, residency: residency)
            let chain = FallbackLanguageModel(
                primary: RecordingLanguageModel(managed, label: "local", log: log),
                secondary: RecordingLanguageModel(fallback, label: "apple", log: log))
            return .init(model: chain, residency: residency)
        })
        let fetch = FakeFetch()
        fetch.holds = holds
        if preinstalled {
            // What a Mac had before the intent default: the old recommendation.
            let entry = ModelTierPolicy.recommended(for: machine, useIntentModels: false)
            fetch.preinstall(entry, root: root)
        }
        for id in alsoInstalled {
            if let entry = ModelRegistry.entry(id: id) { fetch.preinstall(entry, root: root) }
        }
        let controller = CleanupModelController(
            settings: settings, downloads: downloads, apple: apple, factory: factory, machine: machine,
            modelsRoot: root, health: ModelHealth(), fetch: fetch.fetch(root: root),
            useIntentModels: useIntentModels, useSealedModels: useSealedModels, keys: keys, sealedOpens: sealedOpens,
            verifyDownloaded: { _, _ in verificationSucceeds })
        return Rig(controller: controller, settings: settings, downloads: downloads, apple: apple, locals: locals,
                   residencies: residencies, fetch: fetch, root: root)
    }

    static let small = MachineProfile(physicalMemoryGB: 8, chip: .base, chipName: "Apple M1")

    func settle() async {
        for _ in 0..<30 {
            await Task.yield()
            try? await Task.sleep(for: .milliseconds(5))
        }
    }

    func answer(_ model: any LanguageModel) async throws -> String {
        try await model.respond(instructions: "i", prompt: "p", schema: SmartCleaner.cleanedSchema, options: .greedy)
    }

    @Test("default is Apple Intelligence; nothing downloads")
    func defaultApple() async throws {
        let rig = rig()
        rig.downloads.start()
        await settle()
        #expect(rig.controller.effective == .apple)
        #expect(rig.controller.install == .notInstalled)
        #expect(rig.controller.selectedEntry.id == ModelRegistry.qwen08B4bit, "8 GB → 0.8B")
        #expect(try await answer(rig.controller.backend) == #"{"text":"apple"}"#)
        #expect(rig.fetch.fetches == 0)
    }

    @Test("hidden intent setting selects 4B, then 2B intent by memory and chip; off keeps the recommendation")
    func intentSelection() {
        let large = MachineProfile(physicalMemoryGB: 24, chip: .pro, chipName: "Apple M4 Pro")
        let small = MachineProfile(physicalMemoryGB: 16, chip: .pro, chipName: "Apple M4 Pro")
        let base = MachineProfile(physicalMemoryGB: 16, chip: .base, chipName: "Apple M1")
        let eligible = rig(machine: large)
        #expect(eligible.controller.selectedEntry.id == ModelRegistry.hushyCleanup2B)
        eligible.settings.useIntentCleanup4B = true
        #expect(eligible.controller.selectedEntry.id == ModelRegistry.hushyCleanup4B)
        eligible.controller.selectModel(ModelRegistry.hushyCleanup2B)
        #expect(!eligible.settings.useIntentCleanup4B)
        #expect(eligible.controller.selectedEntry.id == ModelRegistry.hushyCleanup2B)
        let ineligible = rig(machine: small)
        #expect(ineligible.controller.selectedEntry.id == ModelRegistry.hushyCleanup2B)
        ineligible.settings.useIntentCleanup4B = true
        #expect(ineligible.controller.selectedEntry.id == ModelRegistry.hushyCleanup2BIntent)
        let baseMac = rig(machine: base)
        baseMac.settings.useIntentCleanup4B = true
        #expect(baseMac.controller.selectedEntry.id == ModelRegistry.hushyCleanup2BIntent)
        let eightGB = rig(machine: Self.small)
        eightGB.settings.useIntentCleanup4B = true
        #expect(eightGB.controller.selectedEntry.id == ModelRegistry.qwen08B4bit)
    }

    @Test("the hidden 2B preference picks the 2B intent model on a Mac that could run the 4B, only with the intent setting on")
    func preferTwoBIntent() {
        let rig = rig(machine: MachineProfile(physicalMemoryGB: 24, chip: .pro, chipName: "Apple M4 Pro"))
        rig.settings.preferIntentCleanup2B = true
        #expect(rig.controller.selectedEntry.id == ModelRegistry.hushyCleanup2B)
        rig.settings.useIntentCleanup4B = true
        #expect(rig.controller.selectedEntry.id == ModelRegistry.hushyCleanup2BIntent)
        rig.settings.preferIntentCleanup2B = false
        #expect(rig.controller.selectedEntry.id == ModelRegistry.hushyCleanup4B)
    }

    @Test("hidden intent setting still wins over an explicit model with the default switch off")
    func hiddenIntentWins() {
        let machine = MachineProfile(physicalMemoryGB: 24, chip: .pro)
        let rig = rig(machine: machine)
        rig.settings.localCleanupModelID = ModelRegistry.qwen2B4bit
        rig.settings.useIntentCleanup4B = true
        #expect(rig.controller.selectedEntry.id == ModelRegistry.hushyCleanup4B)
        #expect(rig.controller.recommendedEntry.id == ModelRegistry.hushyCleanup2B)
    }

    @Test("recommendation handover keeps the installed model through download and checksum verification")
    func recommendationHandover() async throws {
        let machine = MachineProfile(physicalMemoryGB: 24, chip: .pro)
        let rig = rig(choice: .local, preinstalled: true, holds: true,
                      machine: machine, useIntentModels: true)
        let old = try #require(ModelRegistry.entry(id: ModelRegistry.hushyCleanup2B))
        let oldDirectory = rig.controller.directory(for: old)
        rig.downloads.start()
        await settle()
        #expect(rig.settings.localCleanupModelID == nil)
        #expect(rig.controller.selectedEntry.id == ModelRegistry.hushyCleanup4B)
        #expect(rig.controller.effective == .local(old.id))
        #expect(FileManager.default.fileExists(atPath: oldDirectory.path))
        #expect(try await answer(rig.controller.backend) == #"{"text":"local:hushy-cleanup-2b-v5.4-4bit"}"#)
        rig.fetch.release()
        await settle()
        #expect(rig.controller.effective == .local(ModelRegistry.hushyCleanup4B))
        #expect(!FileManager.default.fileExists(atPath: oldDirectory.path))
    }

    @Test("failed checksum keeps the old recommendation and its files")
    func failedRecommendationHandover() async throws {
        let machine = MachineProfile(physicalMemoryGB: 16, chip: .base)
        let rig = rig(choice: .local, preinstalled: true, holds: true,
                      machine: machine, useIntentModels: true, verificationSucceeds: false)
        let old = try #require(ModelRegistry.entry(id: ModelRegistry.hushyCleanup2B))
        let oldDirectory = rig.controller.directory(for: old)
        rig.downloads.start()
        await settle()
        rig.fetch.release()
        await settle()
        #expect(rig.controller.effective == .local(old.id))
        #expect(rig.controller.install == .failed("Some model files are damaged."))
        #expect(FileManager.default.fileExists(atPath: oldDirectory.path))
    }

    @Test("download → ready → switch, without a restart; latencies are logged without text")
    func downloadReadySwitch() async throws {
        let rig = rig(holds: true)
        rig.downloads.start()
        await settle()
        rig.controller.choose(.local)
        await settle()
        guard case .downloading(let received, let total, _) = rig.controller.install else {
            Issue.record("expected downloading, got \(rig.controller.install)"); return
        }
        #expect(total == rig.controller.selectedEntry.downloadBytes)
        #expect(received == total / 3)
        #expect(rig.controller.effective == .rules, "no Apple Intelligence while Hushy's model downloads")
        #expect(!rig.controller.backend.isAvailable)
        #expect(rig.apple.calls == 0)

        rig.fetch.release()
        await settle()
        #expect(rig.controller.install == .ready)
        #expect(rig.controller.effective == .local(ModelRegistry.qwen08B4bit))
        #expect(try await answer(rig.controller.backend) == #"{"text":"local:qwen3.5-0.8b-4bit"}"#)
        #expect(rig.controller.recentCalls.map(\.backend) == ["local"])
        #expect(rig.residencies.all.last?.idleSeconds == 120, "8 GB → idle unload after 120 s")
    }

    @Test("promoted default queues automatically, then switches from the simpler fixes to local")
    func promotedDefaultDownload() async {
        let machine = MachineProfile(physicalMemoryGB: 16, chip: .base)
        let rig = rig(holds: true, machine: machine, useStoredChoice: false)
        #expect(rig.settings.cleanupBackend == .local)
        #expect(rig.controller.selectedEntry.id == ModelRegistry.hushyCleanup2B)
        rig.downloads.start()
        await settle()
        #expect(rig.downloads.queue[rig.controller.selectedEntry.asset.id] != nil)
        #expect(rig.controller.effective == .rules)
        #expect(rig.controller.activeBackendDescription == "Hushy's own model is still downloading. Until it is ready, Hushy uses its simpler fixes (fillers, punctuation, capitals).")
        rig.fetch.release()
        await settle()
        #expect(rig.controller.install == .ready)
        #expect(rig.controller.effective == .local(ModelRegistry.hushyCleanup2B))
        // Plain words: what polishes the text, never the model's name, revision or call log.
        #expect(rig.controller.activeBackendDescription == "Hushy's own model polishes your dictation on this Mac. Apple Intelligence steps in when it cannot answer in time.")
        #expect(!rig.controller.activeBackendDescription.contains("v5.4"))
    }

    @Test("stored Apple choice survives promotion")
    func storedAppleChoice() {
        let defaults = UserDefaults(suiteName: "hushy-choice-\(UUID().uuidString)")!
        let machine = MachineProfile(physicalMemoryGB: 16, chip: .pro)
        #expect(AppSettings(defaults: defaults, machine: machine).cleanupBackend == .local)
        #expect(AppSettings(defaults: defaults, machine: Self.small).cleanupBackend == .apple)
        defaults.set("apple", forKey: "cleanupBackend")
        #expect(AppSettings(defaults: defaults, machine: machine).cleanupBackend == .apple)
    }

    @Test("delete reverts to Apple, unloads the model and removes its files")
    func deleteReverts() async throws {
        let rig = rig(choice: .local, preinstalled: true)
        rig.downloads.start()
        await settle()
        #expect(rig.controller.effective == .local(ModelRegistry.qwen08B4bit))
        let directory = rig.controller.directory(for: rig.controller.selectedEntry)
        #expect(FileManager.default.fileExists(atPath: directory.path))

        rig.controller.deleteModel()
        await settle()
        #expect(rig.controller.effective == .apple)
        #expect(rig.settings.cleanupBackend == .apple)
        #expect(rig.controller.install == .notInstalled)
        #expect(!FileManager.default.fileExists(atPath: directory.path))
        #expect(rig.locals.all.first?.unloads == 1)
        #expect(try await answer(rig.controller.backend) == #"{"text":"apple"}"#)
    }

    @Test("rules only: no model is called")
    func rulesOnly() async {
        let rig = rig()
        rig.controller.choose(.rules)
        #expect(rig.controller.effective == .rules)
        #expect(!rig.controller.backend.isAvailable)
        let output = await SmartCleaner(model: rig.controller.backend).clean("um so ship it friday", options: CleanupOptions(level: .polished))
        #expect(!output.usedModel)
        #expect(rig.apple.calls == 0)
        #expect(rig.controller.activeBackendDescription == "Simple fixes only (fillers, punctuation, capitals). No model rewrites your words.")
        rig.controller.choose(.apple)
        #expect(rig.controller.effective == .apple)
        #expect(rig.controller.activeBackendDescription == "Apple Intelligence polishes your dictation on this Mac.")
    }

    @Test("a snapshot can show that nothing can polish, and shows it as available unless told so")
    func snapshotPinsAvailability() async {
        let rig = rig()
        rig.controller.pinForSnapshot(choice: .apple, install: .notInstalled, effective: .apple, calls: [])
        #expect(rig.controller.isModelAvailable)
        #expect(rig.controller.activeBackendDescription == "Apple Intelligence polishes your dictation on this Mac.")
        rig.controller.pinForSnapshot(choice: .apple, install: .notInstalled, effective: .apple, calls: [], modelAvailable: false)
        #expect(!rig.controller.isModelAvailable)
        #expect(rig.controller.activeBackendDescription
            == "Apple Intelligence is not available on this Mac right now, so Hushy uses its simpler fixes (fillers, punctuation, capitals).")
    }

    @Test("Settings describes every waiting state of Hushy's own model in plain words")
    func plainDescriptions() async {
        let rig = rig()
        let entry = rig.controller.recommendedEntry
        let cases: [(LocalModelInstall, String)] = [
            (.downloading(received: 1, total: 10, secondsRemaining: 60), "Hushy's own model is still downloading. Until it is ready, Apple Intelligence polishes your dictation."),
            (.paused(received: 1, total: 10, reason: .offline), "The download of Hushy's own model is paused. Until it finishes, Apple Intelligence polishes your dictation."),
            (.failed("HTTP 503"), "Hushy's own model could not be downloaded, so Apple Intelligence polishes your dictation."),
            (.notInstalled, "Hushy's own model is not downloaded yet, so Apple Intelligence polishes your dictation."),
            (.ready, "Hushy's own model cannot run on this Mac right now, so Apple Intelligence polishes your dictation."),
        ]
        for (install, expected) in cases {
            rig.controller.pinForSnapshot(choice: .local, install: install, effective: .apple, calls: [])
            #expect(rig.controller.activeBackendDescription == expected)
        }
        rig.controller.pinForSnapshot(choice: .local, install: .ready, effective: .local(entry.id), calls: [])
        let ready = rig.controller.activeBackendDescription
        for term in ["fallback", "model call", "session", entry.displayName, entry.source.revision, "HTTP"] where !term.isEmpty {
            #expect(!ready.contains(term), "internal wording: \(term)")
        }
    }

    @Test("while Hushy's model downloads the simpler fixes run, and the same words describe it in Settings")
    func rulesWhileDownloadingDescriptions() {
        let rig = rig()
        let simpler = "Hushy uses its simpler fixes (fillers, punctuation, capitals)"
        let cases: [(LocalModelInstall, String)] = [
            (.downloading(received: 1, total: 10, secondsRemaining: 60), "Hushy's own model is still downloading. Until it is ready, \(simpler)."),
            (.paused(received: 1, total: 10, reason: .offline), "The download of Hushy's own model is paused. Until it finishes, \(simpler)."),
            (.failed("HTTP 503"), "Hushy's own model could not be downloaded, so \(simpler)."),
            (.notInstalled, "Hushy's own model is not downloaded yet, so \(simpler)."),
        ]
        for (install, expected) in cases {
            rig.controller.pinForSnapshot(choice: .local, install: install, effective: .rules, calls: [])
            #expect(rig.controller.activeBackendDescription == expected)
            #expect(!rig.controller.activeBackendDescription.contains("Apple"))
        }
    }

    @Test("the pill line and bar for a model that is not ready: a bar while downloading, never for a ready model")
    func waitingLines() {
        let line = CleanupModelController.waitingLine(for:)
        let progress = CleanupModelController.waitingProgress(for:)
        #expect(line(.downloading(received: 38, total: 100, secondsRemaining: 140)) == "Getting faster — downloading the model")
        #expect(progress(.downloading(received: 38, total: 100, secondsRemaining: 140)) == 0.38)
        #expect(progress(.downloading(received: 100, total: 100, secondsRemaining: nil)) == 0.99)
        #expect(progress(.downloading(received: 0, total: 0, secondsRemaining: nil)) == nil)
        #expect(progress(.notInstalled) == nil)
        #expect(line(.downloading(received: 0, total: 0, secondsRemaining: nil)) == "Getting faster — downloading the model")
        #expect(line(.notInstalled) == "Getting faster — downloading the model")
        #expect(line(.paused(received: 1, total: 10, reason: .user)) == "Hushy's model download is paused")
        #expect(line(.failed("HTTP 503")) == "Hushy's model isn't ready")
        #expect(line(.ready) == nil)
    }

    @Test("while the model downloads, a short dictation stays on rules and the pill says so; the same cleaner uses the model once it is ready")
    func firstLaunchRulesWithPillNote() async throws {
        let rig = rig(holds: true, machine: MachineProfile(physicalMemoryGB: 16, chip: .base), useStoredChoice: false)
        rig.downloads.start()
        await settle()
        #expect(rig.controller.effective == .rules)
        guard case .cleanupModelWaiting(let line, let progress) = rig.controller.waitingBanner else {
            Issue.record("expected the downloading banner, got \(String(describing: rig.controller.waitingBanner))"); return
        }
        #expect(line == "Getting faster — downloading the model")
        #expect(progress.map { abs($0 - 1.0 / 3) < 0.01 } == true, "the fake download reports a third")
        let backend = rig.controller.backend
        let cleaner = SmartCleaner(model: backend, health: ModelHealth(), secondOpinion: rig.apple)
        let short = "how's it going"
        #expect(TextStats.wordCount(short) <= TextSegmentation.segmentThresholdWords)
        let shortOutput = await cleaner.clean(short, options: CleanupOptions(level: .polished))
        #expect(!shortOutput.usedModel)
        #expect(rig.apple.calls == 0)
        let long = String(repeating: "word ", count: TextSegmentation.segmentThresholdWords + 1)
        #expect(TextStats.wordCount(long) > TextSegmentation.segmentThresholdWords)
        let longOutput = await cleaner.clean(long, options: CleanupOptions(level: .polished))
        #expect(!longOutput.usedModel)
        #expect(rig.apple.calls == 0, "a long dictation stays on rules while the model downloads")
        rig.fetch.release()
        await settle()
        #expect(rig.controller.backend === backend)
        #expect(rig.controller.effective == .local(ModelRegistry.hushyCleanup2B))
        #expect(rig.controller.waitingBanner == nil, "nothing to say once the model is ready")
        let local = try #require(rig.locals.all.first)
        let callsBefore = local.calls
        _ = await cleaner.clean(short, options: CleanupOptions(level: .polished))
        #expect(local.calls > callsBefore, "the cleaner captured before the download asks the model that arrived")
        #expect(try await answer(backend) == #"{"text":"local:\#(ModelRegistry.hushyCleanup2B)"}"#)
        #expect(rig.apple.calls == 0)
    }

    @Test("switching to a model that is not downloaded keeps the installed one that fits, with its files, until the new one is ready")
    func standInKeepsFilesUntilReady() async throws {
        let machine = MachineProfile(physicalMemoryGB: 24, chip: .pro)
        let rig = rig(choice: .local, holds: true, machine: machine, useIntentModels: true,
                      alsoInstalled: [ModelRegistry.hushyCleanup2BIntent], fourBOptIn: true)
        let twoB = try #require(ModelRegistry.entry(id: ModelRegistry.hushyCleanup2BIntent))
        let twoBDirectory = rig.controller.directory(for: twoB)
        rig.downloads.start()
        await settle()
        #expect(rig.controller.selectedEntry.id == ModelRegistry.hushyCleanup4B)
        #expect(rig.controller.install != .ready)
        #expect(rig.controller.effective == .local(twoB.id), "the 2B keeps answering while the 4B downloads")
        #expect(try await answer(rig.controller.backend) == #"{"text":"local:\#(twoB.id)"}"#)
        #expect(rig.apple.calls == 0)
        #expect(rig.controller.waitingBanner == nil, "a local model is polishing; no note")
        #expect(rig.controller.activeBackendDescription.hasPrefix(
            "Hushy's new model is still downloading. Until it is ready, the one already on this Mac polishes your dictation."))
        rig.fetch.release()
        await settle()
        #expect(rig.controller.effective == .local(ModelRegistry.hushyCleanup4B))
        #expect(FileManager.default.fileExists(atPath: twoBDirectory.path), "the stand-in stays: the person may switch back")
        #expect(rig.controller.activeBackendDescription.hasPrefix("Hushy's own model polishes your dictation on this Mac."))
    }

    @Test("with the intent defaults on, the 4B is selected only on 24 GB+ Pro/Max Macs", arguments: [
        (8, MachineProfile.ChipClass.base, ModelRegistry.qwen08B4bit),
        (16, .base, ModelRegistry.hushyCleanup2BIntent),
        (16, .pro, ModelRegistry.hushyCleanup2BIntent),
        (24, .base, ModelRegistry.hushyCleanup2BIntent),
        (24, .pro, ModelRegistry.hushyCleanup4B),
        (36, .max, ModelRegistry.hushyCleanup4B),
    ])
    func fourBIsTheDefaultOnProMax(memory: Int, chip: MachineProfile.ChipClass, expected: String) {
        let machine = MachineProfile(physicalMemoryGB: memory, chip: chip)
        let rig = rig(machine: machine, useIntentModels: true)
        #expect(rig.controller.selectedEntry.id == expected)
        #expect(rig.controller.recommendedEntry.id == expected)
        #expect(rig.settings.localCleanupModelID == nil)
        #expect(!rig.settings.useIntentCleanup4B, "no hidden switch needed")
    }

    @Test("an existing 24 GB Pro user on the installed 2B keeps dictating with it while the 4B downloads, then the 4B takes over")
    func migrationFromTheTwoB() async throws {
        let machine = MachineProfile(physicalMemoryGB: 24, chip: .pro, chipName: "Apple M4 Pro")
        let rig = rig(choice: .local, holds: true, machine: machine, useIntentModels: true,
                      alsoInstalled: [ModelRegistry.hushyCleanup2BIntent])
        let twoB = try #require(ModelRegistry.entry(id: ModelRegistry.hushyCleanup2BIntent))
        let twoBDirectory = rig.controller.directory(for: twoB)
        let installedFetches = rig.fetch.fetches   // the pre-installed 2B counts as one
        rig.downloads.start()
        await settle()
        #expect(rig.controller.selectedEntry.id == ModelRegistry.hushyCleanup4B)
        #expect(rig.controller.install != .ready)
        #expect(rig.fetch.fetches == installedFetches + 1, "the 4B download starts by itself")
        let fourBAssetID = try #require(ModelRegistry.entry(id: ModelRegistry.hushyCleanup4B)).asset.id
        #expect(rig.fetch.requested == [fourBAssetID], "an installed 2B means no second 2B download")
        #expect(rig.controller.effective == .local(twoB.id), "the 2B answers while the 4B downloads")
        #expect(try await answer(rig.controller.backend) == #"{"text":"local:\#(twoB.id)"}"#)
        #expect(rig.apple.calls == 0)
        #expect(rig.controller.waitingBanner == nil)
        rig.fetch.release()
        await settle()
        #expect(rig.controller.effective == .local(ModelRegistry.hushyCleanup4B))
        #expect(try await answer(rig.controller.backend) == #"{"text":"local:\#(ModelRegistry.hushyCleanup4B)"}"#)
        #expect(FileManager.default.fileExists(atPath: twoBDirectory.path), "the 2B's files are kept")
        #expect(rig.settings.localCleanupModelID == nil)
    }

    @Test("a fresh 24 GB Pro install fetches the 2B first, polishes with it once it is in, then the 4B takes over")
    func freshInstallTwoBFirst() async throws {
        let machine = MachineProfile(physicalMemoryGB: 24, chip: .pro, chipName: "Apple M4 Pro")
        let rig = rig(choice: .local, holds: true, machine: machine, useIntentModels: true)
        let twoB = try #require(ModelRegistry.entry(id: ModelRegistry.hushyCleanup2BIntent))
        let fourB = try #require(ModelRegistry.entry(id: ModelRegistry.hushyCleanup4B))
        let twoBDirectory = rig.controller.directory(for: twoB)
        #expect(rig.controller.selectedEntry.id == fourB.id)
        rig.downloads.start()
        await settle()
        #expect(rig.fetch.requested == [twoB.asset.id], "only the 2B moves; the 4B waits in the queue")
        #expect(rig.downloads.queue[fourB.asset.id]?.state == .queued)
        #expect(rig.downloads.queue[twoB.asset.id]?.state == .downloading)
        #expect(rig.controller.effective == .rules)
        guard case .cleanupModelWaiting(let line, let progress) = rig.controller.waitingBanner else {
            Issue.record("expected the downloading note, got \(String(describing: rig.controller.waitingBanner))"); return
        }
        #expect(line == "Getting faster — downloading the model")
        #expect(progress.map { abs($0 - 1.0 / 3) < 0.01 } == true, "the bar follows the 2B, the model about to answer")
        #expect(rig.apple.calls == 0)

        rig.fetch.release()   // the 2B lands
        await settle()
        #expect(rig.controller.effective == .local(twoB.id), "the 2B answers as soon as it is in")
        #expect(try await answer(rig.controller.backend) == #"{"text":"local:\#(twoB.id)"}"#)
        #expect(rig.controller.waitingBanner == nil, "a local model polishes; no note while the 4B downloads")
        #expect(rig.fetch.requested == [twoB.asset.id, fourB.asset.id], "the 4B is requested after the 2B")
        #expect(rig.downloads.queue[fourB.asset.id]?.state == .downloading)
        #expect(rig.apple.calls == 0)

        rig.fetch.release()   // the 4B lands
        await settle()
        #expect(rig.controller.effective == .local(fourB.id))
        #expect(try await answer(rig.controller.backend) == #"{"text":"local:\#(fourB.id)"}"#)
        #expect(FileManager.default.fileExists(atPath: twoBDirectory.path), "the 2B's files are kept")
        #expect(rig.settings.localCleanupModelID == nil)
    }

    @Test("a fresh 16 GB Pro install downloads only the 2B, as before")
    func freshSixteenGBOnlyTwoB() async throws {
        let machine = MachineProfile(physicalMemoryGB: 16, chip: .pro)
        let rig = rig(choice: .local, holds: true, machine: machine, useIntentModels: true)
        let twoB = try #require(ModelRegistry.entry(id: ModelRegistry.hushyCleanup2BIntent))
        rig.downloads.start()
        await settle()
        #expect(rig.controller.selectedEntry.id == twoB.id)
        #expect(rig.fetch.requested == [twoB.asset.id])
        rig.fetch.release()
        await settle()
        #expect(rig.controller.effective == .local(twoB.id))
        #expect(rig.fetch.requested == [twoB.asset.id], "no 4B follows")
    }

    @Test("with the 4B already installed there is no 2B download at all")
    func installedFourBNoTwoB() async throws {
        let machine = MachineProfile(physicalMemoryGB: 24, chip: .pro)
        let rig = rig(choice: .local, holds: true, machine: machine, useIntentModels: true,
                      alsoInstalled: [ModelRegistry.hushyCleanup4B])
        rig.downloads.start()
        await settle()
        #expect(rig.controller.install == .ready)
        #expect(rig.controller.effective == .local(ModelRegistry.hushyCleanup4B))
        #expect(rig.fetch.requested.isEmpty)
        #expect(rig.downloads.queue[try #require(ModelRegistry.entry(id: ModelRegistry.hushyCleanup2BIntent)).asset.id] == nil)
    }

    @Test("pausing the local model on a fresh 24 GB install stops the 2B too; choosing it again resumes")
    func leavingLocalPausesTheFirstDownload() async throws {
        let machine = MachineProfile(physicalMemoryGB: 24, chip: .pro)
        let rig = rig(choice: .local, holds: true, machine: machine, useIntentModels: true)
        let twoB = try #require(ModelRegistry.entry(id: ModelRegistry.hushyCleanup2BIntent))
        rig.downloads.start()
        await settle()
        rig.controller.choose(.apple)
        await settle()
        #expect(rig.downloads.queue[twoB.asset.id]?.state == .paused)
        rig.controller.choose(.local)
        await settle()
        #expect(rig.downloads.queue[twoB.asset.id]?.state != .paused)
    }

    @Test("a 16 GB Pro Mac with the 2B installed stays on it and downloads nothing")
    func sixteenGBStaysOnTwoB() async throws {
        let machine = MachineProfile(physicalMemoryGB: 16, chip: .pro)
        let rig = rig(choice: .local, holds: true, machine: machine, useIntentModels: true,
                      alsoInstalled: [ModelRegistry.hushyCleanup2BIntent])
        let installedFetches = rig.fetch.fetches   // the pre-installed 2B counts as one
        rig.downloads.start()
        await settle()
        #expect(rig.controller.selectedEntry.id == ModelRegistry.hushyCleanup2BIntent)
        #expect(rig.controller.effective == .local(ModelRegistry.hushyCleanup2BIntent))
        #expect(rig.controller.install == .ready)
        #expect(rig.fetch.fetches == installedFetches, "nothing new is downloaded")
    }

    @Test("preferIntentCleanup2B is the way back to the 2B on a 24 GB Pro Mac: no 4B download")
    func preferTwoBIsTheWayBack() async throws {
        let machine = MachineProfile(physicalMemoryGB: 24, chip: .pro)
        let rig = rig(choice: .local, holds: true, machine: machine, useIntentModels: true,
                      alsoInstalled: [ModelRegistry.hushyCleanup2BIntent], preferTwoB: true)
        let installedFetches = rig.fetch.fetches   // the pre-installed 2B counts as one
        rig.downloads.start()
        await settle()
        #expect(rig.controller.selectedEntry.id == ModelRegistry.hushyCleanup2BIntent)
        #expect(rig.controller.recommendedEntry.id == ModelRegistry.hushyCleanup2BIntent)
        #expect(rig.controller.effective == .local(ModelRegistry.hushyCleanup2BIntent))
        #expect(rig.fetch.fetches == installedFetches, "nothing new is downloaded")
        #expect(rig.controller.fit(try #require(ModelRegistry.entry(id: ModelRegistry.hushyCleanup2BIntent))) == .recommended)
    }

    @Test("choosing the 2B intent model from the picker sticks on a 4B Mac, even with the hidden 4B switch on")
    func pickingTheTwoBSticks() throws {
        let machine = MachineProfile(physicalMemoryGB: 24, chip: .pro)
        let rig = rig(choice: .local, holds: true, machine: machine, useIntentModels: true, fourBOptIn: true)
        #expect(rig.controller.selectedEntry.id == ModelRegistry.hushyCleanup4B)
        rig.controller.selectModel(ModelRegistry.hushyCleanup2BIntent)
        #expect(rig.settings.localCleanupModelID == ModelRegistry.hushyCleanup2BIntent)
        #expect(!rig.settings.useIntentCleanup4B)
        #expect(rig.controller.selectedEntry.id == ModelRegistry.hushyCleanup2BIntent)
    }

    @Test("an installed model that does not fit this Mac is not a stand-in")
    func misfitIsNoStandIn() async {
        let rig = rig(choice: .local, holds: true, machine: Self.small, alsoInstalled: [ModelRegistry.hushyCleanup2BIntent])
        rig.downloads.start()
        await settle()
        #expect(rig.controller.effective == .rules)
    }

    @Test("a Mac that cannot run the local model keeps today's behaviour: Apple Intelligence, no pill note")
    func noRuntimeKeepsApple() async {
        let rig = rig(choice: .local, holds: true, runtimeAvailable: false)
        rig.downloads.start()
        await settle()
        #expect(rig.controller.effective == .apple)
        #expect(rig.controller.waitingBanner == nil)
    }

    @Test("an explicit Apple choice stays Apple during a download and shows no note")
    func explicitAppleStays() async {
        let rig = rig(choice: .apple, holds: true, machine: MachineProfile(physicalMemoryGB: 16, chip: .base))
        rig.downloads.start()
        await settle()
        #expect(rig.controller.effective == .apple)
        #expect(rig.controller.waitingBanner == nil)
    }

    @Test("leaving the local model mid-download pauses it and keeps Apple; choosing it again resumes")
    func leaveMidDownload() async {
        let rig = rig(holds: true)
        rig.downloads.start()
        await settle()
        rig.controller.choose(.local)
        await settle()
        rig.controller.choose(.apple)
        await settle()
        guard case .paused(_, _, .user) = rig.controller.install else {
            Issue.record("expected a user pause, got \(rig.controller.install)"); return
        }
        #expect(rig.controller.effective == .apple)
        rig.fetch.holds = false
        rig.controller.choose(.local)
        await settle()
        #expect(rig.controller.install == .ready)
        #expect(rig.controller.effective == .local(ModelRegistry.qwen08B4bit))
    }

    @Test("an installed model is used from launch; critical memory pressure falls back to Apple until normal")
    func launchAndMemoryPressure() async throws {
        let rig = rig(choice: .local, preinstalled: true)
        #expect(rig.controller.effective == .local(ModelRegistry.qwen08B4bit))
        #expect(rig.fetch.fetches == 1, "only the preinstall; no download at launch")
        #expect(try await answer(rig.controller.backend) == #"{"text":"local:qwen3.5-0.8b-4bit"}"#)
        #expect(rig.controller.activeBackendDescription.hasSuffix("The most recent cleanup used Hushy's own model."))

        rig.controller.memoryPressure(.critical)
        await settle()
        #expect(rig.controller.isSuspendedForMemory)
        // (The rig's clock never sleeps, so the 8 GB idle unload has fired too; count only pressure.)
        #expect(rig.residencies.all.first?.stats.pressureUnloads == 1)
        #expect(try await answer(rig.controller.backend) == #"{"text":"apple"}"#)
        #expect(rig.controller.activeBackendDescription.hasPrefix("This Mac is low on memory, so Apple Intelligence polishes your dictation for now."))
        #expect(rig.controller.activeBackendDescription.hasSuffix("The most recent cleanup used Apple Intelligence."))
        rig.controller.memoryPressure(.normal)
        #expect(try await answer(rig.controller.backend) == #"{"text":"local:qwen3.5-0.8b-4bit"}"#)
    }

    @Test("an override model replaces the recommended one; the old files are removed")
    func overrideModel() async {
        let rig = rig(choice: .local, preinstalled: true)
        rig.downloads.start()
        await settle()
        let oldDirectory = rig.controller.directory(for: rig.controller.selectedEntry)
        rig.controller.selectModel(ModelRegistry.qwen2B4bit)
        #expect(rig.settings.localCleanupModelID == ModelRegistry.qwen2B4bit)
        #expect(!FileManager.default.fileExists(atPath: oldDirectory.path))
        if case .override = rig.controller.fit(rig.controller.selectedEntry) {} else { Issue.record("2B on 8 GB is an override") }
        await settle()
        #expect(rig.controller.effective == .local(ModelRegistry.qwen2B4bit))
        rig.controller.selectModel(rig.controller.recommendedEntry.id)
        #expect(rig.settings.localCleanupModelID == nil, "back to following the recommendation")
    }

    @Test("verify catches damaged files and stops using the model until repaired")
    func verifyDamaged() async throws {
        let rig = rig(choice: .local, preinstalled: true)
        #expect(rig.controller.effective == .local(ModelRegistry.qwen08B4bit))
        rig.controller.verifyFiles()
        for _ in 0..<200 where rig.controller.verification == .checking { try await Task.sleep(for: .milliseconds(20)) }
        guard case .damaged(let paths) = rig.controller.verification else {
            Issue.record("sparse files can't match the pinned SHA-256s: \(rig.controller.verification)"); return
        }
        #expect(!paths.isEmpty)
        #expect(rig.controller.effective == .rules, "a damaged model with no stand-in never hands the work to Apple Intelligence")
        #expect(rig.controller.install == .failed("Some model files are damaged."))
    }

    // MARK: Sealed models (docs/engineering/SEALED-MODELS.md)

    /// Keys from a store the test can look into, fetched by a counting fake.
    private final class KeyDesk: ModelKeyFetching, @unchecked Sendable {
        private let lock = NSLock()
        private(set) var fetched: [String] = []
        var fails = false
        func fetchKey(modelID: String) async throws -> Data {
            lock.withLock { fetched.append(modelID) }
            if fails { throw ModelKeyError.notPublished }
            return Data(repeating: 3, count: 32)
        }
        var count: Int { lock.withLock { fetched.count } }
    }

    private let pro24 = MachineProfile(physicalMemoryGB: 24, chip: .pro, chipName: "Apple M4 Pro")

    @Test("with sealed delivery on, a fresh 24 GB Pro install fetches the sealed 2B then the sealed 4B, each key first")
    func sealedFreshInstall() async throws {
        let desk = KeyDesk()
        let rig = rig(choice: .local, holds: true, machine: pro24, useIntentModels: true, useSealedModels: true,
                      keys: ModelKeyProvider(store: InMemoryModelKeyStore(), fetcher: desk), sealedOpens: { _, _ in true })
        let twoB = try #require(ModelRegistry.entry(id: ModelRegistry.hushyCleanup2BIntentSealed))
        let fourB = try #require(ModelRegistry.entry(id: ModelRegistry.hushyCleanup4BSealed))
        #expect(rig.controller.selectedEntry.id == fourB.id)
        #expect(rig.controller.recommendedEntry.id == fourB.id)
        rig.downloads.start()
        await settle()
        #expect(rig.fetch.requested == [twoB.asset.id], "only the sealed 2B moves first")
        #expect(desk.fetched == [twoB.id], "its key was asked for before its files")
        rig.fetch.release()
        await settle()
        #expect(rig.controller.effective == .local(twoB.id))
        #expect(desk.fetched == [twoB.id, fourB.id])
        rig.fetch.release()
        await settle()
        #expect(rig.controller.effective == .local(fourB.id))
        #expect(try await answer(rig.controller.backend) == #"{"text":"local:\#(fourB.id)"}"#)
        #expect(rig.settings.localCleanupModelID == nil)
    }

    @Test("an install with the plain 4B moves to the sealed 4B through the normal handover, and the plain files go last")
    func sealedHandoverFromPlain() async throws {
        let desk = KeyDesk()
        let rig = rig(choice: .local, holds: true, machine: pro24, useIntentModels: true,
                      alsoInstalled: [ModelRegistry.hushyCleanup4B], useSealedModels: true,
                      keys: ModelKeyProvider(store: InMemoryModelKeyStore(), fetcher: desk), sealedOpens: { _, _ in true })
        let plain = try #require(ModelRegistry.entry(id: ModelRegistry.hushyCleanup4B))
        let sealed = try #require(ModelRegistry.entry(id: ModelRegistry.hushyCleanup4BSealed))
        let plainDirectory = rig.controller.directory(for: plain)
        rig.downloads.start()
        await settle()
        #expect(rig.controller.selectedEntry.id == sealed.id)
        #expect(rig.controller.effective == .local(plain.id), "the plain 4B answers while the sealed one downloads")
        #expect(try await answer(rig.controller.backend) == #"{"text":"local:\#(plain.id)"}"#)
        #expect(FileManager.default.fileExists(atPath: plainDirectory.path))
        #expect(rig.fetch.requested == [sealed.asset.id])
        rig.fetch.release()
        await settle()
        #expect(rig.controller.effective == .local(sealed.id))
        #expect(!FileManager.default.fileExists(atPath: plainDirectory.path), "the plain files are deleted after the switch")
        #expect(desk.fetched == [sealed.id])
        #expect(rig.settings.localCleanupModelID == nil)
    }

    @Test("a sealed model whose key does not open the files never replaces the plain one")
    func sealedHandoverKeyDoesNotOpen() async throws {
        let rig = rig(choice: .local, holds: true, machine: pro24, useIntentModels: true,
                      alsoInstalled: [ModelRegistry.hushyCleanup4B], useSealedModels: true,
                      keys: ModelKeyProvider(store: InMemoryModelKeyStore(), fetcher: KeyDesk()), sealedOpens: { _, _ in false })
        let plain = try #require(ModelRegistry.entry(id: ModelRegistry.hushyCleanup4B))
        let plainDirectory = rig.controller.directory(for: plain)
        rig.downloads.start()
        await settle()
        rig.fetch.release()
        await settle()
        #expect(rig.controller.effective == .local(plain.id))
        #expect(FileManager.default.fileExists(atPath: plainDirectory.path))
        #expect(rig.controller.install == .failed("Some model files are damaged."))
    }

    @Test("no key from the host: the sealed files are not downloaded at all, and the plain model keeps answering")
    func sealedKeyUnavailableBeforeDownload() async throws {
        let desk = KeyDesk()
        desk.fails = true
        let rig = rig(choice: .local, machine: pro24, useIntentModels: true, alsoInstalled: [ModelRegistry.hushyCleanup4B],
                      useSealedModels: true, keys: ModelKeyProvider(store: InMemoryModelKeyStore(), fetcher: desk))
        let plain = try #require(ModelRegistry.entry(id: ModelRegistry.hushyCleanup4B))
        let sealed = try #require(ModelRegistry.entry(id: ModelRegistry.hushyCleanup4BSealed))
        rig.downloads.start()
        await settle()
        #expect(rig.fetch.requested.isEmpty, "the key came first and failed; no file was fetched")
        #expect(desk.count >= 1)
        #expect(rig.controller.effective == .local(plain.id))
        #expect(FileManager.default.fileExists(atPath: rig.controller.directory(for: plain).path))
        _ = sealed
    }

    @Test("a sealed model on disk whose key is missing or wrong is reported, the stand-in answers, and it recovers when the key is right")
    func sealedKeyIssueState() async throws {
        let store = InMemoryModelKeyStore()
        let keys = ModelKeyProvider(store: store, fetcher: nil)
        let rig = rig(choice: .local, machine: pro24, useIntentModels: true,
                      alsoInstalled: [ModelRegistry.hushyCleanup2BIntentSealed, ModelRegistry.hushyCleanup4BSealed],
                      useSealedModels: true, keys: keys, sealedOpens: { _, _ in true })
        let sealed = try #require(ModelRegistry.entry(id: ModelRegistry.hushyCleanup4BSealed))
        let twoB = try #require(ModelRegistry.entry(id: ModelRegistry.hushyCleanup2BIntentSealed))
        rig.downloads.start()
        await settle()
        #expect(rig.controller.effective == .local(sealed.id))
        #expect(rig.controller.keyIssue == nil)

        keys.report(modelID: sealed.id, issue: .mismatch)
        await settle()
        #expect(rig.controller.keyIssue == .mismatch)
        #expect(rig.controller.install == .failed(ModelKeyIssue.mismatch.summary))
        #expect(rig.controller.effective == .local(twoB.id), "the installed sealed 2B answers meanwhile")
        #expect(rig.controller.activeBackendDescription.contains("cannot open"))

        keys.report(modelID: sealed.id, issue: nil)
        await settle()
        #expect(rig.controller.keyIssue == nil)
        #expect(rig.controller.install == .ready)
        #expect(rig.controller.effective == .local(sealed.id))
    }

    @Test("with sealed delivery off (today's default) nothing sealed is asked for, and plain installs are untouched")
    func sealedOffChangesNothing() async throws {
        let desk = KeyDesk()
        let rig = rig(choice: .local, holds: true, machine: pro24, useIntentModels: true,
                      alsoInstalled: [ModelRegistry.hushyCleanup4B], useSealedModels: false,
                      keys: ModelKeyProvider(store: InMemoryModelKeyStore(), fetcher: desk))
        rig.downloads.start()
        await settle()
        #expect(rig.controller.selectedEntry.id == ModelRegistry.hushyCleanup4B)
        #expect(rig.controller.effective == .local(ModelRegistry.hushyCleanup4B))
        #expect(rig.fetch.requested.isEmpty)
        #expect(desk.count == 0)
        #expect(!ModelTierPolicy.sealedModelsAreDefault, "the roll-out switch is flipped by hand, last")
    }
}
