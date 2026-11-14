import Foundation
import MurmurCore
import Observation
import os

/// Builds the local-model chain. The app passes `LocalCleanupBackend` (MLX); tests pass a fake,
/// so the settings state machine runs without weights, Metal or a network.
struct LocalBackendFactory {
    struct Built {
        let model: any LanguageModel
        let residency: LocalModelResidency
        /// The local model's memory, for `ModelWarmthKeeper` (nil in tests).
        var memory: (any ResidentModelMemory)?
    }

    /// Whether this process can run a local model at all (`mlx.metallib` is bundled).
    var isRuntimeAvailable: () -> Bool
    var make: (_ entry: LocalModelEntry, _ directory: URL, _ fallback: any LanguageModel,
               _ idleSeconds: TimeInterval?, _ log: ModelCallLog, _ keys: (any SealedKeySource)?) -> Built
}

/// Settings → Writing → "Cleanup model" (M5/M6): which backend dictation cleanup runs on, the
/// local model's download (through `DownloadCoordinator`'s queue), and the switch — done in
/// place on the `SwitchableLanguageModel` the dictation `SmartCleaner` holds, so nothing
/// restarts. Choosing a local model that is not downloaded yet keeps an installed one that fits this
/// Mac (the stand-in) answering, or the simple rule-based fixes when none is installed, never Apple
/// Intelligence (TRY-88); deleting the model reverts to Apple. See DECISIONS 2026-09-27 "MLX cleanup
/// model in the app".
@MainActor
@Observable
final class CleanupModelController {
    enum Verification: Equatable {
        case idle, checking
        case intact(files: Int)
        case damaged([String])
        case failed(String)
    }

    /// What cleanup runs on right now.
    private(set) var effective: EffectiveCleanupBackend
    /// The installed model answering while the selected one downloads (or is being checked), else nil.
    private(set) var standInEntry: LocalModelEntry?
    private(set) var verification: Verification = .idle
    /// Bumped whenever files on disk change, so `install` (read from disk) re-renders.
    private(set) var diskRevision = 0
    /// Set when "Verify" found a damaged file: the model is not used until repaired.
    private(set) var damagedEntryID: String?
    /// Why the selected sealed model cannot open (its key is not on this Mac, or does not match the files), or nil.
    /// While set, the model is reported as not ready and the installed stand-in, if any, keeps answering.
    private(set) var keyIssue: ModelKeyIssue?
    /// Whether the model answering now is sent register lines (Professional, Casual and Prompt as real rewrites). The
    /// tone page reads it to offer Prompt and to pick honest examples; dictation reads the backend's own flag.
    private(set) var writesRegisterLines = false

    /// The model `SmartCleaner` calls for dictation cleanup.
    @ObservationIgnored let backend: SwitchableLanguageModel
    @ObservationIgnored let callLog: ModelCallLog
    /// The model note and meeting summaries call (`LanguageModels.meeting`): the loaded local 4B when cleanup runs
    /// on it, Apple FM otherwise. It wraps `backend`, so there is never a second copy of the model.
    @ObservationIgnored let meeting: MeetingLanguageModel
    /// Whether a dictation is in progress; summaries wait for it between calls (`MeetingLanguageModel`).
    @ObservationIgnored let foreground: ForegroundActivity
    let machine: MachineProfile

    @ObservationIgnored private let settings: AppSettings
    @ObservationIgnored private let downloads: DownloadCoordinator
    @ObservationIgnored private let modelsRoot: URL
    @ObservationIgnored private let apple: any LanguageModel
    @ObservationIgnored private let factory: LocalBackendFactory
    @ObservationIgnored private let health: ModelHealth
    @ObservationIgnored private let useIntentModels: Bool
    /// Deliver the sealed twins of the Hushy-hosted models (`ModelTierPolicy.sealedModelsAreDefault`).
    @ObservationIgnored private let useSealedModels: Bool
    /// Keys of sealed models: the Keychain and the account-gated key route. Nil: sealed models cannot be opened.
    @ObservationIgnored let keys: ModelKeyProvider?
    /// Whether a sealed entry's key opens its downloaded files (default: `SealedModelOpener`, one chunk read).
    @ObservationIgnored private let opensSealed: @Sendable (LocalModelEntry, URL) async -> Bool
    @ObservationIgnored private let verifyDownloaded: @Sendable (LocalModelEntry, URL) throws -> Bool
    @ObservationIgnored private var handoverEntry: LocalModelEntry?
    @ObservationIgnored private var residency: LocalModelResidency?
    /// The local model's pages, while a local model is the backend (`PredictiveWarmer`).
    @ObservationIgnored private(set) var residentMemory: (any ResidentModelMemory)?
    @ObservationIgnored private let log = Logger(subsystem: "app.hushy", category: "cleanup-model")
    /// Called after a switch so the new backend can load before the next dictation.
    @ObservationIgnored var onSwitched: ((EffectiveCleanupBackend) -> Void)?
    /// The sign-in gate's session, used for a model download when the Keychain holds none.
    @ObservationIgnored var currentAccountSession: (() -> AccountSession?)?

