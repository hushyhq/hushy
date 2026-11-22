import AppKit
import MurmurCore
import Observation
import os

/// Composition root: builds the services, wires them together, and holds navigation state.
/// Data lives in `Library`, the pill window in `PillCoordinator`, settings propagation in
/// `SettingsSync`; this type only connects them.
@MainActor
@Observable
final class AppModel {
    /// Settings is its own macOS Settings window/scene (see `MurmurApp`'s `Settings { }` scene
    /// and `SettingsView`), not a section of the main window — so it isn't listed here.
    enum Section: String, CaseIterable, Identifiable {
        case home, history, notes, insights, style, ai

        var id: String { rawValue }

        var title: String {
            switch self {
            case .home: "Home"
            case .history: "History"
            case .notes: "Meetings"
            case .insights: "Insights"
            case .style: "Voice & style"
            case .ai: "AI connections"
            }
        }

        var symbol: String {
            switch self {
            case .home: "house"
            case .history: "clock.arrow.circlepath"
            case .notes: "waveform.badge.mic"
            case .insights: "chart.bar.xaxis"
            case .style: "textformat"
            case .ai: "sparkles"
            }
        }

        /// The sections a person can reach in this build. Notes holds recordings and meetings, so
        /// release builds have no Notes section (`FeatureFlags.meetings`).
        static func available(meetings: Bool = FeatureFlags.meetings) -> [Section] {
            allCases.filter { $0 != .notes || meetings }
        }
    }

    // Navigation
    var section: Section = .home {
        didSet {
            // Anything that still asks for Notes (a saved note's link, a dropped file) lands on Home.
            if section == .notes, !FeatureFlags.meetings { section = .home; return }
            appLock.recordActivity()
            // Entering or leaving History both count as "seen": leaving also covers anything
            // that failed while History was already on screen.
            if section == .history || oldValue == .history { settings.historySeenAt = Date() }
        }
    }
    var selectedNoteID: Int64?
    var showOnboarding: Bool
    @ObservationIgnored private let snapshotDefaultsSuiteName: String?

    // Shared state
    let settings: AppSettings
    let library: Library
    /// "Remember this voice" consent and confirm-time voice updates for speaker labels.
    @ObservationIgnored lazy var speakerVoices = SpeakerVoiceController(store: library.store, encryption: encryption)
    /// "What day is it" for every screen that shows today's figures; see `DayClock.system()`.
    let dayClock = DayClock.system()
    /// Learn-from-corrections surfaces (History suggestion, Voice & style list, Today notice).
    let learned: LearnedReview
    let permissions = Permissions()
    /// With this Mac's earlier load times, so Home can say how long getting ready usually takes.
    let modelStatus = SpeechModelStatus(loadTimes: .standard)
    /// Every model download (required speech model at launch, optional assets after it).
    let downloads: DownloadCoordinator
    /// Which backend dictation cleanup runs on (Apple FM / local MLX model / rules) and the local
    /// model's download, switch and diagnostics (Settings → Writing → Cleanup model).
    let cleanupModel: CleanupModelController
    let pill = PillModel()
    let encryption: EncryptionController
    let appLock: AppLockController
    /// Home's assistant chat: opt-in, saved to the local database (see `AssistantModel`).
    let handoff = TaskHandoffUIModel()
    let assistant: AssistantModel

