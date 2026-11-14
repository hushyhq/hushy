import AppKit
import ApplicationServices
import AVFoundation
import Foundation
import MurmurCore
import Observation
import os

/// The push-to-talk state machine: key events in, text into the focused app out.
///
/// Hot path after key release: stop mic -> Parakeet (~50 ms) -> rules (<1 ms) -> paste.
/// Everything else (saving audio, history, stats) happens off the hot path.
@MainActor
@Observable
final class DictationController {
    enum Mode { case pushToTalk, handsFree }

    private enum Phase {
        case idle
        case recording(RecordingSession)
        case processing(ProcessingSession)
    }


    private struct RecordingSession {
        let id: UUID
        let mode: Mode
        let startedAt: Date
        let target: FocusTarget
        let settings: SessionSettings
        /// The key went down while an earlier take was still being written. Such a recording is push-to-talk only: a
        /// tap or a latch is never a hands-free recording, only a hold is a take (`handle`).
        var startedBehind = false
        /// The take being written when this recording began, to go back to if the recording is thrown away.
        var resume: ProcessingResume?
    }

    /// An earlier take that was in `.processing` when a recording began behind it.
    private struct ProcessingResume {
        let session: ProcessingSession
        let task: Task<Void, Never>?
    }

    /// A recording that is opening its microphone behind an earlier take (`begin` to `completeBegin`).
    private struct StartBehind {
        let resume: ProcessingResume?
    }

    private struct ProcessingSession {
        let id: UUID
        let startedAt: Date
        let target: FocusTarget
        let settings: SessionSettings
        let samples: [Float]
        let duration: TimeInterval
        /// The session that cleaned finished sentence groups while this recording was going, if there was one.
        /// `process()` closes it and never waits for it: the text always comes from one pass over the whole recording.
        let earlySession: EarlyCleanupSession?
        /// Full live-draft transcript at key release (never logged; reconciles common words after boosting).
        let liveDraftText: String?
    }

    /// Silent recordings shorter than this are dropped instead of saved as failed rows.
    private static let minimumSilentRecordingToKeep: TimeInterval = 1.5
    /// A solo release sooner than this turns the held recording into hands-free dictation.
    nonisolated static let minimumHold: TimeInterval = 0.25
    /// The recogniser's allowance after the release: three times the audio, at least 15 s, at most 10 minutes. A pass
    /// takes a few percent of the audio's length, so only a stall reaches it. The floor covers the bounded waits inside
    /// the pass (5 s behind a draft, 4 s for the drift model, 0.5 s for boosting) on a loaded 8 GB Mac.
    nonisolated static func defaultReleaseDeadline(forAudio seconds: TimeInterval) -> Duration {
        .seconds(min(max(15, seconds * 3), 600))
    }
    /// What a take is given on top of the recogniser's allowance for cleaning and the paste. A later take waits for an
    /// earlier one for as long as it is inside this, and no longer (`waitForTurn`).
    static let defaultTurnSlack: Duration = .seconds(60)
    /// The shortest recording cap already offered for notes, applied to hands-free dictation.
    static let handsFreeLimit: TimeInterval = MaxRecordingLength.thirtyMinutes.seconds

    /// The dictation microphone. Replaced only by tests, with a scripted engine.
    @ObservationIgnored var audio = AudioCapture()
    /// Opens the microphone off the main thread, one start at a time (`openMicrophone`).
    @ObservationIgnored private let captureStartQueue = DispatchQueue(label: "app.hushy.capture-start", qos: .userInteractive)
    /// Whether the person allowed the microphone. Replaced only by tests.
    @ObservationIgnored var microphoneGranted: () -> Bool = { AVAuthorization.microphoneGranted }
    @ObservationIgnored var micFacts: (@MainActor () -> MicFacts)?   // tests only; see `noTextFailure`
    @ObservationIgnored var inputCue = InputCueTracker()   // says when the recording is really heard
    @ObservationIgnored var microphones = MicrophoneSelector.shared   // which device a recording opens
    @ObservationIgnored let speech: SpeechEngine
    @ObservationIgnored private let modelStatus: SpeechModelStatus
    /// Cleanup on the backend Settings → Writing → "Cleanup model" picked
    /// (`CleanupModelController.backend`, swapped in place — no restart).
    @ObservationIgnored private let cleaner: SmartCleaner
    @ObservationIgnored private let keyDownWarm: KeyDownWarmScheduler
    @ObservationIgnored let pipeline: DictationPipeline
    /// One lane onto the recogniser for the live draft, early cleaning and the release pass (`RecogniserLane`).
    @ObservationIgnored let recogniserLane = RecogniserLane()
    @ObservationIgnored let store: Store
    @ObservationIgnored let settings: AppSettings
    @ObservationIgnored let pill: PillModel
    @ObservationIgnored let sounds: Sounds
    @ObservationIgnored private let hotkeys: HotkeyMonitor
    @ObservationIgnored let encryption: EncryptionController
    @ObservationIgnored let log = Logger(subsystem: "app.hushy", category: "dictation")
    @ObservationIgnored private let memoryCoordinator = MemoryCoordinator()
    @ObservationIgnored let nameOffers = NameOfferCoordinator()
    /// Words spoken over a selection (`FeatureFlags.voiceEdit`), on the same cleanup model.
    @ObservationIgnored let voiceEdits: VoiceEditController
    /// The shortcut and Services items that restyle the selected text, on the same model (`RestyleController`).
    @ObservationIgnored let restyle: RestyleController