    private func gateSession() -> AccountSession? { currentAccountSession?() }

    /// Lets the key client (built before `self` is complete) reach the sign-in gate's in-memory session.
    private final class SessionRelay: @unchecked Sendable {
        var fallback: (@Sendable () async -> AccountSession?)?
        func current() async -> AccountSession? { await fallback?() }
    }

    init(
        settings: AppSettings, downloads: DownloadCoordinator, apple: any LanguageModel, factory: LocalBackendFactory,
        machine: MachineProfile = .current(), modelsRoot: URL = AppPaths.supportDirectory,
        health: ModelHealth = .shared, callLog: ModelCallLog = ModelCallLog(),
        foreground: ForegroundActivity = ForegroundActivity(),
        fetch: (@Sendable (DownloadableAsset, @escaping @Sendable (Int64) -> Void) async throws -> Void)? = nil,
        useIntentModels: Bool = ModelTierPolicy.intentModelsAreDefault,
        useSealedModels: Bool = ModelTierPolicy.sealedModelsAreDefault,
        keys: ModelKeyProvider? = nil,
        keyStore: (any ModelKeyStoring)? = nil,
        sealedOpens: (@Sendable (LocalModelEntry, URL) async -> Bool)? = nil,
        verifyDownloaded: @escaping @Sendable (LocalModelEntry, URL) throws -> Bool = {
            try ManagedAssetInstaller.verify($0.files, in: $1).isClean
        }
    ) {
        self.settings = settings
        self.downloads = downloads
        self.apple = apple
        self.factory = factory
        self.machine = machine
        self.modelsRoot = modelsRoot
        self.health = health
        self.useIntentModels = useIntentModels
        self.useSealedModels = useSealedModels
        // Keys: given (tests), or the Keychain with the key route behind the account's token (the app).
        let relay = SessionRelay()
        let resolvedKeys = keys ?? keyStore.map {
            ModelKeyProvider(store: $0, fetcher: ModelKeyClient(authorizer: AccountDownloadAuthorizer(fallback: { await relay.current() })))
        }
        self.keys = resolvedKeys
        self.opensSealed = sealedOpens ?? { [keys = resolvedKeys] entry, directory in
            guard let keys else { return false }
            do {
                _ = try await SealedModelOpener.open(directory: directory, modelID: entry.id, keys: keys)
                return true
            } catch {
                return false
            }
        }
        self.verifyDownloaded = verifyDownloaded
        self.callLog = callLog
        let old = ModelTierPolicy.recommended(for: machine, useIntentModels: false, sealed: false)
        let new = ModelTierPolicy.recommended(for: machine, useIntentModels: useIntentModels,
                                              prefer2B: settings.preferIntentCleanup2B, sealed: useSealedModels)
        if useIntentModels, settings.localCleanupModelID == nil, old.id != new.id,
           ManagedAssetInstaller.isInstalled(old.files, in: ModelRegistry.directory(for: old, root: modelsRoot)) {
            handoverEntry = old
        }
        backend = SwitchableLanguageModel(RecordingLanguageModel(apple, label: "apple", log: callLog))
        self.foreground = foreground
        meeting = MeetingLanguageModel(shared: backend, apple: apple, activity: foreground)
        effective = .apple
        let fetchFiles = fetch ?? Self.fetcher(
            root: modelsRoot, authorizer: AccountDownloadAuthorizer(fallback: { [weak self] in await self?.gateSession() }))
        let keyHolder = self.keys
        downloads.fetchManagedAsset = { asset, progress in
            // A sealed model's key first: gigabytes are not downloaded for a model that could not be opened.
            if let id = LocalModelEntry.entryID(forAssetID: asset.id), ModelRegistry.entry(id: id)?.sealing != nil, let keyHolder {
                try await keyHolder.ensure(modelID: id)
            }
            try await fetchFiles(asset, progress)
        }
        relay.fallback = { [weak self] in await self?.gateSession() }
        self.keys?.onIssueChange = { [weak self] _, _ in Task { @MainActor in self?.refreshKeyIssue() } }
        let previous = downloads.onAssetReady
        downloads.onAssetReady = { [weak self] id in
            previous?(id)
            self?.assetReady(id)
        }
        if useSealedModels, handoverEntry == nil, intentOverrideDirectory == nil,
           let plain = ModelRegistry.plainTwin(of: selectedEntry),
           ManagedAssetInstaller.isInstalled(plain.files, in: ModelRegistry.directory(for: plain, root: modelsRoot)),
           !ManagedAssetInstaller.isInstalled(selectedEntry.files, in: ModelRegistry.directory(for: selectedEntry, root: modelsRoot)) {
            // An install from before sealed models: the plain files answer while the sealed ones download.
            handoverEntry = plain
        }
        apply(why: "launch")
        // A download the user started last session picks up where it stopped.
        if settings.cleanupBackend == .local, !install.isReady, damagedEntryID == nil, intentOverrideDirectory == nil {
            requestSelectedDownload()
        }
        if handoverEntry != nil, install.isReady { verifyHandover() }
    }