    // Services
    @ObservationIgnored let speech: SpeechEngine
    @ObservationIgnored let sounds = Sounds()
    @ObservationIgnored let hotkeys = HotkeyMonitor()
    @ObservationIgnored let dictation: DictationController
    @ObservationIgnored let recorder: NoteRecorder
    /// The macOS calendar as notes read it; the Meetings setting asks it for access.
    @ObservationIgnored let calendarReader: EventKitCalendarReader
    /// The Meetings section: overview, page content, typed lines, consent and follow-ups.
    @ObservationIgnored lazy var meetings = MeetingsModel(
        store: library.store, settings: settings, calendar: calendarReader, reminders: EventKitActionBackend())
    /// A memo's page shown as Professional or Casual after the fact, on the cleanup model, never while a dictation or
    /// a recording is under way (`NoteRestyleModel`).
    @ObservationIgnored lazy var noteStyles = NoteRestyleModel(model: cleanupModel.backend) { [weak self] in
        guard let self else { return true }
        return self.dictation.isBusy || self.recorder.isRecording || self.recorder.isFinishing
    }
    /// The optional project folder for the "Coding" card (Settings -> Voice & style -> Coding).
    /// Owned here (not by `CodingSettingsCard`) so its scanned vocabulary reaches
    /// `dictation.projectVocabulary` regardless of whether the card's view is currently on
    /// screen — a dictation into a code editor should use the last scan even if the user never
    /// reopens Settings after their first scan completes.
    let codingProjectVocabulary = ProjectVocabularySettings()
    @ObservationIgnored let actionHotkeys = ActionHotkeyMonitor()
    /// The notice for another dictation app on Hushy's key. Started in `launch()`, never in a disposable run.
    @ObservationIgnored private var rivalKeys: RivalKeyCoordinator?
    /// The answer card's "Search Apple Notes?" offer goes through the same access check as the toggles.
    @ObservationIgnored let appleNotesSearch = AppleNotesToggle()
    @ObservationIgnored let voiceActions: VoiceActionsController
    @ObservationIgnored let importQueue: ImportQueue
    @ObservationIgnored private let pillCoordinator: PillCoordinator
    @ObservationIgnored private let settingsSync: SettingsSync
    @ObservationIgnored private var callDetection: CallDetectionCoordinator?
    /// Local-only first-run funnel (gate 11) — see `OnboardingFunnelRecorder`.
    @ObservationIgnored let funnel: OnboardingFunnelRecorder
    /// Usage numbers (counts and timings, never words): collection, the local queue and the
    /// inert-by-default uploader. See `UsageMetricsRecorder`.
    @ObservationIgnored let usageMetrics: UsageMetricsRecorder
    /// The once-a-day count of Macs (no identifier; its own switch, on by default). See `DailyCountSender`.
    @ObservationIgnored let dailyCount: DailyCountSender
    @ObservationIgnored let crashReporter: any CrashReporter
    @ObservationIgnored private let networkMonitor = NetworkPathMonitor()
    /// `.critical` memory pressure unloads the local cleanup model (M6).
    @ObservationIgnored private var memoryPressure: MemoryPressureMonitor?
    @ObservationIgnored private var wakeRewarmer: WakeRewarmer?
    @ObservationIgnored private var predictiveWarmer: PredictiveWarmer?
    /// The dictation hotkey handler, parked while onboarding's key practice is on screen.
    /// The dictation handlers the key lesson swapped out (`AppModel+KeyPractice`).
    @ObservationIgnored var practiceSavedHandlers: (event: ((HotkeyEvent) -> Void)?, timed: ((HotkeyEvent, Date) -> Void)?)?
    /// "Check for Updates…" — Sparkle when the build is configured, an explanation otherwise.
    /// Replaced in `launch()`; snapshot runs keep the inert default.
    @ObservationIgnored private(set) var updates: any UpdateChecker = UnconfiguredUpdateChecker()
    @ObservationIgnored private var updateCheckerStarted = false
    /// True while the sign-in gate has the app suspended; nothing may begin recording then.
    @ObservationIgnored private(set) var isBetaSuspended = false
    /// True from the moment "Uninstall Hushy…" starts stopping the app; quitting then saves
    /// nothing. Cleared only when the app would not stop and the uninstall was abandoned, or
    /// when a test run, which does not quit, has ended.
    @ObservationIgnored private(set) var isUninstalling = false
    /// Asked on ⌘Q once an uninstall has started (`UninstallFlow.handleAppQuit`). True when the
    /// uninstall will quit the app itself; false hands the quit back to the app.
    @ObservationIgnored var quitAfterUninstall: (() -> Bool)?
    /// True for snapshot rendering and `MURMUR_DEFAULTS_SUITE` runs: preferences live in a
    /// throwaway suite, so nothing here may touch the user's real defaults or Login Items.
    @ObservationIgnored let isDisposableRun: Bool
    /// The personal lexicon (names from use and domain packs); nil in a disposable run, which must not write the
    /// pack state file into the data folder.
    @ObservationIgnored private(set) var lexicon: LexiconCoordinator?
    func setLexicon(_ coordinator: LexiconCoordinator) { lexicon = coordinator }
    @ObservationIgnored var hotkeyRetry: Timer?
    @ObservationIgnored var permissionRecovery = PermissionRecoveryDecision()
    @ObservationIgnored var permissionRecoveryStarted = false
    @ObservationIgnored private var appLockIdleTimer: Timer?
    @ObservationIgnored private var appLockSleepObservers: [NSObjectProtocol] = []
    @ObservationIgnored let log = Logger(subsystem: "app.hushy", category: "app")
    /// Set by SwiftUI (which owns window creation) so non-view code can open the main window.
    @ObservationIgnored var openWindowHandler: (() -> Void)? {
        didSet { showPermissionRecoveryIfNeeded() }
    }
    /// Set by SwiftUI so non-view code can open the Settings window (see `openAccountSettings`).
    @ObservationIgnored var openSettingsHandler: (() -> Void)?

    var store: Store { library.store }

    /// The History sidebar badge: dictations since History was last opened that still hold
    /// recoverable words (never pasted, or failed with a transcript/audio to retry). Zero while
    /// History is on screen — the user is already looking at them. See `HistoryAttention`.
    var historyBadgeCount: Int {
        guard section != .history else { return 0 }
        return HistoryAttention.badgeCount(library.dictations, seenThrough: settings.historySeenAt)
    }

    /// True only after the old Murmur support folder was actually moved.
    var migratedFromMurmur: Bool {
        UserDefaults.standard.bool(forKey: AppDataMigration.supportDirectoryMigrationFlagKey)
    }