    private var phase: Phase = .idle { didSet { reportBusyChange() } }
    /// Tells the summaries when a dictation starts and ends (`ForegroundActivity`), so they yield the local model.
    @ObservationIgnored var onBusyChanged: ((Bool) -> Void)?
    @ObservationIgnored private var reportedBusy = false
    /// Dictionary + snippets, kept in memory so the hot path never touches the database.
    @ObservationIgnored var personalizer = Personalizer()
    /// The personal lexicon as last built (`LexiconCoordinator`); read at key-down, never built on the hot path.
    @ObservationIgnored var lexicon = LexiconSnapshot.empty
    /// Hands one dictation's screen terms to the lexicon (pack sightings, counted in the background).
    @ObservationIgnored var onScreenTerms: (([String]) -> Void)?
    /// Identifiers/file names scanned from the user's chosen project folder (Settings -> Voice &
    /// style -> Coding), or nil when no project is set. Set by `AppModel` from
    /// `ProjectVocabularySettings`; read once per session at key-down like every other setting
    /// here, not live mid-dictation. See `CleanupOptions.projectVocabulary`, `CodeFileTags`.
    @ObservationIgnored var projectVocabulary: ProjectVocabulary?
    @ObservationIgnored private var peakLevel: Float = 0
    @ObservationIgnored private var resetTask: Task<Void, Never>?
    @ObservationIgnored private var handsFreeTimer: Timer?
    @ObservationIgnored private var processingTask: Task<Void, Never>?
    /// The second look at the last paste into a known field (`startLateLanding`); the next dictation ends it.
    @ObservationIgnored var lateLandingTask: Task<Void, Never>?
    /// The Esc re-reads that are waiting for the recogniser lane or running on it, by the id of the read they belong to
    /// (`rereadCancelled`). A new take cancels them (`yieldToNewTake`); `yieldedRereads` marks the ones it cancelled,
    /// which ask again once no take is under way.
    @ObservationIgnored var rereadAttempts: [UUID: Task<String, Error>] = [:]
    @ObservationIgnored var yieldedRereads: Set<UUID> = []
    /// Where a finished dictation goes, and the clipboard the second look may use. Replaced only by tests.
    @ObservationIgnored var delivery = DictationDelivery.live
    /// The recogniser the release pass and the re-read of a cancelled take use. The engine; replaced only by tests.
    @ObservationIgnored var transcriber: any Transcriber
    @ObservationIgnored private var cancellationRequestedIDs: Set<UUID> = []
    @ObservationIgnored var startPending = false // Internal for startup tests without a real microphone.
    @ObservationIgnored private(set) var pendingStartEvents: [(HotkeyEvent, Date)] = []
    /// Feeds the current recording to its early-cleaning session; nil while idle.
    @ObservationIgnored private var streamingCoordinator: StreamingCoordinator?
    @ObservationIgnored var lastLiveDraftText: String?
    /// Every take between the key release and its text being delivered, oldest first. A held key while one is still
    /// being cleaned and pasted starts the next recording at once, so several can be here at a time. A take is
    /// processed only when it is first in line (`waitForTurn`), so pastes keep the order the words were spoken in and
    /// each take's time budget starts when its turn does.
    @ObservationIgnored private var takes = TakeLine()
    /// A recording that is opening its microphone behind an earlier take.
    @ObservationIgnored private var startingBehind: StartBehind?
    /// What takes that finished behind a newer recording or take had to tell the person (one failed, or its words were
    /// held or copied), oldest first. Each is shown once the pill is free (`showNextParked`); a plain "done" is not
    /// kept. Nothing clears it: a failure's Try again may hold the only copy of the audio.
    @ObservationIgnored private var parkedRows: [@MainActor () -> Void] = []
    /// Every take in `takes`, so a take that is left behind as stuck can still be kept (`keepDroppedTake`).
    @ObservationIgnored private var sessionsInLine: [UUID: ProcessingSession] = [:]
    /// How long the recogniser may take on the whole recording after the key release; past it the take fails safe
    /// to its saved audio and Try again, so a stalled recogniser can never hold the controller in `.processing`.
    @ObservationIgnored var releaseDeadline: (TimeInterval) -> Duration = DictationController.defaultReleaseDeadline
    /// How long Esc waits for a take that is stuck mid-step before the controller is forced back to idle.
    @ObservationIgnored var escapeGrace: Duration = .seconds(2)
    @ObservationIgnored var turnSlack: Duration = DictationController.defaultTurnSlack
    #if DEBUG
    /// Tests only: a press starts a recording with no microphone, focused app or permission check.
    @ObservationIgnored var startsWithoutHardwareForTests = false
    /// Tests only: told when a take's processing begins, with its audio length and the release instant it was given.
    @ObservationIgnored var processStartedForTests: ((TimeInterval, ContinuousClock.Instant) -> Void)?
    /// Tests only: told when a start has opened the microphone, with its timing; the start then ends there, idle.
    @ObservationIgnored var microphoneOpenedForTests: ((DictationStartTiming) -> Void)?
    /// Tests only: told when a take's processing has finished, with its audio length.
    @ObservationIgnored var processEndedForTests: ((TimeInterval) -> Void)?
    #endif
    /// How long the current recording took to start, for its one `dictation start` log line.
    @ObservationIgnored var startTiming: DictationStartTiming?
    /// Set while a failed dictation's saved audio is being re-transcribed from History.
    var retryingDictationID: Int64?

    /// Called after a dictation is stored, so views can refresh.
    @ObservationIgnored var onSaved: (() -> Void)?
    /// Called once per dictation that produced text — pasted, or shown in the pill because no
    /// field had focus — right after it is stored. The onboarding funnel's "first dictation".
    @ObservationIgnored var onDictationSucceeded: ((Dictation) -> Void)?
    /// Capture arbiter supplied by AppModel when notes and dictation share the microphone.
    @ObservationIgnored var canBeginRecording: (() -> Bool)?
    /// Usage numbers (counts and timings only), set by AppModel; see `DictationController+Metrics`.
    @ObservationIgnored var metrics = DictationMetricsHooks()
    /// The pill's note when no local cleanup model is ready (`CleanupModelController.waitingBanner`).
    @ObservationIgnored var cleanupWaitNotice: () -> PillBanner? = { nil }

    init(
        speech: SpeechEngine, modelStatus: SpeechModelStatus, store: Store, settings: AppSettings,
        pill: PillModel, sounds: Sounds, hotkeys: HotkeyMonitor, encryption: EncryptionController,
        cleanupModel: any LanguageModel = LanguageModels.current, secondOpinion: (any LanguageModel)? = nil,
        isAppLocked: @escaping @MainActor () -> Bool = { false },
        voiceEditField: VoiceEditController.Field = .live, restyleEnvironment: RestyleController.Environment = .live
    ) {
        // Apple's model behind the Hushy fine-tune, asked only about filler the first pass left (SmartCleaner.secondPass);
        // it is skipped when both are the same model.
        let cleaner = SmartCleaner(model: cleanupModel,
                                   wholeTranscript: { (cleanupModel as? SwitchableLanguageModel)?.usesWholeTranscript ?? false },
                                   registerLines: { (cleanupModel as? SwitchableLanguageModel)?.understandsRegisterLines ?? false },
                                   abandoned: .shared, secondOpinion: secondOpinion)
        let keyDownWarm = KeyDownWarmScheduler { await cleaner.warmOnKeyDown() }
        self.cleaner = cleaner
        let voiceEdits = VoiceEditController(model: cleanupModel, pill: pill, field: voiceEditField)
        self.voiceEdits = voiceEdits
        self.restyle = RestyleController(model: cleanupModel, pill: pill, voiceEdits: voiceEdits,
                                         field: voiceEditField, environment: restyleEnvironment)
        self.keyDownWarm = keyDownWarm
        self.speech = speech
        self.transcriber = speech
        self.modelStatus = modelStatus
        self.pipeline = DictationPipeline(transcriber: speech, cleaner: cleaner, warmScheduler: keyDownWarm)
        self.store = store
        self.settings = settings
        self.pill = pill
        pill.isAppLocked = isAppLocked // paste last, copy last and the pill's recovery lines read it
        self.sounds = sounds
        self.hotkeys = hotkeys
        self.encryption = encryption
        hotkeys.onEvent = { [weak self] event in self?.handle(event) }
        hotkeys.onTimedEvent = { [weak self] event, time in self?.handle(event, at: time) }
        pill.onUseMicrophone = { [weak self] name in self?.useMicrophone(named: name) }
        pill.onUseAutomatic = { [weak self] in self?.useAutomaticMicrophone() }
        pill.onIdle = { [weak self] in self?.showNextParked() }
    }

    /// True from the key press until the last take is delivered, however many are in flight.
    var isBusy: Bool {
        if case .idle = phase { return !takes.isEmpty }
        return true
    }

    private func reportBusyChange() {
        let busy = isBusy
        guard busy != reportedBusy else { return }
        reportedBusy = busy
        onBusyChanged?(busy)
    }

    func handle(_ event: HotkeyEvent, at eventTime: Date = Date()) {
        if startPending {
            pendingStartEvents.append((event, eventTime))
            return
        }
        switch (event, phase) {
        case (.pressed, .idle), (.pressed, .processing):
            begin(mode: .pushToTalk, at: eventTime)
        case (.latched, .idle) where takes.isEmpty:
            begin(mode: .handsFree, at: eventTime)
        case (.latched, .recording(let session)) where session.startedBehind:
            // A tap, a brushed key or the second tap of a double tap that ended a hands-free recording: not a take.
            hotkeys.isLatched = false
            if eventTime.timeIntervalSince(session.startedAt) < Self.minimumHold { discard() }
        case (.latched, .recording(let session)):
            phase = .recording(RecordingSession(id: session.id, mode: .handsFree, startedAt: session.startedAt,
                                                target: session.target, settings: session.settings))
            hotkeys.isLatched = true
            show(.handsFree(startedAt: session.startedAt))
            startHandsFreeLimit(sessionID: session.id, startedAt: session.startedAt)
        case (.released, .recording(let session)) where session.mode == .pushToTalk:
            if eventTime.timeIntervalSince(session.startedAt) < Self.minimumHold {
                discard()
            } else {
                finish()
            }
        case (.stopLatched, .recording):
            finish()
        case (.finishLatched, .recording):
            finish()
        case (.cancel, .recording):
            cancel()
        case (.cancel, .processing):
            cancel()
        case (.interrupted, .recording(let session)) where session.mode == .pushToTalk:
            if eventTime.timeIntervalSince(session.startedAt) < 0.8 { discard() }
        case (.chordTaken, .recording(let session)) where session.mode == .pushToTalk:
            // The held fn became the action chord (fn+control): the utterance is the action's.
            discard()
        case (.latched, _):
            // Nothing can latch while a take is being written. The monitor has already counted it as latched.
            hotkeys.isLatched = false
        case (.pasteLast, _):
            pasteLast()
        case (.copyLast, _):
            copyLast()
        case (.restyleSelection, .idle) where takes.isEmpty:
            restyle.begin()
        default:
            break
        }
    }