    // MARK: What Settings shows

    var choice: CleanupBackendChoice { settings.cleanupBackend }
    /// The 4B on 24 GB+ Pro/Max Macs, the 2B intent model elsewhere; `preferIntentCleanup2B` is the way back to the 2B.
    var recommendedEntry: LocalModelEntry {
        ModelTierPolicy.recommended(
            for: machine, useIntentModels: useIntentModels, prefer2B: settings.preferIntentCleanup2B, sealed: useSealedModels)
    }

    var selectedEntry: LocalModelEntry {
        if intent2BOverrideDirectory != nil, qualifiesFor2BIntent,
           let intent = delivered(ModelRegistry.hushyCleanup2BIntent) { return intent }
        if settings.useIntentCleanup4B || intent4BOverrideDirectory != nil {
            if settings.preferIntentCleanup2B, intent4BOverrideDirectory == nil, qualifiesFor2BIntent,
               let intent = delivered(ModelRegistry.hushyCleanup2BIntent) { return intent }
            if let intent = ModelTierPolicy.intentEntry(for: machine, sealed: useSealedModels) { return intent }
        }
        return settings.localCleanupModelID.flatMap(delivered(_:)) ?? recommendedEntry
    }

    /// The registry entry that delivers model `id` here: its sealed twin when sealed delivery is on.
    private func delivered(_ id: String) -> LocalModelEntry? {
        ModelRegistry.entry(id: id).map { ModelRegistry.delivered($0, sealed: useSealedModels) }
    }

    private var qualifiesFor2BIntent: Bool {
        ModelTierPolicy.qualifiesFor2BIntent(machine)
    }

    func fit(_ entry: LocalModelEntry) -> ModelTierPolicy.Fit {
        ModelTierPolicy.fit(entry, on: machine, prefer2B: settings.preferIntentCleanup2B)
    }

    private func overrideDirectory(_ key: String) -> URL? {
        guard let path = ProcessInfo.processInfo.environment[key], !path.isEmpty else { return nil }
        return URL(fileURLWithPath: path, isDirectory: true)
    }

    private var intent4BOverrideDirectory: URL? { overrideDirectory("HUSHY_CLEANUP_4B_DIR") }
    private var intent2BOverrideDirectory: URL? { overrideDirectory("HUSHY_CLEANUP_2B_INTENT_DIR") }
    private var intentOverrideDirectory: URL? {
        switch selectedEntry.logicalID {
        case ModelRegistry.hushyCleanup4B: intent4BOverrideDirectory
        case ModelRegistry.hushyCleanup2BIntent: intent2BOverrideDirectory
        default: nil
        }
    }

    func directory(for entry: LocalModelEntry) -> URL {
        if entry.logicalID == ModelRegistry.hushyCleanup4B, let intent4BOverrideDirectory { return intent4BOverrideDirectory }
        if entry.logicalID == ModelRegistry.hushyCleanup2BIntent, let intent2BOverrideDirectory { return intent2BOverrideDirectory }
        return ModelRegistry.directory(for: entry, root: modelsRoot)
    }