    init() {
        // Snapshot rendering must not persist its temporary sidebar layout into the user's
        // regular preferences.
        snapshotDefaultsSuiteName = Snapshots.requestedDirectory == nil
            ? nil : "app.hushy.snapshot.\(UUID().uuidString)"
        let snapshotDefaults = snapshotDefaultsSuiteName.flatMap(UserDefaults.init(suiteName:))
        // `MURMUR_DEFAULTS_SUITE=<name>` (with `MURMUR_HOME` pointing at a temp dir) runs the
        // app as a fresh install — onboarding and all — without touching the real preferences.
        // Used to time the first-run flow; see docs/guide/RELEASE.md and the Developer pane.
        let overrideSuite = snapshotDefaults == nil
            ? ProcessInfo.processInfo.environment["MURMUR_DEFAULTS_SUITE"].flatMap { $0.isEmpty ? nil : UserDefaults(suiteName: $0) }
            : nil
        isDisposableRun = snapshotDefaults != nil || overrideSuite != nil
        settings = AppSettings(defaults: snapshotDefaults ?? overrideSuite ?? .standard)
        library = Library(encryptsData: settings.encryptDataAtRest)
        pill.liveVariant = .load(from: snapshotDefaults ?? overrideSuite ?? .standard)
        // Snapshot rendering shows every page against a fresh, empty suite of defaults, which
        // would otherwise leave onboarding incomplete and dim every page behind its scrim.
        if snapshotDefaults != nil { settings.hasCompletedOnboarding = true }
        showOnboarding = !settings.hasCompletedOnboarding
        learned = LearnedReview(library: library)
        // A new day with nothing newly dictated still changes the streak and the day counts.
        dayClock.onDayChange = { [library, weak dayClock] in
            guard let dayClock else { return }
            library.refreshInsights(now: dayClock.now, calendar: dayClock.calendar)
        }
        encryption = EncryptionController(settings: settings)
        appLock = AppLockController(
            authenticator: LocalAuthenticationBridge(), isEnabled: settings.appLockEnabled,
            autoLockMinutes: settings.appLockAutoLockMinutes)
        speech = SpeechEngine(status: modelStatus)
        downloads = DownloadCoordinator(
            status: modelStatus, speech: SpeechEngineDownloads(engine: speech, settings: settings),
            requiredBytes: SpeechEngine.expectedDownloadBytes(for: settings.speechLanguageMode.modelVersion),
            notifier: snapshotDefaults == nil ? UserNotificationReadyNotifier() : SilentNotifier())
        cleanupModel = CleanupModelController(
            settings: settings, downloads: downloads, apple: LanguageModels.current, factory: .mlx,
            keyStore: snapshotDefaults == nil ? KeychainModelKeyStore() : nil)
        dictation = DictationController(
            speech: speech, modelStatus: modelStatus, store: library.store, settings: settings,
            pill: pill, sounds: sounds, hotkeys: hotkeys, encryption: encryption, cleanupModel: cleanupModel.backend,
            secondOpinion: LanguageModels.current, isAppLocked: { [appLock] in appLock.isLocked })
        recorder = NoteRecorder(
            speech: speech, modelStatus: modelStatus, store: library.store, settings: settings, pill: pill,
            encryption: encryption)
        let calendar = EventKitCalendarReader()
        calendarReader = calendar
        recorder.calendarNamer = NoteCalendarNamer(
            reader: calendar, store: library.store, isEnabled: { [settings] in settings.nameNotesFromCalendar })
        voiceActions = VoiceActionsController(
            hotkeys: actionHotkeys, pill: pill, speech: speech, modelStatus: modelStatus,
            store: library.store, calendarBackend: EventKitActionBackend(),
            shortcutsBackend: RealShortcutsActionBackend(), linkBackend: WorkspaceLinkBackend(),
            ownStuffSources: [StoreOwnStuffSource(store: library.store), EventKitOwnStuffSource()])
        voiceActions.optionalSource = AppleNotesOwnStuffSource()
        assistant = AssistantModel(settings: settings, store: library.store)
        funnel = OnboardingFunnelRecorder(settings: settings, modelStatus: modelStatus, permissions: permissions)
        // Disposable runs (snapshots, MURMUR_DEFAULTS_SUITE) get an inert recorder: no folder, no endpoint.
        let metrics = UsageMetricsRecorder(
            settings: settings,
            directory: isDisposableRun ? nil : AppPaths.supportDirectory.appendingPathComponent("UsageMetrics", isDirectory: true),
            endpoint: isDisposableRun ? nil : MetricsEndpoint.configured())
        usageMetrics = metrics
        dailyCount = DailyCountSender(
            store: isDisposableRun ? nil : DailyCountStore(url: AppPaths.supportDirectory.appendingPathComponent(DailyCountStore.fileName)),
            endpoint: isDisposableRun || !HushyServices.current.isOfficial ? nil : DailyCountEndpoint.url,
            build: DailyCountSender.bundleBuild(), gate: settings.dailyCountGate)
        // A build without the Hushy services (`HushyServices.none`, e.g. built from source) keeps no
        // crash queue and sends nothing to the Hushy site.
        crashReporter = MetricKitCrashReporter(
            settings: settings,
            directory: isDisposableRun || !HushyServices.current.isOfficial
                ? nil : AppPaths.supportDirectory.appendingPathComponent("CrashReports", isDirectory: true))
        funnel.onStepReached = { [weak metrics] event, date in metrics?.recordFunnel(event, at: date) }
        downloads.onSpeedMeasured = { [weak funnel] bucket in funnel?.recordSpeed(bucket) }
        let actions = voiceActions
        assistant.actionHandlers = AssistantActionHandlers(
            isEntitled: { actions.isEntitled() },
            execute: { await actions.executeConfirmed($0) },
            undo: { await actions.performUndo(recordID: $0) })
        let importStore = library.store
        let importSettings = settings
        let importEncryption = encryption
        let importLibrary = library
        let importSpeech = speech
        let importFinalizer = recorder.finalizer
        importQueue = ImportQueue { url in
            FileTranscriber(
                fileURL: url, speech: importSpeech, store: importStore, settings: importSettings,
                encryption: importEncryption,
                vocabulary: .from(dictionary: importLibrary.dictionary), finalizer: importFinalizer)
        }
        pillCoordinator = PillCoordinator(pill: pill)
        settingsSync = SettingsSync(
            settings: settings, hotkeys: hotkeys, sounds: sounds, pill: pill, store: library.store)
        dictation.metrics = Self.dictationMetricsHooks(metrics, cleanupModel, dailyCount)
        dictation.cleanupWaitNotice = { [cleanupModel] in cleanupModel.waitingBanner }
        dictation.onBusyChanged = { [foreground = cleanupModel.foreground] busy in foreground.set(busy: busy) }
        // Note and meeting summaries run on the cleanup model already in memory when it is the 4B (never a second copy).
        LanguageModels.meeting = cleanupModel.meeting
        voiceActions.onMetric = { [weak metrics] event in metrics?.record(.voiceAction(event)) }
        recorder.onMeetingMetric = { [weak metrics] event in metrics?.record(.meeting(event)) }
        dictation.canBeginRecording = { [weak self] in
            guard let self else { return false }
            return !self.isCaptureClosed && !self.recorder.isRecording && !self.recorder.isFinishing && !self.voiceActions.isActionInProgress
        }
        voiceActions.canBeginRecording = { [weak self] in
            guard let self else { return false }
            return !self.isCaptureClosed && !self.recorder.isRecording && !self.recorder.isFinishing && !self.dictation.isBusy
        }
        voiceActions.usesVoiceProcessing = { [weak self] in self?.settings.reduceBackgroundNoise ?? false }
        voiceActions.pickedMicrophone = { [weak self] in self?.settings.inputDeviceName }
        // Push the "Coding" card's scanned project vocabulary into the dictation hot path (see
        // `CodingSettingsCard`, `ProjectVocabularyScanner`). Set immediately in case a bookmarked
        // project resolved and scanned before this point; `dictation.projectVocabulary` is read
        // fresh at every key-down, so a later scan completing just updates it in place.
        codingProjectVocabulary.onVocabularyChange = { [weak dictation] vocabulary in
            dictation?.projectVocabulary = vocabulary
        }
        dictation.projectVocabulary = codingProjectVocabulary.vocabulary
        voiceActions.onHandoffProposed = { [weak self] proposal in
            self?.handoff.propose(proposal)
            self?.openWindowHandler?()
        }
    }