    /// Start or stop from UI (menu bar, pill button).
    func toggleHandsFree() {
        // A second toggle while the mic opens stops the pending recording.
        if startPending { pendingStartEvents.append((.stopLatched, Date())); return }
        switch phase {
        case .idle: if takes.isEmpty { begin(mode: .handsFree) }
        case .recording: finish()
        case .processing: break
        }
    }

    /// Set when a press finds an earlier take still being cleaned and pasted: the microphone is free, so the
    /// recording starts at once and nothing the person says is lost. The earlier take carries on and keeps the pill
    /// until the key has been held (`revealBehind`); the new take is processed after it (`waitForTurn`).
    private func startBehind() -> StartBehind? {
        guard !takes.isEmpty else { return nil }
        guard case .processing(let current) = phase else { return StartBehind(resume: nil) }
        return StartBehind(resume: ProcessingResume(session: current, task: processingTask))
    }

    private func begin(mode: Mode, at eventTime: Date = Date()) {
        yieldToNewTake()
        let behind = startBehind()
        #if DEBUG
        if startsWithoutHardwareForTests { startForTests(mode: mode, at: eventTime, behind: behind); return }
        #endif
        var starting = DictationStartTiming(keyEvent: eventTime)
        // A press that cannot start a recording changes nothing while an earlier take is being written: that take
        // keeps the pill, and Esc still reaches it.
        guard modelStatus.isReady else {
            if behind == nil { resetHotkeyState(); flashError(modelStatus.label) }
            return
        }
        guard canBeginRecording?() ?? true else {
            if behind == nil { resetHotkeyState() }
            return
        }
        guard microphoneGranted() else {
            if behind == nil { resetHotkeyState(); fail(.didNotStart("Microphone access needed")) }
            return
        }
        lastLiveDraftText = nil
        resetTask?.cancel()
        peakLevel = 0
        startingBehind = behind
        startPending = true
        let sessionID = UUID()
        let microphoneChoice = microphones.prepare(audio, picked: settings.inputDeviceName)
        audio.voiceProcessing = settings.reduceBackgroundNoise
        // The microphone opens on its own queue (100-500 ms with voice processing or Bluetooth), so the main thread
        // stays free for the pill while it does. Hotkey events that arrive meanwhile wait in `pendingStartEvents`.
        let opening = openMicrophone(sessionID: sessionID)
        if behind == nil { showListening(mode: mode, at: eventTime) }
        starting.pillShown()
        startTiming = starting
        Task { @MainActor in
            // Give the listening pill a frame before reading AX on the main thread.
            try? await Task.sleep(for: .milliseconds(16))
            let opened = await opening.value
            continueBegin(mode: mode, at: eventTime, sessionID: sessionID, microphoneChoice: microphoneChoice,
                          opened: opened)
        }
    }

    /// Starts the capture off the main thread and, once it runs, asks the front app to build its accessibility
    /// tree (an Electron app can take a while to answer), in that order as before. The moment the capture is running,
    /// or why it could not start.
    private func openMicrophone(sessionID: UUID) -> Task<Result<(clock: ContinuousClock.Instant, date: Date), any Error>, Never> {
        let audio = self.audio
        let onLevel: @Sendable (Float) -> Void = { [weak self] rms in
            Task { @MainActor in
                guard let self else { return }
                guard case .recording(let active) = self.phase, active.id == sessionID else { return }
                self.peakLevel = max(self.peakLevel, rms)
                self.pill.push(rms: rms)
                self.inputCue.level(rms)
                self.noteFirstAudio()
            }
        }
        let queue = captureStartQueue
        return Task {
            await withCheckedContinuation { continuation in
                queue.async {
                    do {
                        try audio.start(onLevel: onLevel)
                    } catch {
                        continuation.resume(returning: .failure(error))
                        return
                    }
                    let opened = (clock: ContinuousClock.now, date: Date())
                    FocusTarget.exposeAccessibility(of: NSWorkspace.shared.frontmostApplication)
                    continuation.resume(returning: .success(opened))
                }
            }
        }
    }

    private func continueBegin(mode: Mode, at eventTime: Date, sessionID: UUID,
                               microphoneChoice: MicrophoneResolution,
                               opened: Result<(clock: ContinuousClock.Instant, date: Date), any Error>) {
        defer {
            startPending = false
            let queued = pendingStartEvents
            pendingStartEvents.removeAll()
            for (event, time) in queued { handle(event, at: time) }
        }
        let now = eventTime
        let behind = startingBehind
        startingBehind = nil
        let openedAt: (clock: ContinuousClock.Instant, date: Date)
        switch opened {
        case .success(let instant):
            openedAt = instant
        case .failure(let error):
            log.error("mic start failed: \(error.localizedDescription)")
            if behind == nil {
                resetHotkeyState()
                fail(.didNotStart(PillModel.microphoneFailedMessage))
            } else {
                say(owning: false) { self.fail(.didNotStart(PillModel.microphoneFailedMessage)) }
            }
            return
        }
        startTiming?.captureStarted(at: openedAt.clock)
        #if DEBUG
        if let report = microphoneOpenedForTests, let timing = startTiming {
            report(timing)
            _ = audio.stop()
            resetHotkeyState()
            showIdle()
            return
        }
        #endif
        completeBegin(mode: mode, at: now, sessionID: sessionID, microphoneChoice: microphoneChoice, behind: behind,
                      opened: openedAt.date)
    }

    private func showListening(mode: Mode, at eventTime: Date) {
        pill.resetLevels()
        pill.awaitFirstAudio()
        show(mode == .handsFree ? .handsFree(startedAt: eventTime) : .listening)
    }