    /// The selected model's state, from the queue and the disk.
    var install: LocalModelInstall {
        _ = diskRevision
        if let pinnedInstall { return pinnedInstall }
        let entry = selectedEntry
        if entry.promptProfile == .intent, intentOverrideDirectory != nil {
            let directory = directory(for: entry)
            let config = directory.appendingPathComponent("config.json").path
            let weights = (try? FileManager.default.contentsOfDirectory(atPath: directory.path))?
                .contains(where: { $0.hasSuffix(".safetensors") }) == true
            return FileManager.default.fileExists(atPath: config) && weights ? .ready : .notInstalled
        }
        if damagedEntryID == entry.id { return .failed("Some model files are damaged.") }
        if entry.sealing != nil, let keyIssue, !isDownloading(entry),
           ManagedAssetInstaller.isInstalled(entry.files, in: directory(for: entry)) {
            return .failed(keyIssue.summary)
        }
        return queueInstall(of: entry)
    }

    private func isDownloading(_ entry: LocalModelEntry) -> Bool {
        let state = downloads.queue[entry.asset.id]?.state
        return state == .downloading || state == .queued
    }

    /// An entry's state from the download queue and the disk.
    private func queueInstall(of entry: LocalModelEntry) -> LocalModelInstall {
        let id = entry.asset.id
        let total = entry.downloadBytes
        if let queued = downloads.queue[id] {
            switch queued.state {
            case .downloading:
                return .downloading(received: queued.receivedBytes, total: total, secondsRemaining: downloads.secondsRemaining(for: id))
            case .queued:
                return .downloading(received: queued.receivedBytes, total: total, secondsRemaining: nil)
            case .paused:
                return .paused(received: queued.receivedBytes, total: total, reason: pauseReason(id))
            case .failed(let message):
                return .failed(message)
            case .ready, .offered:
                break
            }
        }
        return ManagedAssetInstaller.isInstalled(entry.files, in: directory(for: entry)) ? .ready : .notInstalled
    }

    private func pauseReason(_ id: String) -> LocalModelInstall.PauseReason {
        if downloads.userPaused.contains(id) { return .user }
        if downloads.signInPaused.contains(id) { return .signedOut }
        if downloads.limitPaused.contains(id) { return .downloadLimit }
        return downloads.meteredPaused.contains(id) ? .meteredNetwork : .offline
    }

    /// What the pill's waiting note follows: the 2B being fetched first on a fresh 24 GB+ Pro/Max install
    /// (the model that is about to answer), else the selected model.
    private var waitingInstall: LocalModelInstall {
        if pinnedInstall == nil, let first = firstDownloadStandIn { return queueInstall(of: first) }
        return install
    }

    var isSuspendedForMemory: Bool { residency?.isSuspended ?? false }
    var residencyStats: LocalModelResidency.Stats? { residency?.stats }

    /// Whether the model behind cleanup can be called now (the status note's "Tones still apply").
    var isModelAvailable: Bool { pinnedInstall != nil ? pinnedModelAvailable : backend.isAvailable }

    /// The last few cleanup calls (backend, outcome, latency — no text), oldest first.
    var recentCalls: [ModelCallLog.Entry] { pinnedCalls ?? callLog.recent }

    /// What polishes dictation right now, in plain words, for the status note (`PolishStatusNote`) and About. It
    /// stays truthful about the chain: the selected model is not necessarily the one that
    /// answered last (Hushy's own model can hand over to Apple Intelligence), so the sentence
    /// says what is set up and, separately, what the most recent cleanup actually used. It never
    /// claims the local model ran just because it is selected or installed. No model names,
    /// revisions or call counts: those are for logs, not for the person.
    var activeBackendDescription: String {
        let lastCall: String
        switch recentCalls.last(where: { $0.outcome == .answered })?.backend {
        case "local": lastCall = " The most recent cleanup used Hushy's own model."
        case "apple": lastCall = " The most recent cleanup used Apple Intelligence."
        default: lastCall = ""
        }
        switch effective {
        case .local:
            if isSuspendedForMemory {
                return "This Mac is low on memory, so \(Self.standIn(appleAvailable: isAppleAvailable)) for now. Hushy's own model takes over again by itself." + lastCall
            }
            if standInEntry != nil {
                return waitingSentence(
                    subject: "Hushy's new model", standIn: "the one already on this Mac polishes your dictation",
                    readyIs: "is downloaded and being checked") + lastCall
            }
            return "Hushy's own model polishes your dictation on this Mac. Apple Intelligence steps in when it cannot answer in time." + lastCall
        case .apple:
            let standIn = Self.standIn(appleAvailable: isAppleAvailable)
            guard settings.cleanupBackend == .local else {
                return (isAppleAvailable
                    ? "Apple Intelligence polishes your dictation on this Mac."
                    : "Apple Intelligence is not available on this Mac right now, so Hushy uses its simpler fixes (fillers, punctuation, capitals).") + lastCall
            }
            return waitingSentence(subject: Self.ownModel, standIn: standIn, readyIs: "cannot run on this Mac right now") + lastCall
        case .rules:
            guard settings.cleanupBackend == .local else {
                return "Simple fixes only (fillers, punctuation, capitals). No model rewrites your words."
            }
            return waitingSentence(
                subject: Self.ownModel, standIn: "Hushy uses its simpler fixes (fillers, punctuation, capitals)",
                readyIs: "cannot run on this Mac right now")
        }
    }