    /// What the dictation path reports through, for usage numbers (`DictationController+Metrics`).
    private static func dictationMetricsHooks(
        _ metrics: UsageMetricsRecorder, _ cleanup: CleanupModelController, _ dailyCount: DailyCountSender
    ) -> DictationMetricsHooks {
        DictationMetricsHooks(
            isCollecting: { [weak metrics] in metrics?.isCollecting ?? false },
            record: { [weak metrics] in metrics?.recordDictation($0) },
            hold: { [weak metrics] in metrics?.holdDictation($0) },
            resolve: { [weak metrics] in metrics?.resolveDictation($0, verdict: $1, coverage: $2, size: $3) },
            cleanupBackend: { [weak cleanup] in cleanup?.effective ?? .apple },
            modelState: { [weak cleanup] outcome, startedAt in
                guard let cleanup else { return nil }
                return MetricsModelState.infer(
                    outcome: outcome, answeredAt: cleanup.callLog.recent.filter { $0.outcome == .answered }.map(\.at),
                    callStartedAt: startedAt, idleUnloadSeconds: ModelTierPolicy.idleUnloadSeconds(for: cleanup.machine))
            },
            dictationDelivered: { [weak dailyCount] in dailyCount?.noteDeliveredDictation() })
    }

    /// Creates the update checker once. The app delegate calls it before the sign-in gate decides,
    /// so a build the gate locks out can still be replaced by a fixed one; `launch()` repeats it
    /// harmlessly.
    func startUpdateChecker() {
        guard !updateCheckerStarted else { return }
        updateCheckerStarted = true
        updates = SparkleUpdateChecker.make()
    }