    /// A recording that began behind a take shows itself only once the key has been held past `minimumHold`. Until
    /// then it could be a brushed key or the second tap of a double tap, and the pill is still the take's.
    private func revealBehind(sessionID: UUID, startedAt: Date) {
        let wait = max(0, Self.minimumHold - Date().timeIntervalSince(startedAt))
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(wait))
            guard let self, case .recording(let live) = self.phase, live.id == sessionID else { return }
            self.showListening(mode: .pushToTalk, at: startedAt)
        }
    }

    private func completeBegin(mode: Mode, at now: Date, sessionID: UUID,
                               microphoneChoice: MicrophoneResolution, behind: StartBehind?, opened: Date) {
        let readingFocus = Date()
        if microphoneChoice.rule == .headsetFallback,
           let headset = microphoneChoice.using?.name,
           !UserDefaults.standard.bool(forKey: "microphoneHeadsetFallbackNoticeShown") {
            UserDefaults.standard.set(true, forKey: "microphoneHeadsetFallbackNoticeShown")
            pill.banner = .microphoneFallback(headset: headset)
            Task { @MainActor [weak pill] in
                try? await Task.sleep(for: .seconds(6))
                if case .microphoneFallback = pill?.banner { pill?.banner = nil }
            }
        }
        // No local cleanup model is ready, so this dictation gets the simple fixes: say why, briefly.
        if pill.banner == nil, let notice = cleanupWaitNotice() {
            pill.banner = notice
            Task { @MainActor [weak pill] in
                try? await Task.sleep(for: .seconds(5))
                if pill?.banner == notice { pill?.banner = nil }
            }
        }
        TextInserter.preparePasteKey()
        var target = keyDownTarget()
        let screen = settings.contextAwarenessEnabled && FeatureFlags.screenContextSpelling
            ? ContextReader.termSnapshot(app: NSWorkspace.shared.frontmostApplication,
                                         excludedApps: settings.learningExcludedApps) : (terms: [], evidence: [])
        var capturedSettings = sessionSettings(for: target, contextTerms: screen.terms)
        capturedSettings.learning.screenTerms = screen.evidence
        let frontmost = NSWorkspace.shared.frontmostApplication
        capturedSettings.selection = FeatureFlags.voiceEdit ? SelectionReader.read(app: frontmost) : nil
        if settings.contextAwarenessEnabled && FeatureFlags.screenContextSpelling
            || TerminalAgentContext.isCandidate(bundleID: frontmost?.bundleIdentifier) {
            let box = WindowContextBox()
            capturedSettings.windowContext = box
            target.terminalContext = box
            startWindowRead(app: frontmost, box: box, target: target, settings: capturedSettings, sessionID: sessionID)
        }
        // Terms read from the screen make this dictation's vocabulary new, and the recogniser would build its boosting
        // session for it only after the key release (about 150 ms). Start that build now, while the person speaks.
        if let vocabulary = pipelineSettings(for: target, settings: capturedSettings).contextWarmVocabulary {
            let speech = self.speech
            Task.detached(priority: .userInitiated) { await speech.warmBoosting(for: vocabulary) }
        }
        if capturedSettings.cleanupOptions.level != .verbatim { keyDownWarm.schedule() }
        log.notice("key-down: microphone opened in \(Int(opened.timeIntervalSince(now) * 1_000)) ms, focused app read in \(Int(Date().timeIntervalSince(readingFocus) * 1_000)) ms")
        phase = .recording(RecordingSession(id: sessionID, mode: mode, startedAt: now, target: target,
                                            settings: capturedSettings, startedBehind: behind != nil,
                                            resume: behind?.resume))
        if behind != nil {
            processingTask = nil
            revealBehind(sessionID: sessionID, startedAt: now)
        }
        if FeatureFlags.personMemory, let app = target.bundleID, !ContextReader.isDenylisted(bundleID: app) {
            memoryCoordinator.prepare(
                app: app, history: store,
                copiesLearnedWords: settings.learnFromEdits && !settings.learningExcludedApps.contains(app),
                editLife: settings.memoryEditLife)
        } else {
            memoryCoordinator.cancel()
        }
        Task { await InstalledAppCatalog.shared.refresh() }
        Task { [store] in await RankedInstalledApps.shared.refreshIfStale(store: store) }
        let coordinator = StreamingCoordinator(recordingID: sessionID)
        streamingCoordinator = coordinator
        coordinator.begin(session: earlySession(for: target, settings: capturedSettings),
                          draft: liveDraft(recordingID: sessionID), audio: audio)
        hotkeys.isDictationActive = true
        hotkeys.isLatched = mode == .handsFree
        if mode == .handsFree { startHandsFreeLimit(sessionID: sessionID, startedAt: now) }
        beginInputCue()
        if capturedSettings.cleanupOptions.level != .verbatim { cleaner.prewarm() }
    }

    /// Detects terminal agents and reads context while recording; a late result is ignored. Logs counts only.
    private func startWindowRead(app: NSRunningApplication?, box: WindowContextBox, target: FocusTarget,
                                 settings captured: SessionSettings, sessionID: UUID) {
        let bundleID = app?.bundleIdentifier, pid = app?.processIdentifier ?? 0, excluded = settings.learningExcludedApps
        let readsScreen = settings.contextAwarenessEnabled && FeatureFlags.screenContextSpelling
        Task { [weak self] in
            let probe = await Task.detached(priority: .userInitiated) {
                TerminalAgentReader.inspect(bundleID: bundleID, pid: pid, excludedApps: excluded, readsScreen: readsScreen) }.value
            if TerminalAgentContext.isCandidate(bundleID: bundleID) {
                self?.log.notice("terminal context: agent \(probe.agent ? 1 : 0), field \(probe.surface?.rawValue ?? "-"), detection \(probe.milliseconds) ms") }
            if probe.agent, let self, case .recording(let active) = self.phase, active.id == sessionID { box.markAgentPrompt() }
            guard let outcome = probe.outcome else { return }
            self?.windowRead(outcome, box: box, target: target, settings: captured, sessionID: sessionID)
        }
    }

    private func windowRead(_ outcome: WindowContextReader.Outcome, box: WindowContextBox, target: FocusTarget,
                            settings captured: SessionSettings, sessionID: UUID) {
        log.notice("window context: \(outcome.characters) characters, \(outcome.nodesVisited) elements, \(outcome.milliseconds) ms (\(outcome.stoppedBy.rawValue)), \(outcome.terms.count) terms")
        guard !outcome.terms.isEmpty, case .recording(let active) = phase, active.id == sessionID else { return }
        box.publish(
            WindowContextPolicy.merged(fieldTerms: captured.contextTerms, windowTerms: outcome.terms),
            commonWordFiltered: outcome.commonWordFiltered)
        guard let vocabulary = pipelineSettings(for: target, settings: captured).contextWarmVocabulary else { return }
        box.setVocabulary(vocabulary)
        let speech = self.speech
        Task.detached(priority: .userInitiated) { await speech.warmBoosting(for: vocabulary) }
    }

    /// Ends a recording's early cleaning when the recording itself is thrown away.
    private func abandon(_ early: EarlyCleanupSession?) {
        guard let early else { return }
        early.close()
        Task { await early.end() }
    }

    #if DEBUG
    /// Test seam: a recording that has just ended, with no microphone, no focused app and no event
    /// tap, so everything after key release can be checked without hardware. The take is exactly `seconds` long:
    /// the tests tell takes apart by their length, and a stall of the test process while this runs must not
    /// change it (a stall here once made a 3 s take read as 4 s).
    func finishForTests(samples: [Float], heldFor seconds: TimeInterval = 2) {
        let session = RecordingSession(id: UUID(), mode: .pushToTalk, startedAt: Date().addingTimeInterval(-seconds),
                                       target: .detachedForTests, settings: sessionSettings(for: .detachedForTests))
        phase = .recording(session)
        hotkeys.isDictationActive = true
        complete(session, samples: samples, early: nil,
                 analysisOverride: DictationAudioAnalysis.analyze(samples), heldFor: seconds)
    }

    /// Test seam: what a press does once the checks and the microphone are out of the way.
    private func startForTests(mode: Mode, at eventTime: Date, behind: StartBehind?) {
        lastLiveDraftText = nil
        let id = UUID()
        if behind == nil { showListening(mode: mode, at: eventTime) }
        phase = .recording(RecordingSession(id: id, mode: mode, startedAt: eventTime, target: .detachedForTests,
                                            settings: sessionSettings(for: .detachedForTests),
                                            startedBehind: behind != nil, resume: behind?.resume))
        if behind != nil {
            processingTask = nil
            revealBehind(sessionID: id, startedAt: eventTime)
        }
        hotkeys.isDictationActive = true
        hotkeys.isLatched = mode == .handsFree
    }
    #endif

    /// Stop without inserting anything or saving history (accidental tap / shortcut).
    private func discard() {
        let resume = resumable()
        lastLiveDraftText = nil
        inputCue.end()
        audio.stop()
        noteRecordingEnded()
        abandon(streamingCoordinator?.detach())
        streamingCoordinator = nil
        leaveRecording(to: resume)
    }

    /// The take this recording began behind, if it is still being written.
    private func resumable() -> ProcessingResume? {
        guard case .recording(let session) = phase, let resume = session.resume,
              takes.contains(resume.session.id) else { return nil }
        return resume
    }

    /// The recording is over without a take: back to the take it began behind, which kept its place, or to idle.
    private func leaveRecording(to resume: ProcessingResume?) {
        guard let resume else {
            phase = .idle
            resetHotkeyState()
            showIdle()
            return
        }
        phase = .processing(resume.session)
        processingTask = resume.task
        hotkeys.isLatched = false
        if pill.state == .listening { show(.processing(modeName: resume.session.settings.mode.isTransform ? resume.session.settings.mode.name : nil)) }
    }

    /// The pill is free: the oldest row an earlier take could not show (`parkedRows`) goes up now, else it rests.
    private func showIdle() {
        if !showOldestParked() { show(.idle) }
    }

    @discardableResult
    private func showOldestParked() -> Bool {
        guard !parkedRows.isEmpty else { return false }
        parkedRows.removeFirst()()
        return true
    }

    /// The pill went idle by itself (a row was dismissed, tried again or timed out): the next parked row follows it,
    /// unless a recording or a take has the pill by now.
    private func showNextParked() {
        Task { @MainActor [weak self] in
            guard let self, case .idle = self.phase, self.pill.state == .idle else { return }
            self.showOldestParked()
        }
    }

    private func cancel() {
        let processing: ProcessingSession? = if case .processing(let session) = phase { session } else { nil }
        let recording: RecordingSession? = if case .recording(let session) = phase { session } else { nil }
        let resume = resumable()
        lastLiveDraftText = nil
        inputCue.end()
        let samples = audio.stop()
        // Cancellation (Esc/×) ends the early cleaning too, not just the mic. The saved cancelled audio below is
        // unaffected: its text always comes from `samples`, never from that session.
        noteRecordingEnded()
        abandon(streamingCoordinator?.detach())
        streamingCoordinator = nil
        if let processing {
            // Let the in-flight step finish its cancellation check. This preserves any
            // transcript and tells us whether ⌘V already went out before cancellation.
            cancellationRequestedIDs.insert(processing.id)
            processingTask?.cancel()
            resetHotkeyState()
            sounds.stop()
            show(.idle)
            // A step that never reaches its checkpoint (a stalled recogniser) must not keep the controller here:
            // Esc always gets out, and the audio is kept.
            let grace = escapeGrace
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: grace)
                self?.leaveStuckProcessing(processing)
            }
            return
        }
        processingTask?.cancel()
        processingTask = nil
        sounds.stop()
        leaveRecording(to: resume)
        // Keep cancelled speech for 24 h so a mistaken Esc can be recovered from History.
        if let recording, !samples.isEmpty {
            Task { await self.saveCancelled(samples: samples, target: recording.target, duration: Date().timeIntervalSince(recording.startedAt), settings: recording.settings) }
        } else if let processing, !processing.samples.isEmpty {
            Task { await self.saveAudioOnly(samples: processing.samples, target: processing.target,
                                            duration: processing.duration, settings: processing.settings,
                                            status: .cancelled) }
        }
    }

    /// Esc was pressed on a take still in flight and its step has not answered: free the controller and keep the audio
    /// as a cancelled row. If the step wakes later it finds the take gone and does nothing.
    private func leaveStuckProcessing(_ stuck: ProcessingSession) {
        guard isCurrent(stuck.id), cancellationRequestedIDs.contains(stuck.id) else { return }
        log.error("cancelled take did not stop; back to idle, audio kept")
        cancellationRequestedIDs.remove(stuck.id)
        let ownedPhase = isProcessing(stuck.id)
        leaveLine(stuck.id)
        if ownedPhase {
            processingTask = nil
            phase = .idle
            resetHotkeyState()
            show(.idle)
        }
        guard !stuck.samples.isEmpty else { return }
        Task { await self.saveAudioOnly(samples: stuck.samples, target: stuck.target, duration: stuck.duration,
                                        settings: stuck.settings, status: .cancelled) }
    }

    func finish() {
        guard case .recording(let session) = phase else { return }
        handsFreeTimer?.invalidate()
        handsFreeTimer = nil
        // The ticks stop here, and so does cleaning ahead: nothing new starts from this instant. `stop()` returns
        // the complete recording whatever the ticks already handed out.
        let early = streamingCoordinator?.detach()
        early?.close()
        streamingCoordinator = nil
        inputCue.end()
        noteRecordingEnded()
        complete(session, samples: audio.stop(), early: early)
    }

    /// The recording has stopped; analysis leaves the main actor before recognition.
    private func complete(_ session: RecordingSession, samples: [Float], early: EarlyCleanupSession?,
                          analysisOverride: DictationAudioAnalysis? = nil, heldFor: TimeInterval? = nil) {
        let duration = heldFor ?? Date().timeIntervalSince(session.startedAt)
        // A few stretches beyond full scale are silenced before anything measures the recording: the gate, the gain
        // and the kept audio all see the repaired one. A recording too bad to repair is left whole, and fails below.
        let repaired = repairedRead(samples)
        let samples = repaired ?? samples
        let analysisOverride = repaired == nil ? analysisOverride : nil
        let liveDraftText = lastLiveDraftText
        lastLiveDraftText = nil
        let processing = ProcessingSession(id: session.id, startedAt: session.startedAt, target: session.target,
                                           settings: session.settings, samples: samples, duration: duration,
                                           earlySession: early, liveDraftText: liveDraftText)
        phase = .processing(processing)
        joinLine(processing)
        hotkeys.isLatched = false
        let heldForLink = headsetWasStillConnecting(samples)
        if !heldForLink { sounds.stop() }
        show(.processing(modeName: session.settings.mode.isTransform ? session.settings.mode.name : nil))
        if let analysisOverride, takes.isFirst(processing.id) {
            // The tests hand in the analysis, and with nothing ahead there is nothing to wait for: decided at once.
            takes.start(processing.id, limit: turnLimit(forAudio: duration))
            guard accept(analysisOverride, session: processing, heldForLink: heldForLink) else { return }
            processingTask = Task {
                await process(session: processing, analysis: analysisOverride, releasedAt: Date(),
                              releasedInstant: ContinuousClock.now)
            }
            return
        }
        processingTask = Task {
            await waitForTurn(processing.id, audio: duration)
            let analysis: DictationAudioAnalysis
            if let analysisOverride {
                analysis = analysisOverride
            } else {
                analysis = await Task.detached(priority: .userInitiated) {
                    DictationAudioAnalysis.analyze(samples)
                }.value
            }
            guard isCurrent(processing.id) else { return }
            guard accept(analysis, session: processing, heldForLink: heldForLink) else { return }
            // The release instant counts from this take's turn, not from the key: the cleanup model's time is
            // measured from it, and the wait behind an earlier take is not the model's.
            await process(session: processing, analysis: analysis, releasedAt: Date(),
                          releasedInstant: ContinuousClock.now)
        }
    }

    private func accept(_ analysis: DictationAudioAnalysis, session: ProcessingSession,
                        heldForLink: Bool) -> Bool {
        let gate = analysis.gate
        let samples = session.samples
        log.notice("gate \(gate.hasSpeech ? "pass" : "fail") \(gate.metrics.logSummary, privacy: .public) threshold \(gate.threshold, format: .fixed(precision: 5)) active \(String(format: "%.0f%%", gate.activeFrameFraction * 100), privacy: .public)")
        let evidence = analysis.evidence
        let hasSpeech = analysis.hasSpeech
        log.notice("speech evidence \(hasSpeech ? "yes" : "no", privacy: .public): \(evidence.runs.count) runs, \(String(format: "%.2f", evidence.speechSeconds), privacy: .public) s of \(String(format: "%.1f", evidence.duration), privacy: .public) s (\(String(format: "%.0f%%", evidence.share * 100), privacy: .public)), voiced \(String(format: "%.2f", evidence.voicedSeconds), privacy: .public) s")
        let unreadable = unreadableFailure(samples)
        if hasSpeech, unreadable == nil { microphones.trial = nil }
        guard hasSpeech, !heldForLink, unreadable == nil else {
            abandon(session.earlySession)
            let speaks = ownsPill(session.id)
            if isProcessing(session.id) {
                phase = .idle
                resetHotkeyState()
            }
            leaveLine(session.id)
            if let unreadable { say(owning: speaks) { self.fail(unreadable) }; return false }
            if heldForLink { say(owning: speaks) { self.fail(.headsetConnecting) }; return false }
            let triage = triageEmpty(gate: gate, samples: samples, duration: session.duration)
            if triage == .dismiss { if speaks { showIdle() }; return false }
            if session.duration >= Self.minimumSilentRecordingToKeep {
                Task { await self.saveAudioOnly(samples: samples, target: session.target, duration: session.duration,
                                                settings: session.settings, status: .failed) }
            }
            let isDigitalSilence = samples.allSatisfy { $0 == 0 }
            if isDigitalSilence { log.error("capture returned digital silence (\(samples.count) samples)") }
            // The gate heard something but it was not speech (a long recording of a room): the same brief line a
            // recording with words the recogniser could not read gets.
            let failure = triage == .brief ? DictationFailure.missedWords(heardSpeech: gate.hasSpeech)
                : noTextFailure(isDigitalSilence ? .micSilent : .heardNothing, samples: samples)
            say(owning: speaks) { self.fail(failure) }
            return false
        }
        return true
    }

    private func process(session: ProcessingSession, analysis: DictationAudioAnalysis,
                         releasedAt: Date, releasedInstant: ContinuousClock.Instant) async {
        #if DEBUG
        processStartedForTests?(session.duration, releasedInstant)
        #endif
        let stopWarm = Task { await keyDownWarm.beforeRealCall() }
        let samples = session.samples
        let duration = session.duration
        let target = session.target
        let id = session.id
        var timing = LatencyBreakdown(releasedAt: releasedAt)
        var metricsToken: UUID?   // set when a pasted dictation waits for the edit watcher's verdict
        var speaks = false   // whether this take owns the pill when it ends; read before it leaves the line
        let end = { (result: DictationMetricInput.Result, cleaned: SmartCleaner.Output?, words: Int) in
            // The tone it really ran with, worked out only if usage numbers are on (an autoclosure).
            metricsToken = self.metrics.report(
                result, cleaned, words, session.settings.mode, duration, timing, releasedAt,
                tone: MetricsTone.applied(
                    by: session.settings.tone, mode: session.settings.mode, category: target.category,
                    bundleID: target.bundleID, registerSent: cleaned?.sentRegisterLines ?? false),
                appKind: MetricsAppKind(target.category))
            speaks = self.ownsPill(id)
            self.finishPhase(id: id) }
        // The learning snapshot (keep-as-heard pairs, learned terms) is read off the main actor at key-down;
        // it is almost always ready by release. Wait for it so a quick tap never re-applies a reverted swap.
        await session.settings.learning.task?.value
        let settingsForPipeline = pipelineSettings(for: target, settings: session.settings)
        let raw: String
        let confidences: [WordConfidence]?
        let releaseSwaps: [VocabularySwap]
        // Whatever was cleaned ahead of the release is dropped on every way out of this function, after the one
        // `pipeline.clean` call that may use it. Only this recording's: the next one may already be cleaning ahead.
        defer {
            if let early = session.earlySession { Task { await early.end() } }
            // However this function left, the take is no longer in line, so a later one never waits for it.
            #if DEBUG
            processEndedForTests?(duration)
            #endif
            leaveLine(id)
        }
        do {
            log.notice("meter resampled \(analysis.gate.metrics.logSummary, privacy: .public)")
            log.notice("meter normalized \(analysis.normalizedMetrics.logSummary, privacy: .public)")

            // The early-cleaning session was closed at the release and is never waited for; the text always comes
            // from this one pass over the whole recording (measured 2026-09-26: faster and more accurate than a
            // transcript stitched together while speaking).
            let heard = try await transcribeRelease(analysis.normalized, vocabulary: settingsForPipeline.vocabulary,
                                                    within: releaseDeadline(duration))
            let transcribed = keepingWordsInSpeech(heard, evidence: analysis.evidence)
            let release = ReleaseSwaps.apply(transcribed, keep: settingsForPipeline.keepHeard)
            let boosted = release.text
            releaseSwaps = release.swaps
            let reconciled = DraftCommonWordGuard.reconcile(
                draft: session.liveDraftText, release: boosted, vocabulary: settingsForPipeline.vocabulary,
                installedApps: settingsForPipeline.installedApps)
            raw = reconciled.text
            // Restored draft spans can have a different token count from the release pass.
            confidences = reconciled.repairs > 0 ? nil : transcribed.confidences
            timing.mark(.speech)
            if reconciled.disagreements > 0 || reconciled.repairs > 0 {
                log.notice(
                    "draft vs release: disagreements=\(reconciled.disagreements) commonRepairs=\(reconciled.repairs)")
            }
        } catch {
            log.error("transcription failed: \(error.localizedDescription)")
            if cancellationRequestedIDs.contains(id) {
                end(.cancelled, nil, 0)
                // The recognition ended with the take, so it has no words yet. A new task reads the recording
                // again (this one is cancelled), so Esc during processing keeps the words as Esc while
                // speaking does.
                Task { await self.saveCancelled(samples: samples, target: target, duration: duration, settings: session.settings) }
                return
            }
            guard isCurrent(id) else { return }
            end(.failed, nil, 0)
            // History gets one failed row for this dictation, however often it is tried again.
            let saved = session.settings.retryOf ?? Task {
                await self.saveAudioOnly(samples: samples, target: target, duration: duration, settings: session.settings, status: .failed)
            }
            // The audio stays in memory behind the row's Try again, and goes when the row does. A newer recording owns
            // the pill, so a take failing behind it keeps its row until the pill is free.
            let retry = samples.isEmpty ? nil : tryAgain(session, saved: saved)
            say(owning: speaks) { self.fail(.transcription(recordingKept: !samples.isEmpty), retry: retry) }
            return
        }
        if cancellationRequestedIDs.contains(id) {
            end(.cancelled, nil, 0)
            let cancelled = Dictation(rawText: raw, text: raw, appBundleID: target.bundleID, appName: target.appName,
                                      durationSeconds: duration, status: .cancelled, appCategory: target.category.rawValue)
            await persist(cancelled, samples: samples, settings: session.settings)
            return
        }
        guard isCurrent(id) else { return }
        guard !raw.isEmpty else {
            end(.failed, nil, 0)
            switch triageEmpty(gate: analysis.gate, samples: samples, duration: duration) {
            case .dismiss:
                // An accidental tap: nothing to show and nothing worth keeping in History.
                if speaks { showIdle() }
                return
            case .brief: say(owning: speaks) { self.fail(.missedWords(heardSpeech: true)) }
            case .hint:
                let failure = noTextFailure(.noWords, samples: samples)
                say(owning: speaks) { self.fail(failure) }
            }
            await saveAudioOnly(samples: samples, target: target, duration: duration,
                                settings: session.settings, status: .failed)
            return
        }
        // Words over a selection may be an instruction about it: an edit ends the dictation here. A declined one
        // keeps the words in History (not the selection), so paste last still has them if they were meant as text.
        if let selection = session.settings.selection, case .finished(let result) = await voiceEdits.handle(
            spoken: raw, selection: selection, target: target,
            isCancelled: { self.cancellationRequestedIDs.contains(id) || !self.isCurrent(id) }) {
            end(result, nil, 0)
            guard result == .failed else { return }
            await persist(Dictation(rawText: raw, text: raw, appBundleID: target.bundleID, appName: target.appName,
                                    durationSeconds: duration, status: .notInserted, appCategory: target.category.rawValue),
                          samples: samples, settings: session.settings)
            return
        }
        var knownWords: MemoryIndex?   // the person's words, for the pill's name offer
        var personBlock = PersonBlockAssembler.finish(session.settings.learning.learned, transcript: raw)
        if FeatureFlags.personMemory {
            let shadow = memoryCoordinator.finish(transcript: raw)
            knownWords = shadow.index
            personBlock = shadow.block
            log.notice("memory shadow ready \(shadow.ready ? 1 : 0) why \(shadow.reason.rawValue, privacy: .public) lines \(shadow.block?.usedLines ?? 0) terms \(shadow.block?.terms.count ?? 0) prepareMs \(shadow.prepareMs) finishMs \(shadow.finishMs)")
        }
        // Pill latency choreography (docs/design/DESIGN-LANGUAGE.md §3.1): on a Large pill the user's own words
        // appear as wet ink while cleanup runs. A Mini pill shows no words at all, start to finish (founder,
        // 2026-10-28): the raw words differ from what lands, which makes the wait feel longer. A transform mode
        // (Email…) keeps its "Applying" label instead, since its output can differ a lot from what was said.
        let showsInk = settings.pillShowsLiveWords && !session.settings.mode.isTransform
        if ownsPill(id) { pill.advance(to: .polishing, ink: showsInk ? raw : nil) }

        // Detected once per dictation, on the raw ASR transcript, before cleanup — the language
        // this run's cleanup stages and on-device model instructions are gated on (see
        // TextCleaner.clean, SmartCleaner.clean) and what gets stored on the saved `Dictation`
        // row for the History language tag. Only meaningful when the language setting allows
        // more than English in the first place; English-only mode never produces anything but
        // English, so detection is skipped there and the row is left `nil` (== English).
        var (pipelineSettingsForRun, detectedLanguage) = settingsForPipeline.detectingLanguage(
            in: raw, enabled: settings.speechLanguageMode == .automatic)
        pipelineSettingsForRun.cleanupOptions.personBlock = personBlock
        // Groups cleaned while the recording was going are reused by `pipeline.clean` below wherever this transcript
        // has a group with exactly the same text, then dropped by this function's `defer` on the way out.
        // The model's deadline counts from the key release, speech recognition included.
        await stopWarm.value
        let pipelineOutput = await pipeline.clean(
            raw, confidences: confidences, settings: pipelineSettingsForRun, released: releasedInstant,
            onProgress: Self.progressObserver(for: pill))
        let cleaned = SmartCleaner.Output(
            // Return only for a spoken "press enter" — never added after a paste on Hushy's own.
            text: pipelineOutput.text, pressEnter: pipelineOutput.pressEnter,
            usedModel: pipelineOutput.usedModel, rejection: pipelineOutput.rejection,
            speedFallback: pipelineOutput.speedFallback, groups: pipelineOutput.groups)
        timing.mark(.cleanup)
        let cleanupOutcome = CleanupOutcomeSummary(groups: cleaned.groups, level: pipelineSettingsForRun.cleanupOptions.level)?.code
        if cancellationRequestedIDs.contains(id) {
            end(.cancelled, cleaned, 0)
            let cancelled = Dictation(rawText: raw, text: cleaned.text, appBundleID: target.bundleID,
                                      appName: target.appName, durationSeconds: duration, status: .cancelled,
                                      language: detectedLanguage?.code, cleanupOutcome: cleanupOutcome,
                                      appCategory: target.category.rawValue)
            await persist(cancelled, samples: samples, settings: session.settings)
            return
        }
        guard isCurrent(id) else { return }
        if ownsPill(id) { pill.advance(to: .typing, ink: cleaned.text) }
        // A command-only result ("press enter" with nothing else said) has no text to paste
        // but still carries an action: send Return to the bound target rather than dropping it.
        if cleaned.text.isEmpty, !cleaned.pressEnter {
            end(.failed, cleaned, 0)
            let failure = noTextFailure(.nothingToWrite, samples: samples)
            say(owning: speaks) { self.fail(failure) }
            let failed = Dictation(rawText: raw, text: "", appBundleID: target.bundleID, appName: target.appName,
                                   durationSeconds: duration, status: .failed, appCategory: target.category.rawValue)
            await persist(failed, samples: samples, settings: session.settings)
            return
        }

        // The one paste of this dictation — hands-free and streamed long dictations included;
        // nothing is pasted earlier. It re-checks the key-down target (app, field, window,
        // password field) and copies instead of pasting when focus moved (`TargetedDelivery`).
        let delivered = await self.delivery.deliver(cleaned.text, target, cleaned.pressEnter)
        let (delivery, focusAnswer, pastedField) = (delivered.result, delivered.answer, delivered.field)
        let words = TextStats.wordCount(cleaned.text)   // once: the pill's "done" row and the usage numbers share it
        let presentation = DeliveryPresentation.make(
            delivery, text: cleaned.text, usedContext: pipelineOutput.usedContext, asHeard: cleaned.deliveredAsHeard,
            notARewrite: cleaned.groups.contains { $0.guardCode == .notARewrite }, words: words)
        let status = presentation.status
        // The field the paste was bound to, not what key-down saw: a Chromium or Electron app often
        // shows no field at key-down and the real one by paste time.
        let observationElement: AXUIElement? = status == .inserted && !cleaned.text.isEmpty && !cleaned.pressEnter
            ? pastedField : nil
        // After the paste, never before it: the frame read is bounded and the window takes no focus.
        if status == .inserted, !cleaned.text.isEmpty, let pastedField { PasteGlow.shared.show(around: pastedField) }
        timing.mark(.insert)
        let latency = timing.totalMs
        let timeSplit = timing.timeSplit(groups: cleaned.groups)
        log.notice("""
            dictation \(samples.count / 16) ms audio · \(timing.summary, privacy: .public) · model=\(cleaned.usedModel) \
            why=\(LatencyBreakdown.modelWhy(cleaned), privacy: .public) breaks=\(LatencyBreakdown.breaksSummary(cleaned), privacy: .public) · \(delivery.logSummary, privacy: .public) \
            focus=\(focusAnswer.rawValue, privacy: .public) \
            \(focusAnswer == .unknown && !delivery.hasUnknownLandingCheck ? "landing=not-checked" : "", privacy: .public)
            """)
        if !pipelineSettingsForRun.contextTerms.isEmpty {
            let filtered = session.settings.windowContext?.filteredCommonWords ?? 0
            let boost = ScreenBoostPolicy.filter(pipelineSettingsForRun.contextTerms)
            let repairs = ContextSpellingFixer.fixCounting(raw, terms: pipelineSettingsForRun.contextTerms).repairs
            log.notice(
                "context terms: read=\(pipelineSettingsForRun.contextTerms.count) boosted=\(boost.keptNames) ordinaryDropped=\(boost.droppedOrdinary + filtered) screenRepairs=\(repairs)")
        }

        // Esc cancels presentation; TargetedDelivery restores the earlier clipboard.
        if cancellationRequestedIDs.contains(id) {
            end(.init(delivery), cleaned, words)
            let cancelled = Dictation(rawText: raw, text: cleaned.text, appBundleID: target.bundleID,
                                      appName: target.appName, durationSeconds: duration, latencyMs: latency,
                                      fixes: TextStats.changedWords(from: raw, to: cleaned.text),
                                      status: status == .inserted ? .inserted : .cancelled,
                                      language: detectedLanguage?.code, cleanupOutcome: cleanupOutcome,
                                      appCategory: target.category.rawValue, timeSplit: timeSplit)
            let savedID = await persist(cancelled, samples: samples, settings: session.settings)
            watchEdit(savedID, status, cleaned, observationElement, raw, target, detectedLanguage?.code, metricsToken,
                      swaps: releaseSwaps + pipelineOutput.vocabularySwaps, evidence: pipelineSettingsForRun.termEvidence(frontmostName: target.appName,
                                                                  screenTerms: session.settings.learning.screenTerms))
            return
        }

        guard isCurrent(id) else { return }
        end(.init(delivery), cleaned, words)
        let learns = FeatureFlags.personMemory
            && EditWatcher.learning(raw: raw, target: target, settings: settings, detectedLanguage: detectedLanguage?.code).input != nil
        // Done may carry a quiet offer to add one new name (flag `personMemory`); the pill times that row. A newer
        // recording owns the pill, so a take finishing behind it keeps a row that asks something of the person (its
        // words were held or copied) until the pill is free, and drops a plain Done.
        let offers = speaks && parkedRows.isEmpty
            && offerName(after: presentation, .init(pasted: cleaned.text, confidences: confidences, index: knownWords,
                                                    vocabulary: settingsForPipeline.vocabulary, isLearningAllowed: learns))
        if !offers {
            let shown = say(owning: speaks, asksSomething: presentation.status == .notInserted) {
                switch presentation.feedback {
                case .pill(let state): self.pill.present(state, text: cleaned.text) // text: only a held row's Copy
                case .notice(let message): self.show(.error(message))
                }
            }
            if shown { scheduleReset(after: presentation.hold) }
        }

        let dictation = Dictation(
            rawText: raw,
            text: cleaned.text,
            appBundleID: target.bundleID,
            appName: target.appName,
            durationSeconds: duration,
            latencyMs: latency,
            fixes: TextStats.changedWords(from: raw, to: cleaned.text),
            status: status,
            language: detectedLanguage?.code,
            cleanupOutcome: cleanupOutcome,
            appCategory: target.category.rawValue,
            timeSplit: timeSplit)
        let savedID = await persist(dictation, samples: samples, settings: session.settings)
        watchEdit(savedID, status, cleaned, observationElement, raw, target, detectedLanguage?.code, metricsToken,
                      swaps: releaseSwaps + pipelineOutput.vocabularySwaps, evidence: pipelineSettingsForRun.termEvidence(frontmostName: target.appName,
                                                                  screenTerms: session.settings.learning.screenTerms))
        if !cleaned.text.isEmpty { onDictationSucceeded?(dictation) }
        if delivery == .pasted, let lateLanding = delivered.lateLanding {
            startLateLanding(lateLanding, text: cleaned.text, savedID: savedID)
        }
    }

    func isRecording(_ id: UUID) -> Bool {
        if case .recording(let current) = phase { return current.id == id }
        return false
    }

    private func isCurrent(_ id: UUID) -> Bool { takes.contains(id) }

    private func joinLine(_ session: ProcessingSession) {
        takes.append(session.id)
        sessionsInLine[session.id] = session
    }

    private func leaveLine(_ id: UUID) {
        takes.remove(id)
        sessionsInLine[id] = nil
    }

    private func isProcessing(_ id: UUID) -> Bool {
        if case .processing(let current) = phase { return current.id == id }
        return false
    }

    /// Whether this take may speak through the pill: a live recording owns it, and otherwise the newest take does.
    private func ownsPill(_ id: UUID) -> Bool {
        if case .recording = phase { return false }
        return takes.isLast(id)
    }

    /// A take's row for the pill. A take that does not own the pill keeps a row that asks something of the person
    /// (`asksSomething`: it failed, or its words were held or copied) in `parkedRows`, and drops a plain Done. A take
    /// that does own it shows its row as it is, or when older rows are parked, the oldest of them (its own row, if it
    /// asks something, waits behind them). True when `row` was shown.
    @discardableResult
    private func say(owning: Bool, asksSomething: Bool = true, _ row: @escaping @MainActor () -> Void) -> Bool {
        guard owning else {
            if asksSomething { parkedRows.append(row) }
            return false
        }
        guard !parkedRows.isEmpty else {
            row()
            return true
        }
        if asksSomething { parkedRows.append(row) }
        showOldestParked()
        return false
    }

    /// A take starts only when every earlier take is done, so its text lands in the order the words were spoken and
    /// its time budget (the recogniser's allowance, and the cleanup model's, which counts from the release instant)
    /// is not used up by the wait. An earlier take that has run past its own limit is stuck and is left behind.
    private func waitForTurn(_ id: UUID, audio seconds: TimeInterval) async {
        while !Task.isCancelled, takes.contains(id), !takes.isFirst(id) {
            if let stuck = takes.dropStuckFirst(for: id) {
                log.error("an earlier take ran past its limit; going on without it")
                keepDroppedTake(stuck)
                continue
            }
            try? await Task.sleep(for: .milliseconds(10))
        }
        takes.start(id, limit: turnLimit(forAudio: seconds))
    }

    /// A take left behind as stuck leaves the line without being saved, and every later step of it ends at
    /// `isCurrent`, so its audio is kept here as a failed row with a Try again once the pill is free. If its step
    /// wakes later it finds the take gone and neither saves nor delivers anything.
    private func keepDroppedTake(_ id: UUID) {
        cancellationRequestedIDs.remove(id)
        guard let stuck = sessionsInLine.removeValue(forKey: id), !stuck.samples.isEmpty else { return }
        let saved = stuck.settings.retryOf ?? Task {
            await self.saveAudioOnly(samples: stuck.samples, target: stuck.target, duration: stuck.duration,
                                     settings: stuck.settings, status: .failed)
        }
        let retry = tryAgain(stuck, saved: saved)
        parkedRows.append { self.fail(.transcription(recordingKept: true), retry: retry) }
    }

    private func turnLimit(forAudio seconds: TimeInterval) -> Duration {
        releaseDeadline(seconds) + turnSlack
    }

    private func finishPhase(id: UUID) {
        cancellationRequestedIDs.remove(id)
        let ownedPhase = isProcessing(id)
        leaveLine(id)
        // A take finishing behind a newer recording leaves the phase, the pill and the hotkey state to that recording.
        guard ownedPhase else { return }
        phase = .idle
        processingTask = nil
        resetHotkeyState()
    }

    /// Try again for a failed dictation. The closure holds only what a second run needs (the audio,
    /// the target, the settings and the times): never the closed early-cleaning session.
    private func tryAgain(_ failed: ProcessingSession, saved: Task<Dictation?, Never>) -> @MainActor () -> Void {
        var settings = failed.settings
        settings.retryOf = saved
        settings.selection = nil   // the selection may have changed since; a retry only dictates
        let kept = ProcessingSession(id: UUID(), startedAt: failed.startedAt, target: failed.target, settings: settings,
                                     samples: failed.samples, duration: failed.duration, earlySession: nil,
                                     liveDraftText: nil)
        return { [weak self] in self?.reprocess(kept) }
    }

    /// Runs the kept audio through `process` once more, for the same target (if focus has moved
    /// the text is copied, as for any dictation).
    private func reprocess(_ kept: ProcessingSession) {
        guard case .idle = phase else { return }
        yieldToNewTake()
        phase = .processing(kept)
        joinLine(kept)
        hotkeys.isDictationActive = true
        show(.processing(modeName: kept.settings.mode.isTransform ? kept.settings.mode.name : nil))
        processingTask = Task {
            await waitForTurn(kept.id, audio: kept.duration)
            let samples = kept.samples
            let analysis = await Task.detached(priority: .userInitiated) {
                DictationAudioAnalysis.analyze(samples)
            }.value
            guard isCurrent(kept.id) else { return }
            await process(session: kept, analysis: analysis, releasedAt: Date(), releasedInstant: ContinuousClock.now)
        }
    }

    private func resetHotkeyState() {
        handsFreeTimer?.invalidate()
        handsFreeTimer = nil
        hotkeys.isDictationActive = false
        hotkeys.isLatched = false
    }

    private func startHandsFreeLimit(sessionID: UUID, startedAt: Date) {
        handsFreeTimer?.invalidate()
        let remaining = max(0, Self.handsFreeLimit - Date().timeIntervalSince(startedAt))
        handsFreeTimer = Timer.scheduledTimer(withTimeInterval: remaining, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, case .recording(let active) = self.phase, active.id == sessionID,
                      active.mode == .handsFree else { return }
                self.finish()
            }
        }
    }

    func show(_ state: PillState) {
        pill.state = state
    }

    func scheduleReset(after delay: Duration) {
        resetTask?.cancel()
        // A zero hold means the pill owns the row's lifetime (the no-field card waits for the
        // pointer), so no reset is scheduled here.
        guard delay > .zero else { return }
        let expectedRevision = pill.stateRevision
        resetTask = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled, let self, case .idle = self.phase,
                  self.pill.stateRevision == expectedRevision else { return }
            self.show(.idle)
        }
    }
}