    private static let ownModel = "Hushy's own model"

    /// One sentence for a local model that is not answering yet: where it is, and what polishes meanwhile.
    private func waitingSentence(subject: String, standIn: String, readyIs: String) -> String {
        switch install {
        case .downloading: "\(subject) is still downloading. Until it is ready, \(standIn)."
        case .paused(_, _, .signedOut): "Sign in to download \(subject). Until then, \(standIn)."
        case .paused(_, _, .downloadLimit):
            "\(subject) has reached today's download limit and continues by itself later. Until then, \(standIn)."
        case .paused: "The download of \(subject) is paused. Until it finishes, \(standIn)."
        case .failed where keyIssue != nil: "\(subject) is downloaded but cannot open yet. \(keyIssue?.summary ?? "") Until it can, \(standIn)."
        case .failed: "\(subject) could not be downloaded, so \(standIn)."
        case .notInstalled: "\(subject) is not downloaded yet, so \(standIn)."
        case .ready: "\(subject) \(readyIs), so \(standIn)."
        }
    }

    /// The pill's note while no local model can answer and the simple fixes run instead: one short
    /// line, with a bar for the download's progress (`PillBanner.cleanupModelWaiting`). Nil when a model
    /// polishes, when the person chose Apple Intelligence or the simple fixes, or on a Mac that
    /// cannot run the local model.
    var waitingBanner: PillBanner? {
        guard effective == .rules, settings.cleanupBackend == .local else { return nil }
        let waiting = waitingInstall
        guard let line = Self.waitingLine(for: waiting) else { return nil }
        return .cleanupModelWaiting(line: line, progress: Self.waitingProgress(for: waiting))
    }

    static func waitingLine(for install: LocalModelInstall) -> String? {
        let downloading = "Getting faster — downloading the model"
        switch install {
        case .downloading, .notInstalled: return downloading
        case .paused(_, _, .signedOut): return "Sign in to download Hushy's writing model"
        case .paused(_, _, .downloadLimit): return "Hushy's model download continues later"
        case .paused: return "Hushy's model download is paused"
        case .failed: return "Hushy's model isn't ready"
        case .ready: return nil
        }
    }

    /// How far the download is, for the pill's bar (at most 0.99 until the files are in); nil without a size.
    static func waitingProgress(for install: LocalModelInstall) -> Double? {
        guard case .downloading(let received, let total, _) = install, total > 0 else { return nil }
        return min(0.99, Double(received) / Double(total))
    }

    /// Apple Intelligence itself, whatever cleanup is switched to (snapshots pin it either way).
    private var isAppleAvailable: Bool { pinnedInstall != nil ? pinnedModelAvailable : apple.isAvailable }

    /// What does the polishing while Hushy's own model cannot: Apple Intelligence where the Mac
    /// has it, otherwise the rule-based fixes.
    private static func standIn(appleAvailable: Bool) -> String {
        appleAvailable ? "Apple Intelligence polishes your dictation" : "Hushy uses its simpler fixes"
    }

    @ObservationIgnored private var pinnedInstall: LocalModelInstall?
    @ObservationIgnored private var pinnedCalls: [ModelCallLog.Entry]?
    @ObservationIgnored private var pinnedModelAvailable = true

    /// Snapshot rendering only: shows a state without downloading or loading anything.
    /// `modelAvailable: false` shows a Mac where nothing can polish (no Apple Intelligence).
    func pinForSnapshot(
        choice: CleanupBackendChoice, install: LocalModelInstall, effective: EffectiveCleanupBackend,
        calls: [ModelCallLog.Entry], verification: Verification = .idle, modelAvailable: Bool = true,
        registerLines: Bool = false
    ) {
        settings.cleanupBackend = choice
        writesRegisterLines = registerLines
        pinnedInstall = install
        pinnedCalls = calls
        pinnedModelAvailable = modelAvailable
        self.effective = effective
        self.verification = verification
        diskRevision += 1
    }