    /// Called once the app has finished launching.
    func launch() {
        // A guard left set by an earlier suspension must not outlive the launch it preceded.
        isBetaSuspended = false
        startPermissionRecovery()
        pillCoordinator.unhide()
        let encryption = self.encryption
        AudioPlayer.resolveKey = { encryption.currentKey }
        startAppLockObserving()
        settingsSync.onLanguageChange = { [weak self] mode in
            guard let self else { return }
            Task { try? await self.speech.prepare(version: mode.modelVersion, driftGuard: mode.driftGuardEnabled) }
        }
        settingsSync.start()
        if !isDisposableRun { enableLaunchAtLoginOnce() }
        funnel.start()
        if !isDisposableRun {
            rivalKeys = RivalKeyCoordinator(settings: settings, presenter: RivalKeyPanelPresenter())
            rivalKeys?.start()
        }
        usageMetrics.start()
        crashReporter.start()
        if !isDisposableRun { handoff.resumeAtLaunch() }
        dictation.onDictationSucceeded = { [weak self] _ in self?.recordFirstDictation() }
        startUpdateChecker()
        // Dictations saved before the rename point into the old Murmur folder; repoint them.
        do {
            let fixed = try store.rebaseMediaPaths(from: AppPaths.previousSupportDirectory.path,
                                                   to: AppPaths.supportDirectory.path)
            if fixed > 0 { log.notice("repointed \(fixed) audio path(s) to the Hushy folder") }
        } catch {
            log.error("repointing audio paths failed: \(error.localizedDescription)")
        }
        if !isDisposableRun, let openError = library.storeError {
            DatabaseFailureAlert.show(openError)
        }
        // Notes a quit, crash or update left between capture and done finish now, with no click (notes audit B3).
        recorder.finalizer.foreground = cleanupModel.foreground
        if !isDisposableRun, !recorder.finalizer.resumeInterrupted().isEmpty {
            pill.banner = .captureNotice(line: NoteRecorder.captureNoticeLine)
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: .seconds(4))
                if case .captureNotice = self?.pill.banner { self?.pill.banner = nil }
            }
        }
        startLexicon()
        library.onPersonalizationChange = { [weak self] personalizer in
            guard let self else { return }
            self.dictation.personalizer = personalizer
            self.recorder.personalizer = personalizer
            self.downloads.dictionaryChanged(hasTerms: !self.library.dictionary.isEmpty)
            self.warmStandingVocabulary()
            self.lexicon?.scheduleRebuild()
        }
        library.startObserving()
        refreshEntitlementSnapshot()
        if !isDisposableRun, FeatureFlags.accounts, let config = AccountConfiguration() {
            Task { [weak self] in
                let client = AccountClient(configuration: config)
                while let self {
                    await self.refreshAccountEntitlement(client: client)
                    try? await Task.sleep(for: .seconds(24 * 60 * 60))
                }
            }
        }
        // Clicking the resting pill starts hands-free dictation into whatever app has focus;
        // the panel never activates, so the user's text field keeps keyboard focus.
        pillCoordinator.show(
            onTapIdle: { [weak self] in
                Logger(subsystem: "app.hushy", category: "pill").info("pill tap → toggleHandsFree")
                self?.dictation.toggleHandsFree()
            },
            onStop: { [weak self] in
                guard let self else { return }
                if self.recorder.isRecording { self.recorder.stop() } else { self.dictation.toggleHandsFree() }
            },
            onCancel: { [weak self] in
                guard let self else { return }
                // Note recording asks for confirmation inline in the pill before this fires;
                // dictation's ✕ discards immediately, matching the Esc-to-cancel hotkey.
                if self.recorder.isRecording { self.discardActiveNote() } else { self.dictation.handle(.cancel) }
            },
            onHide: { [weak self] in self?.settings.showIdlePill = false })
        refreshModeChip()
        pill.onModeChipWillShow = { [weak self] in self?.refreshModeChip() }
        pill.onPickMode = { [weak self] id in
            guard let self else { return }
            self.settings.manualModeOverrideID = id
            self.refreshModeChip()
        }
        pill.onResetMode = { [weak self] in
            guard let self else { return }
            self.settings.manualModeOverrideID = nil
            self.refreshModeChip()
        }
        pill.onActionButtonTap = { [weak self] in self?.voiceActions.toggleFromButton() }
        pill.onActionStopListening = { [weak self] in self?.voiceActions.stopListening() }
        pill.onActionDiscardListening = { [weak self] in self?.voiceActions.discardListening() }
        pill.onActionCancelProcessing = { [weak self] in self?.voiceActions.cancelProcessing() }
        pill.onActionConfirmRow = { [weak self] row in
            guard let self, case .actionConfirm(let card) = self.pill.state else { return }
            self.voiceActions.confirm(row, in: card)
        }
        pill.onActionCancelRow = { [weak self] row in self?.voiceActions.cancel(row) }
        pill.onActionOfferRow = { [weak self] row in self?.voiceActions.acceptOffer(row) }
        pill.onActionConfirmAll = { [weak self] in self?.voiceActions.confirmAll() }
        pill.onActionCancelAll = { [weak self] in self?.voiceActions.cancelAll() }
        // The answer card and the done chip (ask-actions, 2026-09-28).
        pill.onAnswerCopy = { [weak self] in self?.voiceActions.copyAnswer() }
        pill.onAnswerSaveNote = { [weak self] in self?.voiceActions.saveAnswerAsNote() }
        pill.onAnswerOpenSource = { [weak self] in self?.voiceActions.openAnswerSource() }
        pill.onFileReveal = { [weak self] id in self?.voiceActions.revealFile(rowID: id) }
        pill.onFileOpen = { [weak self] id in self?.voiceActions.openFile(rowID: id) }
        pill.onAnswerOpenInAssistant = { [weak self] in self?.voiceActions.openAnswerInAssistant() }
        pill.onAnswerSuggestion = { [weak self] in self?.voiceActions.takeAnswerSuggestion() }
        pill.onAnswerClose = { [weak self] in self?.voiceActions.closeAnswer() }
        pill.onAnswerFollowUp = { [weak self] in self?.voiceActions.followUpFromButton() }
        pill.onDoneUndo = { [weak self] in self?.voiceActions.undoDone() }
        pill.onVoiceEditUndo = { [weak self] in self?.dictation.voiceEdits.undo() }
        voiceActions.askBeforeDoing = { [weak self] in self?.settings.askBeforeDoing ?? .risky }
        voiceActions.searchesAppleNotes = { [weak self] in self?.settings.searchAppleNotes ?? false }
        voiceActions.enableAppleNotes = { [weak self] in
            guard let self else { return .notesUnavailable }
            return self.appleNotesSearch.turnOn { self.settings.searchAppleNotes = $0 }
        }
        voiceActions.onOpenNote = { [weak self] id in
            guard let self else { return }
            self.section = .notes
            self.selectedNoteID = id
            self.openMainWindow()
        }
        voiceActions.onOpenInAssistant = { [weak self] text in
            guard let self else { return }
            // The thread lands in the draft; the user reads it and sends it themselves. The
            // pane opens beside whatever section is showing (P0 14: right pane, every section).
            self.assistant.draft = text
            self.showAssistant(hasRoom: nil)
            self.openMainWindow()
        }
        installPillRoutes()
        hotkeys.pillKeyScope = { [weak self] in
            self?.pill.keyScope(now: Date(), ownTextFieldFocused: OwnTextFocus.isTextFieldFocused()) ?? .none
        }
        hotkeys.onPillKey = { [weak self] key in self?.pill.answer(key) }
        hotkeys.pillKeysPossible = pill.state.keyScope != .none
        pill.onKeyScopeChange = { [hotkeys] scope in hotkeys.pillKeysPossible = scope != .none }
        // A fix made just before Return is sent and gone before the next scheduled look: one more look now.
        hotkeys.onReturnKey = { EditWatcher.returnPressed(frontmostBundleID: NSWorkspace.shared.frontmostApplication?.bundleIdentifier) }
        installHotkeys()
        // Built here rather than in `init()`: its closure calls back into `startNoteRecording`,
        // which needs a fully-constructed `self` (`recorder`, `section`, `selectedNoteID`).
        // Meetings are private in release builds (`FeatureFlags.meetings`): no call detection at all.
        if FeatureFlags.meetings {
            let detection = CallDetectionCoordinator(
                settings: settings, recorder: recorder, pill: pill,
                startRecording: { [weak self] app in await self?.startNoteRecording(meetingApp: app) })
            callDetection = detection
            detection.start()
        }
        // The speech model starts downloading now, before the welcome screen is done: only the
        // network is needed, never a permission (see `DownloadCoordinator`).
        let downloads = self.downloads
        networkMonitor.start { downloads.networkChanged($0) }
        downloads.start()
        // Load the cleanup model now so the first correction doesn't pay a cold start, and again
        // whenever Settings switches backends (the local model loads off the main actor).
        let cleanupBackend = cleanupModel.backend
        // Told what the backend is, so a model trained on register lines also gets their prefixes built now.
        let warmingCleaner = SmartCleaner(
            model: cleanupBackend, wholeTranscript: { cleanupBackend.usesWholeTranscript },
            registerLines: { cleanupBackend.understandsRegisterLines })
        let prewarmCleanup = { [weak settings] in
            guard let level = settings?.dictationLevel, level != .verbatim else { return }
            warmingCleaner.prewarm(prefixesFor: level)
        }
        prewarmCleanup()
        cleanupModel.onSwitched = { _ in prewarmCleanup() }
        // The same warm-up again after the Mac wakes: sleep can drop the model and the Neural Engine's warm state.
        let speechEngine = speech
        wakeRewarmer = WakeRewarmer(
            cleanupLevel: { [weak settings] in settings?.dictationLevel ?? .verbatim },
            warmCleanup: { level in warmingCleaner.prewarm(prefixesFor: level) },
            warmSpeech: { await speechEngine.rewarm() })
        let cleanupController = cleanupModel
        let warmConditions = SystemWarmConditions()
        memoryPressure = MemoryPressureMonitor { level in
            warmConditions.memoryPressure(level)
            Task { @MainActor in cleanupController.memoryPressure(level) }
        }
        // Keeps the local model's pages in RAM between dictations (DECISIONS 2026-10-28, predictive warm).
        let keeper = ModelWarmthKeeper(
            memory: { await MainActor.run { cleanupController.residentMemory } },
            conditions: { warmConditions.read() },
            load: { [weak settings] in
                Task { @MainActor in
                    guard let level = settings?.dictationLevel, level != .verbatim else { return }
                    SmartCleaner(model: cleanupBackend).prewarm(prefixesFor: level)
                }
            })
        predictiveWarmer = PredictiveWarmer(keeper: keeper)
        predictiveWarmer?.start()
        // The boost guard's English word list takes ~50 ms to load; do it now, not mid-dictation.
        Task.detached(priority: .utility) { _ = BoostGuard.systemWords.count; _ = WordFrequency.shared.entryCount }
    }

    /// Starts the idle-timeout ticker and subscribes to screen-lock/sleep notifications that
    /// should lock History/Notes/Insights immediately, independent of the idle grace period.
    /// Dictation (the pill) is untouched by any of this — `AppLockController` only gates the
    /// main window's content, never capture.
    private func startAppLockObserving() {
        appLockIdleTimer = Timer.scheduledTimer(withTimeInterval: 15, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.appLock.checkIdleTimeout() }
        }
        let center = NSWorkspace.shared.notificationCenter
        let names: [Notification.Name] = [
            NSWorkspace.screensDidSleepNotification, NSWorkspace.willSleepNotification,
        ]
        appLockSleepObservers = names.map { name in
            center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.appLock.lockForSystemSleepOrScreenLock() }
            }
        }
        // A recording seals what it has before the Mac sleeps, so a sleep that never wakes loses nothing.
        appLockSleepObservers.append(center.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.recorder.checkpoint() }
        })
        trackAppLockSettings()
    }

    /// Keeps the controller's settings-backed fields in sync with Settings changes made
    /// elsewhere (e.g. the toggle in SettingsView), the same self-rearming
    /// `withObservationTracking` pattern `SettingsSync.track()` uses.
    private func trackAppLockSettings() {
        withObservationTracking {
            _ = (settings.appLockEnabled, settings.appLockAutoLockMinutes)
        } onChange: { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                self.appLock.isEnabled = self.settings.appLockEnabled
                self.appLock.autoLockMinutes = self.settings.appLockAutoLockMinutes
                self.trackAppLockSettings()
            }
        }
    }

    /// True while nothing may begin recording: the sign-in gate has the app suspended, or an
    /// uninstall is under way.
    var isCaptureClosed: Bool { isBetaSuspended || isUninstalling }

    /// Close all capture entry points as soon as an online approval check revokes access.
    func suspendBetaAccess() {
        isBetaSuspended = true
        closeEntryPoints(savingRecording: true)
    }

    /// Model downloads that waited for an account go on (Hushy's model host serves a signed-in app only).
    func accountSignedIn() {
        downloads.resumeAfterSignIn()
        cleanupModel.accountSignedIn()
    }

    func resumeBetaAccess() {
        isBetaSuspended = false
        // An uninstall has closed every way in; a sign-in check must not reopen them.
        guard !isUninstalling else { return }
        reopenEntryPoints()
    }

    /// Uninstall, first move: every way in is closed. A recording in progress is left for the
    /// uninstall to discard (`prepareForUninstall`), not stopped and saved.
    func beginUninstall() {
        isUninstalling = true
        closeEntryPoints(savingRecording: false)
    }

    /// The uninstall was abandoned before anything was removed, or was a test run that has
    /// ended with the app still open: the ways in open again, unless the sign-in gate has them
    /// closed for its own reason.
    func endAbandonedUninstall() {
        isUninstalling = false
        if !isBetaSuspended { reopenEntryPoints() }
    }

    private func closeEntryPoints(savingRecording: Bool) {
        hotkeyRetry?.invalidate()
        hotkeyRetry = nil
        hotkeys.stop()
        callDetection?.stop()
        if savingRecording, recorder.isRecording { recorder.stop() }
        dictation.handle(.cancel)
        pillCoordinator.hide()
    }

    private func reopenEntryPoints() {
        installHotkeys()
        callDetection?.start()
        pillCoordinator.unhide()
    }

    // MARK: Actions that span services

    func toggleNoteRecording() {
        guard FeatureFlags.meetings || recorder.isRecording else { return }
        if recorder.isRecording {
            recorder.stop()
            return
        }
        guard !isCaptureClosed else { return }
        guard !recorder.isFinishing, recorder.retryingNoteID == nil, !dictation.isBusy else { return }
        guard modelStatus.isReady else {
            pill.state = .error(modelStatus.label)
            return
        }
        Task {
            await startNoteRecording()
        }
    }

    /// - Parameter meetingApp: passed through to `NoteRecorder.start(meetingApp:)` when this
    ///   recording was started by accepting a call-detected prompt (see
    ///   `CallDetectionCoordinator`); `nil` for the manual record button/hotkey.
    func startNoteRecording(meetingApp: MeetingApp? = nil) async {
        // A recording already in progress is never interrupted or re-gated.
        guard FeatureFlags.meetings, recorder.activeNote == nil, !recorder.isFinishing, !isUninstalling else { return }
        do {
            try await recorder.start(meetingApp: meetingApp)
            if let id = recorder.activeNote?.id {
                section = .notes
                selectedNoteID = id
            }
        } catch {
            pill.present(failure: .didNotStart(PillModel.microphoneFailedMessage))
            log.error("note start failed: \(error.localizedDescription)")
        }
    }

    func deleteNote(_ note: Note) {
        guard note.id != recorder.activeNote?.id, !recorder.isFinishing else { return }
        library.deleteNote(note)
        if let id = note.id { noteStyles.forget(noteId: id) }
        if selectedNoteID == note.id { selectedNoteID = nil }
    }

    /// Cancels the in-progress note recording and removes it entirely: no transcription,
    /// no save. Called from the pill's ✕ button, which confirms with the user first.
    func discardActiveNote() {
        guard let note = recorder.discardActive() else { return }
        library.deleteNote(note)
        if selectedNoteID == note.id { selectedNoteID = nil }
    }

    func retryNoteTranscription(_ note: Note) {
        recorder.retryTranscription(for: note)
    }

    /// Opens Settings on the Account pane, whether or not the Settings window already exists.
    func openAccountSettings() {
        UserDefaults.standard.set(SettingsPane.account.rawValue, forKey: SettingsView.lastPaneDefaultsKey)
        openSettingsWindow()
        NotificationCenter.default.post(name: SettingsView.selectPane, object: SettingsPane.account)
    }

    /// Opens the Settings window centred on the main window (founder test 2026-09-28, P0 12:
    /// the window opened from the sidebar was not centred on the app). A Settings window
    /// that is already on screen keeps the place the user gave it; `SettingsView` centres
    /// itself on first appearance too, so ⌘, and the app menu land in the same spot.
    func openSettingsWindow() {
        let wasVisible = WindowPlacement.settingsWindow?.isVisible ?? false
        openSettingsHandler?()
        guard !wasVisible else { return }
        DispatchQueue.main.async {
            guard let window = WindowPlacement.settingsWindow else { return }
            WindowPlacement.center(window, over: WindowPlacement.mainWindow)
        }
    }

    /// Opens the Assistant pane beside the current section (never changing the section). When
    /// the window is too narrow for the pane (`AssistantPane.hasRoom`; pass `nil` to measure
    /// the main window here) the window grows to fit it, so "Show Assistant" always shows it.
    func showAssistant(hasRoom: Bool?) {
        guard FeatureFlags.meetings else { return }
        settings.assistantCollapsed = false
        let collapsedSidebar = settings.sidebarCollapsed
        let room = hasRoom ?? WindowPlacement.mainWindow.map {
            AssistantPane.hasRoom(windowWidth: $0.frame.width, sidebarCollapsed: collapsedSidebar)
        } ?? true
        guard !room, let window = WindowPlacement.mainWindow else { return }
        WindowPlacement.grow(window, toWidth: AssistantPane.windowWidthWithRoom(sidebarCollapsed: collapsedSidebar))
    }

    /// Mirrors the plan into the store for the out-of-process MCP helper (see
    /// `Store.writeProSnapshot` and .claude/DECISIONS.md "How the MCP helper learns the plan").
    /// Called at launch and after anything that changes `Entitlements.has(_:)`.
    private func refreshAccountEntitlement(client: AccountClient) async {
        // The session keeper owns every refresh of the rotating token, shared with the gate.
        guard let session = try? await AccountSessionKeeper.shared.usable() else { return }
        if let value = try? await client.entitlement(session.accessToken, userID: session.userID),
           (try? AccountSessionStore().load())?.userID == session.userID {
            try? AccountEntitlementStore().save(value)
            refreshEntitlementSnapshot()
        }
    }

    func refreshEntitlementSnapshot() {
        // The founding-member badge needs the first time this Mac saw a signed-in account
        // (`FoundingMember`); a snapshot or test run never writes it.
        if !isDisposableRun, (try? AccountSessionStore().load()) != nil { FoundingMember().noteSignedIn() }
        do {
            try store.writeProSnapshot(activeUntil: Entitlements.proActiveUntil())
        } catch {
            log.error("entitlement snapshot failed: \(error.localizedDescription)")
        }
    }

    /// Refreshes the pill's mode-switch chip: every mode (for the menu) and which one would
    /// apply to the *next* dictation for whatever app is currently frontmost — a read-only peek
    /// (`previewActiveMode`), so opening the menu never itself consumes the one-shot manual
    /// override the way starting a real dictation does (see `AppSettings.consumeActiveMode`).
    func refreshModeChip() {
        pill.modeChoices = settings.modes.map { (id: $0.id, name: $0.name, icon: $0.icon) }
        let bundleID = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        pill.activeMode = Self.chipMode(
            settings.previewActiveMode(bundleID: bundleID),
            isManualOverride: settings.manualModeOverrideID != nil)
    }

    /// What the pill's format chip shows for the mode that would apply next: nothing when
    /// that is just the Default fallback (no override, no app assignment — the chip is hidden
    /// rather than reading "Default"), otherwise the mode's name plus whether it came from the
    /// one-shot override (which the chip can reset) or a standing app assignment.
    static func chipMode(_ mode: Mode, isManualOverride: Bool) -> PillModel.ActiveMode? {
        if mode.id == Mode.BuiltInID.default && !isManualOverride { return nil }
        return PillModel.ActiveMode(name: mode.name, isManualOverride: isManualOverride)
    }

    /// Queues one or more dropped/opened files for transcription (see `ImportQueue`). Switches
    /// to Notes so the user sees the queue's progress rows and, once each finishes, the new
    /// note. Returns the number of supported media files in the drop, so callers can tell the
    /// user when it contained nothing importable.
    ///
    /// Imported files are notes, not meetings: they never count toward the Free plan's meeting
    /// allowance and are never gated by it (founder, 2026-09-28: only meetings recorded through
    /// the meeting integration count).
    @discardableResult
    func importFiles(_ urls: [URL]) -> Int {
        let supported = ImportQueue.supported(urls)
        guard FeatureFlags.meetings, !supported.isEmpty, !isUninstalling else { return 0 }
        if importQueue.enqueue(supported) > 0 { section = .notes }
        return supported.count
    }

    /// Presents the standard Open panel, restricted to supported audio/video types, for
    /// "Transcribe a file…" (⌘O) — see `RootView`'s `.commands`.
    func presentImportPanel() {
        guard FeatureFlags.meetings else { return }
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowedContentTypes = ImportQueue.supportedContentTypes
        panel.message = "Choose one or more audio or video files to transcribe."
        guard panel.runModal() == .OK else { return }
        importFiles(panel.urls)
    }

    func retryDictationTranscription(_ item: Dictation) {
        dictation.retryTranscription(for: item)
    }

    func exportNote(_ note: Note) -> URL? {
        library.exportNote(note, to: settings.exportDirectory)
    }

    /// SRT/WebVTT/timestamped-text export for a note's transcript (see `NoteTranscriptExporter`).
    /// Writes into the same export folder as Markdown (Settings → Notes).
    func exportTranscript(_ note: Note, format: NoteTranscriptExporter.Format) -> URL? {
        library.exportTranscript(note, format: format, to: settings.exportDirectory)
    }

    /// Whether `note` has timed turns (or a legacy note's segments) to export as subtitles, so the
    /// SRT/VTT menu items stay hidden rather than exporting an empty subtitle file.
    func hasTimedTranscript(_ note: Note) -> Bool {
        guard let id = note.id else { return false }
        return (try? store.hasTimedTurns(noteId: id)) == true || !library.segments(note).isEmpty
    }

    func openMainWindow() {
        // An uninstall closed the main window on purpose: its data is going, or gone.
        guard !isUninstalling else { return }
        NSApp.activate()
        if let window = NSApp.windows.first(where: { $0.identifier?.rawValue == "main" }) {
            window.makeKeyAndOrderFront(nil)
        } else {
            openWindowHandler?()
        }
    }

    func completeOnboarding() {
        if !modelStatus.isReady { downloads.notifyWhenReady() }
        settings.hasCompletedOnboarding = true
        funnel.markOnboardingCompleted()
        showOnboarding = false
    }

    /// The onboarding window appeared (not for snapshots): starts the funnel clock.
    func markOnboardingStarted() {
        funnel.markOnboardingStarted()
    }

    /// A dictation produced text. Records the funnel's "first dictation" (first one wins) and,
    /// if this happened during onboarding, marks onboarding complete right away — the "Try it
    /// now" step is the last required one, so quitting after a successful dictation must not
    /// replay setup on the next launch. The onboarding view itself stays up so the user can
    /// finish the optional closing step.
    func recordFirstDictation() {
        funnel.markFirstDictation()
        if showOnboarding, !settings.hasCompletedOnboarding {
            settings.hasCompletedOnboarding = true
        }
    }

    /// The voice-action practice in Settings: the chord listens and transcribes as usual, then
    /// hands the words to `heard` instead of running anything (`VoiceActionsController.rehearsal`).
    func beginActionRehearsal(_ heard: @escaping (String) -> Void) {
        voiceActions.rehearsal = heard
    }

    func endActionRehearsal() {
        voiceActions.rehearsal = nil
    }

    /// Onboarding/Home "Retry" after a failed or offline model download. `SpeechEngine.prepare`
    /// clears its failed load task, so this starts a fresh attempt (resuming partial files).
    func retryModelDownload() {
        downloads.retryNow()
    }

    /// Open at login by default: a dictation app that isn't running can't help. Applied once
    /// (users can still turn it off in Settings; macOS also lists it under Login Items).
    private func enableLaunchAtLoginOnce() {
        let key = "launchAtLoginDefaultedV1"
        guard !UserDefaults.standard.bool(forKey: key) else { return }
        UserDefaults.standard.set(true, forKey: key)
        if !settings.launchAtLogin { settings.launchAtLogin = true }
    }

    func clearSnapshotPreferences() {
        guard let snapshotDefaultsSuiteName else { return }
        UserDefaults(suiteName: snapshotDefaultsSuiteName)?.removePersistentDomain(forName: snapshotDefaultsSuiteName)
    }
}