    // MARK: Actions

    func choose(_ choice: CleanupBackendChoice) {
        guard choice != settings.cleanupBackend else { return }
        let entry = selectedEntry
        settings.cleanupBackend = choice
        if choice == .local {
            if !install.isReady, damagedEntryID == nil, intentOverrideDirectory == nil { requestSelectedDownload() }
        } else if downloads.queue[entry.asset.id]?.state == .downloading || downloads.queue[entry.asset.id]?.state == .queued {
            // Leaving the local model mid-download: keep the bytes, stop spending bandwidth.
            downloads.pause(entry.asset.id)
            if let first = firstDownloadStandIn { downloads.pause(first.asset.id) }
        }
        apply(why: "setting-\(choice.rawValue)")
    }

    /// Picks another registry entry (override of the recommendation). The previous model's files
    /// are removed — two cleanup models would only waste disk.
    func selectModel(_ id: String) {
        guard let next = delivered(id), next.id != selectedEntry.id else { return }
        let previous = selectedEntry
        let first = firstDownloadStandIn
        handoverEntry = nil
        downloads.remove(previous.asset.id)
        // A pick other than the 2B ends the 2B-first plan; the 2B itself is still wanted.
        if let first, next.id != first.id { downloads.remove(first.asset.id) }
        if previous.promptProfile == .intent, next.logicalID != ModelRegistry.hushyCleanup4B {
            settings.useIntentCleanup4B = false
        }
        settings.localCleanupModelID = next.id == recommendedEntry.id ? nil : next.logicalID
        damagedEntryID = nil
        apply(why: "model-changed")
        removeFiles(of: previous)
        if settings.cleanupBackend == .local, !install.isReady, intentOverrideDirectory == nil { requestSelectedDownload() }
    }

    /// Deletes the model's files and reverts cleanup to Apple Intelligence.
    func deleteModel() {
        let entry = selectedEntry
        downloads.remove(entry.asset.id)
        if let first = firstDownloadStandIn { downloads.remove(first.asset.id) }
        damagedEntryID = nil
        verification = .idle
        if settings.cleanupBackend == .local { settings.cleanupBackend = .apple }
        apply(why: "model-deleted")
        removeFiles(of: entry)
    }

    /// Full SHA-256 check of the installed files, off the main actor.
    func verifyFiles() {
        let entry = selectedEntry
        let directory = directory(for: entry)
        verification = .checking
        Task { [weak self] in
            let result: Verification = await Task.detached(priority: .utility) {
                do {
                    let report = try ManagedAssetInstaller.verify(entry.files, in: directory)
                    return report.isClean ? .intact(files: report.verified) : .damaged(report.mismatches.map(\.path))
                } catch {
                    return .failed(error.localizedDescription)
                }
            }.value
            self?.finishVerification(result, entry: entry)
        }
    }

    func memoryPressure(_ level: MemoryPressureLevel) {
        guard let residency else { return }
        if level != .warning { log.notice("memory pressure=\(level.rawValue, privacy: .public) backend=\(self.effective.logLabel, privacy: .public)") }
        residency.memoryPressure(level)
    }

    // MARK: Switching

    /// Recomputes the backend from the setting and the disk, and swaps it in if it changed.
    func apply(why: String, force: Bool = false) {
        let covering = installedStandIn()
        let entry = covering ?? selectedEntry
        let next = EffectiveCleanupBackend.resolve(
            choice: settings.cleanupBackend, install: covering == nil ? install : .ready,
            entryID: entry.id, localAvailable: factory.isRuntimeAvailable())
        guard force || next != effective || why == "launch" else { return }
        let previous = residency
        residency = nil
        residentMemory = nil
        switch next {
        case .apple:
            backend.replace(with: RecordingLanguageModel(apple, label: "apple", log: callLog))
        case .rules:
            backend.replace(with: NullLanguageModel())
        case .local:
            let built = factory.make(
                entry, directory(for: entry), apple, ModelTierPolicy.idleUnloadSeconds(for: machine), callLog, keys)
            residency = built.residency
            residentMemory = built.memory
            backend.replace(with: built.model)
        }
        if case .local = next {
            backend.usesWholeTranscript = entry.promptProfile == .intent
            backend.understandsRegisterLines = entry.promptProfile == .intent && entry.understandsRegisterLines
        } else {
            backend.usesWholeTranscript = false
            backend.understandsRegisterLines = false
        }
        writesRegisterLines = backend.understandsRegisterLines
        if let previous { Task { await previous.unload(.manual) } }
        // One backend's speed says nothing about another's.
        health.reset()
        ModelPace.reset()
        callLog.clear()
        let from = effective
        effective = next
        meeting.route(for: next)
        standInEntry = if case .local = next { covering } else { nil }
        log.notice("cleanup backend=\(next.logLabel, privacy: .public) from=\(from.logLabel, privacy: .public) why=\(why, privacy: .public)")
        if why != "launch" { onSwitched?(next) }
    }

    /// The model that answers while the selected one is not ready: the old recommendation being handed
    /// over from (`handoverEntry`), else an installed model that fits this Mac (the recommended one or
    /// the 2B intent model, which answers while the 4B downloads on a 24 GB+ Pro/Max Mac). Its files are never removed here: the person may switch back to it.
    private func installedStandIn() -> LocalModelEntry? {
        if let handoverEntry { return handoverEntry }
        guard !install.isReady else { return nil }
        let selected = selectedEntry
        // The 2B intent model comes before the old 2B: on a 24 GB+ Pro/Max Mac it is what the person had
        // installed before the 4B became the default, and it answers while the 4B downloads.
        let candidates = [recommendedEntry, ModelTierPolicy.defaultIntentEntry(for: machine, sealed: useSealedModels),
                          ModelTierPolicy.defaultIntentEntry(for: machine, prefer2B: true, sealed: useSealedModels),
                          ModelTierPolicy.recommended(for: machine, useIntentModels: false, sealed: false)].compactMap { $0 }
            // A model installed before sealed delivery is the plain twin of a sealed candidate.
            .flatMap { [$0, ModelRegistry.plainTwin(of: $0)].compactMap { $0 } }
        return candidates.first {
            $0.id != selected.id && $0.minimumMemoryGB <= machine.physicalMemoryGB
                && ManagedAssetInstaller.isInstalled($0.files, in: directory(for: $0))
        }
    }

    /// The 2B intent model to fetch before the default 4B, on a fresh install: the 4B is the default (a 24 GB+
    /// Pro/Max Mac), neither it nor any other model that fits is installed, and nothing was picked by hand. The 2B
    /// is about 1 GB, so cleanup is polished within minutes while the several-GB 4B downloads behind it. Nil
    /// once any stand-in is installed (an existing user's 2B or the earlier 2B), and for every other Mac.
    private var firstDownloadStandIn: LocalModelEntry? {
        guard useIntentModels, handoverEntry == nil, damagedEntryID == nil, intentOverrideDirectory == nil,
              settings.localCleanupModelID == nil, !settings.preferIntentCleanup2B,
              selectedEntry.logicalID == ModelRegistry.hushyCleanup4B, recommendedEntry.logicalID == ModelRegistry.hushyCleanup4B,
              !install.isReady, qualifiesFor2BIntent,
              let twoB = delivered(ModelRegistry.hushyCleanup2BIntent),
              installedStandIn() == nil else { return nil }
        return twoB
    }

    /// Queues the selected model's download, the 2B first when it is to answer meanwhile. `DownloadCoordinator`
    /// runs one asset at a time (`activeAssetID`), in the order they were accepted, so the 4B waits for the 2B.
    private func requestSelectedDownload() {
        if let first = firstDownloadStandIn { downloads.accept(first.asset) }
        downloads.accept(selectedEntry.asset)
    }

    private func assetReady(_ assetID: String) {
        if assetID != selectedEntry.asset.id, assetID == delivered(ModelRegistry.hushyCleanup2BIntent)?.asset.id,
           installedStandIn()?.asset.id == assetID {
            // The 2B arrived first (the downloader hashes every file before moving it into place): it answers now.
            diskRevision += 1
            log.notice("stand-in cleanup model downloaded id=\(assetID, privacy: .public)")
            apply(why: "stand-in-ready")
            return
        }
        guard assetID == selectedEntry.asset.id else { return }
        diskRevision += 1
        log.notice("cleanup model downloaded id=\(self.selectedEntry.id, privacy: .public)")
        if handoverEntry != nil { verifyHandover(); return }
        let entry = selectedEntry
        guard entry.sealing != nil else { apply(why: "download-ready"); return }
        // A sealed model is ready only once its key opens the files.
        let directory = directory(for: entry)
        Task { [weak self] in
            guard let opens = await self?.sealedOpens(entry, directory), let self, self.selectedEntry.id == entry.id else { return }
            self.refreshKeyIssue()
            if opens { self.apply(why: "download-ready") }
        }
    }

    /// Whether a sealed entry's key (stored, or fetched now) opens its downloaded files; true for a plain entry.
    /// Reads one chunk; nothing is written. A mismatch asks the host for a fresh key once (`SealedModelOpener`).
    private func sealedOpens(_ entry: LocalModelEntry, _ directory: URL) async -> Bool {
        guard entry.sealing != nil else { return true }
        let opens = opensSealed
        return await Task.detached(priority: .utility) { await opens(entry, directory) }.value
    }

    /// Re-reads the selected sealed model's key state, and swaps the backend when it changed (a model whose key
    /// is missing or wrong is not ready; the stand-in answers until it is).
    func refreshKeyIssue() {
        let next = selectedEntry.sealing == nil ? nil : keys?.issue(for: selectedEntry.id)
        guard next != keyIssue else { return }
        keyIssue = next
        diskRevision += 1
        log.notice("model key issue=\(next == nil ? "none" : "present", privacy: .public) id=\(self.selectedEntry.id, privacy: .public)")
        apply(why: "key-state")
    }

    /// The person signed in: a sealed model whose key was waiting for an account gets it now.
    func accountSignedIn() {
        let entry = selectedEntry
        guard entry.sealing != nil, let keys, !keys.hasStoredKey(modelID: entry.id),
              ManagedAssetInstaller.isInstalled(entry.files, in: directory(for: entry)) else { return }
        Task { [weak self] in
            try? await keys.ensure(modelID: entry.id)
            self?.refreshKeyIssue()
        }
    }

    private func verifyHandover() {
        guard let old = handoverEntry else { return }
        let entry = selectedEntry
        let directory = directory(for: entry)
        let verify = verifyDownloaded
        Task { [weak self] in
            var clean = await Task.detached(priority: .utility) {
                (try? verify(entry, directory)) == true
            }.value
            // A sealed model replaces the plain one only once its key opens the files; until then the plain one answers.
            if clean, let self { clean = await self.sealedOpens(entry, directory) }
            guard let self, self.handoverEntry?.id == old.id, self.selectedEntry.id == entry.id else { return }
            self.refreshKeyIssue()
            if clean {
                self.handoverEntry = nil
                self.apply(why: "recommendation-ready")
                self.removeFiles(of: old)
            } else {
                self.damagedEntryID = entry.id
                self.log.error("recommended cleanup model failed verification id=\(entry.id, privacy: .public)")
            }
        }
    }

    private func finishVerification(_ result: Verification, entry: LocalModelEntry) {
        verification = result
        switch result {
        case .damaged(let paths):
            log.error("cleanup model damaged id=\(entry.id, privacy: .public) files=\(paths.count, privacy: .public)")
            damagedEntryID = entry.id
            apply(why: "files-damaged")
        case .intact(let files):
            log.notice("cleanup model verified id=\(entry.id, privacy: .public) files=\(files, privacy: .public)")
        case .idle, .checking, .failed:
            break
        }
    }

    private func removeFiles(of entry: LocalModelEntry) {
        do {
            try ManagedAssetInstaller.remove(directory(for: entry))
        } catch {
            log.error("removing cleanup model failed id=\(entry.id, privacy: .public): \(error.localizedDescription, privacy: .public)")
        }
        diskRevision += 1
    }

    /// `ManagedAssetInstaller` over the real network, into `<root>/Models/<id>/`. Requests to Hushy's
    /// model host carry the signed-in account's token (`AuthorizedDownloadTransport`); others carry none.
    private static func fetcher(
        root: URL, authorizer: any DownloadAuthorizing
    ) -> @Sendable (DownloadableAsset, @escaping @Sendable (Int64) -> Void) async throws -> Void {
        { asset, progress in
            guard case .files(let files) = asset.source,
                  let id = LocalModelEntry.entryID(forAssetID: asset.id), let entry = ModelRegistry.entry(id: id) else { return }
            let transport = AuthorizedDownloadTransport(base: URLSessionDownloadTransport(), authorizer: authorizer)
            let installer = ManagedAssetInstaller(downloader: AssetDownloader(transport: transport))
            try await installer.install(files, into: ModelRegistry.directory(for: entry, root: root), onProgress: progress)
        }
    }
}
