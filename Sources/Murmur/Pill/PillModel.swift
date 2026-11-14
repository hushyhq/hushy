import Foundation
import MurmurCore
import Observation

/// What the floating pill is showing.
enum PillState: Equatable {
    case idle
    case listening
    case handsFree(startedAt: Date)
    /// `modeName` is the active transform mode's name (e.g. "Email"), shown as "Applying
    /// Email…" while `ModeExecutor` runs; `nil` for a plain cleanup-only dictation, which
    /// keeps the existing "Processing" label exactly as before modes existed.
    case processing(modeName: String? = nil)
    /// `usedContext` is true when "Context awareness" (Settings → Privacy & data) actually
    /// changed this dictation — see `PipelineResult.usedContext` — and drives the small
    /// indicator `PillView` shows on the done state. `asHeard` is true when the model was wanted
    /// but timed out or was refused as a non-rewrite: the pill says "Pasted · as
    /// heard" rather than implying the text was polished. `notSent` is true when the text was
    /// pasted but the spoken/⌘Return "send" was withheld because focus moved in the ~60 ms
    /// before Return: "Pasted · Return not pressed".
    case done(words: Int, usedContext: Bool = false, asHeard: Bool = false, notSent: Bool = false, notARewrite: Bool = false)
    /// Nothing was pasted and the text is on the clipboard and in History: "Copied · switched
    /// apps  ⌘ V to paste" for 4 s. Focus moved, no text field was focused, or the paste failed
    /// (DECISIONS 2026-09-27 "Focus moved before the paste"; UI round 2026-09-28 §1).
    case copied(reason: CopyReason)
    /// A password field has focus: nothing was pasted and nothing was staged. "Not pasted ·
    /// password field [Copy]"; `copied` once the user tapped Copy ("Copied", no ⌘V hint). Carries
    /// no text: the Copy button's text lives outside the state (`present(_:text:)`).
    case held(copied: Bool)
    case error(String)
    /// A dictation produced no text: one line saying what happened and what to do, with ✕. Unlike
    /// `.error` nothing times it; it stays until it is dismissed, acted on or the next dictation
    /// starts (`DictationFailure`).
    case failed(DictationFailure)
    case recordingNote(startedAt: Date)
    /// Listening for a voice-action utterance (fn+⌃ held) — a distinct waveform mode from plain
    /// dictation so the user has a clear signal they're in Action mode, not typing mode.
    case actionListening
    /// The utterance is being transcribed, routed and extracted ("Working…"): the stop was
    /// taken, nothing has been created yet, and esc (or ×) cancels it. Its own state so the
    /// pill never borrows dictation's "Hearing" for an action.
    case actionProcessing
    /// One or more actions were extracted and are awaiting per-row confirmation.
    case actionConfirm(ActionConfirmationCardState)
    /// The answer card (ask your own stuff, summarize this): thinking, the answer with its
    /// source, a failure, or listening for a voice follow-up. Opens toward the screen centre.
    case answer(AnswerCardState)
    /// A Tier-1 action already happened (`ActionPolicy`): "✓ Added: Call Dana · Fri 9:00 · Undo",
    /// for the undo window (`ActionUndoWindow`), then "Undone" for a moment if Undo was tapped.
    case actionDone(DoneChipState)
    /// The dictation was not pasted: a card above the capsule with the text (all of it, scrolling
    /// when it is long), the plain reason and Copy. Carries no text — the card reads it from
    /// `PillModel.noFieldText`, like the held row's Copy.
    case noField(NoFieldMode)
    /// ⌘V was sent, the field could not be read afterwards and nothing was seen going wrong: one
    /// quiet line, "Pasted", with a muted tick. The dictation is still on the clipboard, and a
    /// click opens the unconfirmed card with the words (`PastedUncheckedRow`). Carries no text.
    case pastedUnchecked
    /// Done, with a quiet offer to add one word to the person's words (`PillNameChip`). `words` and
    /// `usedContext` are Done's. Carries no text: the word is in `PillModel.nameOffer`.
    case nameOffer(NameOfferPhase, words: Int = 0, usedContext: Bool = false)
    /// A voice edit of the selection (`VoiceEditController`): "Edited" with ✕ (put it back) and ✓, or
    /// one line saying why the selection was left as it was. Carries no text.
    case voiceEdit(VoiceEditChip)
    /// The restyle shortcut was pressed over a selection: tone chips and a Copy toggle (`RestyleRow`). Carries no text.
    case restyle(RestyleChooser)
}

/// A small transient card shown *above* the pill without changing its main `state` — used for
/// "Zoom call detected · Record notes?" (see `CallDetectionState`/`CallDetectionCoordinator`) and
/// the cancellable stop countdown that follows a call-detected recording. Kept separate from
/// `PillState` (rather than adding cases there) because both can appear while the pill's main
/// state is anything from `.idle` (a call started, nothing recording yet) to `.recordingNote` (the
/// stop countdown, layered over the ongoing recording) — folding them into `PillState` would force
/// awkward compound cases for every existing state.
enum PillBanner: Equatable {
    /// "Zoom call detected · Record notes?" — auto-dismisses at `expiresAt` (task: "disappears
    /// after 20 s").
    case callDetected(app: MeetingApp, expiresAt: Date)
    /// "Call ended · Stopping in Ns…", cancellable — shown only while a call-detected note is
    /// still recording (task: "5 s cancellable countdown").
    case stopCountdown(fireAt: Date)
    /// "Recording will stop in 2 min" — shown once, 2 minutes before "Maximum length" is reached
    /// (any note, not just call-detected ones). Not cancellable: the limit itself is a setting
    /// the user already chose in Settings, so the only control here is dismissing the notice.
    case maxLengthWarning
    case microphoneFallback(headset: String)
    /// "Getting faster — downloading the model" and a thin bar for its progress (nil: no bar): dictation is
    /// being cleaned up with the simple fixes only because no local model is ready (TRY-88). One line,
    /// no buttons, a few seconds.
    case cleanupModelWaiting(line: String, progress: Double?)
    /// A side of a recording died or went silent (capture health, notes audit B4), or a meeting is being recovered
    /// after a quit or crash. One line, no buttons; the recorder clears it when the side comes back.
    case captureNotice(line: String)

    var microphoneFallbackLine: String? {
        guard case .microphoneFallback(let headset) = self else { return nil }
        return "Using \(InputDeviceInfo.cleanName(headset))'s microphone · the Mac's is unavailable"
    }
}

@MainActor
@Observable
final class PillModel {
    nonisolated static let barCount = 9

    var state: PillState = .idle {
        didSet {
            stateRevision &+= 1
            changeRole = PillMotion.role(from: oldValue, to: state)
            if awaitsFirstAudio, !state.showsDictationBars { awaitsFirstAudio = false } // only a dictation's bars wait
            resetProcessingIfNeeded(from: oldValue)
            live.changed(to: state, from: oldValue)
            if case .idle = state { liveWordsAllowed = false; onIdle?() }
            if state != .held(copied: false) { heldText = nil }
            failureRetry = nil
            keptAudioExpiry?.cancel()
            keptAudioExpiry = nil
            if !state.keepsUnpastedText { noFieldText = nil }
            if case .noField = state {} else { isPointerOverCard = false }
            updateCardKeys(from: oldValue)
            onKeyScopeChange?(state.keyScope)
            if case .actionConfirm(let card) = oldValue { onActionCardChange?(card, state) }
            nameOfferEnded(from: oldValue)
        }
    }
    /// The pill went idle: whatever was waiting for it may go up.
    @ObservationIgnored var onIdle: (() -> Void)?
    /// The keys the new state could take (`PillState.keyScope`), for the event tap's thread.
    @ObservationIgnored var onKeyScopeChange: ((PillKeyScope) -> Void)?
    /// The word behind a `.nameOffer` row, and its spelling as the person has it now. Never in
    /// `state`, never logged; gone the moment the row goes (`PillNameChip`).
    var nameOffer: NameOffer?
    /// What became of the offer: add it, closed, or ignored. Called once per offer.
    @ObservationIgnored var onNameOfferAnswer: ((NameOfferAnswer) -> Void)?
    /// A confirm card on the pill changed or left it: the card as it was, and the state now.
    /// `VoiceActionsController` settles a question nobody answered from it.
    @ObservationIgnored var onActionCardChange: ((ActionConfirmationCardState, PillState) -> Void)?
    /// Until when ⏎/esc answer the showing confirm card: `cardKeyWindow` after it appears or the
    /// pointer last hovered it. After that the card is mouse-only, so a lingering card never eats
    /// an Enter meant for another app. Read by the event tap (`keyScope(now:ownTextFieldFocused:)`).
    @ObservationIgnored private(set) var cardKeysUntil: Date?
    /// Whether the footer shows ⏎/esc key caps — it never promises a key that won't work.
    private(set) var showsCardKeys = false
    @ObservationIgnored private var cardKeysExpiry: Task<Void, Never>?
    /// The dictated text behind a `.held` row, kept only so its Copy button can copy it. Never in
    /// `state`, never rendered or logged; dropped the moment the row goes away or is copied.
    @ObservationIgnored private var heldText: String?

    /// Shows a finished dictation's `state`. Rows with Copy keep the text outside `state`.
    func present(_ state: PillState, text: String) {
        heldText = state == .held(copied: false) ? text : nil
        if state.keepsUnpastedText { noFieldText = text }
        self.state = state
    }

    /// The dictated text behind a `.noField` card: shown whole and copied by its Copy
    /// button. Also kept behind the quiet "Pasted" row, for the card it opens. Not in `state`,
    /// not logged; gone the moment the card or row goes.
    private(set) var noFieldText: String?
    /// The pointer is over the no-field card: the card stays while it is (`selfDismissDecision`).
    var isPointerOverCard = false

    /// How long the showing row stays when nobody touches it, or nil when something else times it.
    /// The not-pasted card gets the time its words take to read (`NoFieldMode.dismissDelay(words:)`);
    /// every other row has the state's own delay.
    var selfDismissDelay: Duration? {
        guard case .noField(let mode) = state, let text = noFieldText else { return state.selfDismissDelay }
        return mode.dismissDelay(words: TextStats.wordCount(text))
    }

    func cardKeysLive(now: Date) -> Bool {
        cardKeysUntil.map { now < $0 } ?? false
    }

    /// Re-opens the card's key window when the pointer hovers it. Not for a card that waits on a
    /// question (`waitsOnOffer`): that one gets the window it appeared with and no other, so a
    /// pointer crossing the pill long after never hands ⏎ or esc back to it.
    func renewCardKeys(now: Date = Date()) {
        guard case .actionConfirm(let card) = state, !card.waitsOnOffer else { return }
        openCardKeys(now: now)
    }

    /// Opens the card's key window: when the card appears, and from `renewCardKeys`. The footer's
    /// key caps hide when it closes.
    func openCardKeys(now: Date = Date()) {
        guard case .actionConfirm = state else { return }
        let window = Self.cardKeyWindow
        cardKeysUntil = now.addingTimeInterval(TimeInterval(window.components.seconds))
        showsCardKeys = true
        cardKeysExpiry?.cancel()
        cardKeysExpiry = Task { [weak self] in
            try? await Task.sleep(for: window)
            guard !Task.isCancelled, let self else { return }
            self.showsCardKeys = self.cardKeysLive(now: Date())
        }
    }

    /// Closes the key window at once while the card stays (esc still dismisses it, unless it
    /// waits on a question). Snapshots and tests use it to show the card's mouse-only footer
    /// without waiting 8 s.
    func expireCardKeys() {
        cardKeysExpiry?.cancel()
        cardKeysUntil = nil
        showsCardKeys = false
    }

    /// A card appearing opens the window; leaving the card closes it. Row updates keep it.
    private func updateCardKeys(from oldValue: PillState) {
        if case .actionConfirm = state {
            if case .actionConfirm = oldValue { return }
            openCardKeys()
        } else if cardKeysUntil != nil || showsCardKeys {
            cardKeysExpiry?.cancel()
            cardKeysUntil = nil
            showsCardKeys = false
        }
    }

    /// The held row's Copy button: the only way held text reaches the clipboard.
    func copyHeldText() {
        guard state == .held(copied: false), let text = heldText else { return }
        heldText = nil
        onCopy?(text)
        state = .held(copied: true)
    }

    /// Runs a failed dictation again from its audio. The closure is the only thing holding that
    /// audio, in memory: every state change drops it (✕, Try again, the next dictation, anything
    /// else the pill shows), and the audio goes with it. Never in `state`, never written anywhere.
    @ObservationIgnored private var failureRetry: (@MainActor () -> Void)?
    /// Ends that hold after `DictationFailure.keptAudioLifetime`. Cancelled with every state change.
    @ObservationIgnored private var keptAudioExpiry: Task<Void, Never>?

    /// Shows a dictation that produced no text. The row stays until ✕, Try again or the next
    /// dictation. `retry` is given only with a failure that says its recording is kept, and is
    /// held for `lifetime` at most.
    func present(failure: DictationFailure, retry: (@MainActor () -> Void)? = nil,
                 keptFor lifetime: Duration = DictationFailure.keptAudioLifetime,
                 briefFor briefLifetime: Duration = EmptyDictationTriage.briefLifetime) {
        state = .failed(failure)
        failureRetry = failure.canRetry ? retry : nil
        if failure.isBrief {
            // The same timer slot as the kept audio's, so every state change cancels it too.
            let shown = stateRevision
            keptAudioExpiry = Task { [weak self] in
                try? await Task.sleep(for: briefLifetime)
                guard !Task.isCancelled, let self, self.stateRevision == shown, self.state == .failed(failure) else { return }
                self.state = .idle
            }
            return
        }
        guard failureRetry != nil else { return }
        let shown = stateRevision
        keptAudioExpiry = Task { [weak self] in
            try? await Task.sleep(for: lifetime)
            guard !Task.isCancelled else { return }
            self?.dropKeptAudio(shownAt: shown)
        }
    }

    /// The kept audio's time is up: it goes, and the row says so and stops offering Try again.
    /// `revision` is the state revision the row was shown at, so a timer that outlives its row
    /// can never touch a later state (another failure included).
    func dropKeptAudio(shownAt revision: UInt64) {
        guard stateRevision == revision, state == .failed(.transcription(recordingKept: true)) else { return }
        state = .failed(.transcription(recordingKept: false))
    }

    /// The failure row's Try again: hands the kept audio to the run it starts, once.
    func retryFailure() {
        guard state.isFailure, let retry = failureRetry else { return }
        failureRetry = nil
        retry()
    }

    /// The failure row's ✕.
    func dismissFailure() {
        if state.isFailure { state = .idle }
    }

    /// The quiet-microphone row's "Use Mac mic": the app takes the device name as its Microphone
    /// setting (`onUseMicrophone`), and the row says which microphone is now in use. Once: the
    /// row it becomes offers nothing.
    func useOfferedMic() {
        guard case .failed(let failure) = state, let name = failure.micOffer else { return }
        onUseMicrophone?(name)
        state = .failed(.micSwitched(to: name))
    }

    /// The quiet-microphone row's "Use Automatic": the Microphone setting goes back to Automatic
    /// (`onUseAutomatic`), and the row says so.
    func useAutomatic() {
        guard case .failed(let failure) = state, failure.offersAutomatic else { return }
        onUseAutomatic?()
        state = .failed(.usingAutomatic)
    }

    /// The held row's History button. The row never shows its words, so this is the one way to read
    /// them: the text goes along only so the app can find that exact dictation (`HistoryRoute`).
    func openHeldInHistory() {
        guard state == .held(copied: false), let text = heldText else { return }
        onOpenInHistory?(text)
        state = .idle
    }

    /// The not-pasted card's Copy (or Copy again) button: a plain copy (the text is not a secret),
    /// then "Copied" for a moment and the card closes.
    func copyNoFieldText() {
        guard case .noField(let mode) = state, let next = mode.afterCopy, let text = noFieldText else { return }
        onPlainCopy?(text)
        state = .noField(next)
    }

    private(set) var stateRevision: UInt64 = 0

    // MARK: Motion (`PillMotion`, `PillWait`)

    /// The pill's timings: `.standard` in the app. The preview swaps in the old ones, or a slowed copy.
    var motion = PillMotion.standard
    /// Preview only: forces Reduce Motion on or off for the pill. Nil follows the Mac's setting.
    var reduceMotionOverride: Bool?
    /// What the latest change of state was (opening, morphing, closing, a card rising or falling):
    /// the views animate the change with this role's values.
    private(set) var changeRole = PillMotion.Role.morph
    /// A dictation has asked for the microphone and no audio has arrived yet: its bars are grey and
    /// the capsule has no lime rim. Lime only ever means the microphone is open and heard.
    private(set) var awaitsFirstAudio = false
    /// The levels one update earlier and when `levels` replaced them, so each bar glides to its new
    /// level instead of stepping (`Waveform`).
    private(set) var previousLevels: [Double] = []
    private(set) var levelsUpdatedAt: Date?
    /// The listening bars as they stood at release, which the writing dots fold out of. Empty when
    /// the wait did not follow a dictation's bars (a note, a retry): the dots are then simply there.
    private(set) var foldLevels: [Double] = []
    /// Real cleanup progress for the wait that is showing, when there is some (`PillWaitProgress`).
    private(set) var waitProgress: PillWaitProgress?
    /// Which live-words layout the pill draws (`PillLiveVariant`, a hidden switch).
    var liveVariant: PillLiveVariant = .waveAndWords
    /// This dictation has a live draft (`DictationController.liveDraft`).
    var liveWordsAllowed = false
    /// The words in the pill while listening and writing; in memory only.
    private(set) var live = PillLiveState()

    /// A live draft's words, for the dictation that is still being spoken. Late ones are dropped.
    func noteHeard(_ text: String) {
        guard liveWordsAllowed, state.showsDictationBars else { return }
        live.hear(text)
    }

    /// The words the horizontal pill shows now, or nil for its usual look.
    func liveWords(vertical: Bool) -> String? {
        guard liveWordsAllowed, !vertical, live.isWide else { return nil }
        if state.showsDictationBars { return live.heard }
        guard state.isWriting else { return nil }
        return PillLiveWords.writing(settled: live.settled, ink: ink?.text, heard: live.heard)
    }

    /// Called as a dictation asks for the microphone (`DictationController.begin`).
    func awaitFirstAudio() {
        awaitsFirstAudio = true
    }

    /// One cleanup report for the wait shown at state revision `revision`. Reports for a wait that
    /// is over are dropped, and the fill only ever grows.
    func noteCleanupProgress(_ report: CleanupProgress, revision: UInt64, now: Date = Date()) {
        guard revision == stateRevision, case .processing = state, let since = processingStartedAt else { return }
        if let text = report.latestText { live.settle(text) }
        let elapsed = now.timeIntervalSince(since)
        waitProgress = waitProgress?.advanced(by: report, at: elapsed) ?? PillWaitProgress.starting(with: report, at: elapsed)
    }
    /// Smoothed levels in 0…1 for the waveform bars, newest last.
    private(set) var levels: [Double] = Array(repeating: 0, count: PillModel.barCount)
    /// Afterglow: each bar's recent peak, decaying along the cool curve (~600 ms to 5%). Drawn as
    /// a faint cap above the live bar so a whisper visibly "registers" and speech leaves a
    /// phosphor trail (docs/design/DESIGN-LANGUAGE.md §2.4).
    private(set) var peaks: [Double] = Array(repeating: 0, count: PillModel.barCount)

    /// The real stage of the ~0.3–2 s between key release and paste, so the pill's processing
    /// state says what is actually happening instead of a generic spinner. Set by
    /// `DictationController` at its existing `LatencyBreakdown` marks (main-actor writes only).
    enum ProcessingStage: Equatable {
        /// Speech recognition is finishing.
        case hearing
        /// Raw words exist; cleanup is running.
        case polishing
        /// Cleaned text is final and being pasted.
        case typing

        var label: String {
            switch self {
            case .hearing: "Hearing"
            case .polishing: "Polishing"
            case .typing: "Typing"
            }
        }
    }
    private(set) var processingStage: ProcessingStage = .hearing

    /// Words shown in the processing pill: *wet ink* (the raw transcript, dim) while cleanup runs,
    /// then *dry ink* (the cleaned text) while it pastes. Showing the user's own words ~300 ms
    /// after release is the biggest perceived-speed win there is. Cleared on every state other
    /// than processing.
    struct Ink: Equatable {
        var text: String
        var isDry: Bool
    }
    private(set) var ink: Ink?
    /// The preview keeps only the tail of long dictations; the pill shows one line anyway.
    static let inkPreviewLimit = 120
    /// The `.actionProcessing` label: what Hushy is doing with the utterance it just took.
    nonisolated static let actionProcessingLabel = "Working on it…"

    /// Advances the processing stage and the ink preview together. Stages only move forward
    /// within one processing run, so a late write can't make the pill go backwards.
    func advance(to stage: ProcessingStage, ink text: String? = nil) {
        guard case .processing = state, stage.order >= processingStage.order else { return }
        processingStage = stage
        if stage == .typing { live.typing() }
        if let text {
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            ink = trimmed.isEmpty ? nil : Ink(text: String(trimmed.suffix(Self.inkPreviewLimit)), isDry: stage == .typing)
        }
    }

    /// When the current processing run began, so Writing can reveal the last few words at 1 s and
    /// "Still writing…" at 5 s (`WritingPhase`). Nil outside processing.
    private(set) var processingStartedAt: Date?
    /// When the pill began working on a voice action, so its label can wait for a long one
    /// (`ActionWorkingPhase`). Nil outside `.actionProcessing`.
    private(set) var actionProcessingStartedAt: Date?

    private func resetProcessingIfNeeded(from oldValue: PillState) {
        if state == .actionProcessing {
            if oldValue != .actionProcessing { actionProcessingStartedAt = Date() }
        } else {
            actionProcessingStartedAt = nil
        }
        if case .processing = state {
            if case .processing = oldValue { return }
            processingStage = .hearing
            ink = nil
            processingStartedAt = Date()
            foldLevels = oldValue.showsDictationBars ? levels : []
            waitProgress = nil
        } else {
            processingStage = .hearing
            ink = nil
            processingStartedAt = nil
            waitProgress = nil
        }
    }
    var showWhenIdle = true
    /// When off, the idle pill stays visible during video and full screen (Settings → General).
    var hideIdleDuringVideoOrFullScreen = true
    /// The display the pill is on (`PillPanel.reposition` sets it) and the displays whose
    /// frontmost app is full screen (`PillDistractionWatcher` sets them). The idle pill steps aside
    /// when its own display is in the set; every other state shows as normal.
    var displayID: UInt32?
    var fullScreenDisplayIDs: Set<UInt32> = []
    /// Another app is holding a display-sleep assertion (`VideoPlayingDetector`).
    var videoPlaying = false
    /// The display edge the pill rests on (`PillPanel` sets it); rows, cards and tooltips open
    /// toward the screen centre from it (`PillLayout`).
    var anchor: PillAnchor = .bottom
    /// Being dragged: the pill shows its plain resting capsule (no hover, no hints), turned for
    /// `dragAnchor`, the edge a release would snap to — so it morphs as it nears a side edge.
    var isDragging = false
    var dragAnchor: PillAnchor?
    /// Frames of the drawn shapes in the panel's content (`PillLayout.space`, top-left origin).
    /// The panel takes the pointer only over these (`PillHitTest`); not observed by views.
    @ObservationIgnored var hitRegions: [CGRect] = [] {
        didSet { if hitRegions != oldValue { onHitRegionsChange?() } }
    }
    @ObservationIgnored var onHitRegionsChange: (() -> Void)?
    /// Whether the app lock is on (set by `DictationController`, read live). Locked, paste last
    /// and copy last refuse, so no recovery row names them (`LastTranscriptShortcut`).
    @ObservationIgnored var isAppLocked: @MainActor () -> Bool = { false }
    var triggerGlyph = "fn"
    /// The key pressed twice for a voice action (`ActionTriggerKey.keyCap`), for every hint on the pill.
    var actionKeyCap = ActionTriggerKey.default.keyCap
    /// While a voice action listens hands-free (started by a double tap): the key whose one tap
    /// cancels it, named in the ✕'s hover hint. Nil when the chord is held, which has no such tap.
    var actionCancelKey: String?
    /// The fn + control chord is held for the action being heard: letting go sends it, so the pill
    /// draws no buttons, as dictation does not while its key is held.
    var actionChordHeld = false

    /// What a dictation's listening pill shows in place of the waveform while the input is not
    /// delivering sound yet (`InputCueTracker`). `.hearing` is the waveform, as always.
    enum InputCue: Equatable {
        case hearing
        /// A Bluetooth headset's microphone link is still coming up: nothing said now is heard.
        case connectingHeadset

        var label: String? {
            switch self {
            case .hearing: nil
            case .connectingHeadset: "Connecting to headset…"
            }
        }
    }
    var inputCue: InputCue = .hearing
    /// What the listening pill draws for the action being heard (`ActionPillLayout`).
    var actionListeningMode: ActionListeningMode {
        actionChordHeld ? .held : .latched(cancelKey: actionCancelKey)
    }
    /// True while the active note recording is also capturing system/call audio — drives the
    /// small "call audio" indicator in the `.recordingNote` pill row. Set by `NoteRecorder`/
    /// `AppModel` when a recording starts (or stops) capturing the second stream; never implies
    /// anything about mic capture, which is always on while `.recordingNote`.
    var isCapturingCallAudio = false
    /// The call-detected prompt or stop countdown card, or `nil` when neither is showing. See
    /// `PillBanner`'s doc comment for why this is separate from `state`.
    var banner: PillBanner?
    /// User tapped "Record" on the call-detected prompt.
    var onBannerRecord: ((MeetingApp) -> Void)?
    /// User tapped "Not now", the prompt expired, or the stop countdown reached zero.
    var onBannerDismiss: (() -> Void)?
    /// User tapped "Never for <App>" on the call-detected prompt.
    var onBannerNever: ((MeetingApp) -> Void)?
    /// User tapped "Cancel" on the stop countdown, keeping the recording going.
    var onBannerCancelCountdown: (() -> Void)?
    /// Puts text on the clipboard as a deliberate copy (the held row's Copy).
    var onCopy: ((String) -> Void)?
    /// Puts text on the clipboard as an ordinary copy (the no-field card's Copy): kept by
    /// clipboard managers like any copy the user makes.
    var onPlainCopy: ((String) -> Void)?
    /// Records from the named input device from now on (the quiet-microphone row's one button).
    var onUseMicrophone: ((String) -> Void)?
    /// Puts the Microphone setting back on Automatic (the quiet-microphone row's other button).
    var onUseAutomatic: (() -> Void)?
    /// Opens the main window on History at the dictation with this text (the held row's History).
    var onOpenInHistory: ((String) -> Void)?
    /// Finish and insert/save (the ✓ button in hands-free dictation and note recording).
    var onStop: (() -> Void)?
    var onTapIdle: (() -> Void)?
    var onDismiss: (() -> Void)?
    /// Discard without inserting/saving (the ✕ button). Note recording confirms first.
    var onCancel: (() -> Void)?
    /// Dragging the pill moves its window; reset/hide come from its right-click menu.
    var onDragChanged: (() -> Void)?
    var onDragEnded: (() -> Void)?
    var onResetPosition: (() -> Void)?
    var onHide: (() -> Void)?
    /// Modes available for the "Format the next dictation as" menu (name + icon, in display
    /// order) and the callback to pick one for just the next dictation. Empty `modeChoices`
    /// hides the chip and the menu entirely — this keeps `PillView`/`PillModel` decoupled from
    /// `MurmurCore.Mode` (only plain strings cross the boundary), and means a snapshot/preview
    /// `PillModel` with no modes wired up renders exactly as before this feature existed.
    var modeChoices: [(id: UUID, name: String, icon: String)] = []
    var onPickMode: ((UUID) -> Void)?
    /// Called whenever the idle pill is hovered (about to show the format chip), so `AppModel`
    /// can refresh `activeMode` from the *current* frontmost app right before it's shown,
    /// rather than keeping a live observer on app-switch events just for this chip.
    var onModeChipWillShow: (() -> Void)?

    /// The mode that would format the *next* dictation, when one is actually forced — either
    /// picked from the chip/menu for one dictation (`isManualOverride`) or assigned to the
    /// frontmost app in Settings → Modes. `nil` means nothing is forced: Hushy picks per app
    /// and falls back to plain cleanup, which the pill shows by *not* showing a chip at all
    /// (a "Mode: Default" chip read as meaningless — see DECISIONS.md, 2026-09-27).
    struct ActiveMode: Equatable {
        var name: String
        var isManualOverride: Bool
    }
    var activeMode: ActiveMode?
    /// User chose "Automatic" from the chip or the pill's context menu: clear the one-shot
    /// manual override.
    var onResetMode: (() -> Void)?

    /// Whether the idle pill shows the format chip above its buttons: only when at least one
    /// mode is wired up *and* a mode is actually forced for the next dictation.
    var showsModeChip: Bool { !modeChoices.isEmpty && activeMode != nil }
    /// "Format: Email" — says what the chip controls, never a bare mode name.
    var modeChipLabel: String? { activeMode.map { "Format: \($0.name)" } }
    /// "Automatic" is only offered when there is a one-shot override to clear; an app
    /// assignment is a standing setting, which the menu can still override for one dictation
    /// but not "reset".
    var canResetMode: Bool { activeMode?.isManualOverride == true }

    /// Which of the two idle controls (mic, ⚡) the pointer is over, if any.
    enum IdleControl: Equatable { case dictate, action }
    /// The pointer is over the idle pill (it expands to show its mic/action buttons, the hint
    /// label, and the format chip). Lives here rather than as view state so snapshots and tests
    /// can put the pill into its hovered layout without a live pointer.
    var isHovered = false {
        didSet { if !isHovered { hoveredIdleControl = nil } }
    }
    var hoveredIdleControl: IdleControl?

    /// The single hint label drawn above the hovered idle pill: "Dictate fn" at rest and while
    /// over the mic, "Action fn ⌃" while over the ⚡ button. One label that swaps its text,
    /// rather than a per-button tooltip layered on top of it, so the two can never stack.
    struct IdleHint: Equatable {
        var title: String
        var keys: [String]
    }
    var idleHint: IdleHint {
        switch hoveredIdleControl {
        case .action: IdleHint(title: "Action ×2", keys: [actionKeyCap])
        case .dictate, nil: IdleHint(title: "Dictate", keys: [triggerGlyph])
        }
    }
    /// Action confirmation card row callbacks (✓ / ✕ / Edit per row) and card-level shortcuts
    /// (Return = confirm all, Esc = cancel all) — wired by `VoiceActionsController`.
    var onActionConfirmRow: ((ActionConfirmationRow) -> Void)?
    var onActionCancelRow: ((ActionConfirmationRow) -> Void)?
    var onActionEditRow: ((ActionConfirmationRow) -> Void)?
    /// The tick on a row refused for a list or calendar that isn't there: add it to the default.
    var onActionOfferRow: ((ActionConfirmationRow) -> Void)?
    var onActionConfirmAll: (() -> Void)?
    var onActionCancelAll: (() -> Void)?
    /// Tapped/clicked to start an action utterance from the pill's Action button, independent
    /// of holding the fn+⌃ chord.
    var onActionButtonTap: (() -> Void)?
    /// Stop (finish and process) / discard an action utterance started from the pill or chord.
    var onActionStopListening: (() -> Void)?
    var onActionDiscardListening: (() -> Void)?
    /// Cancel while "Working…" (`PillState.actionProcessing`), before anything is created.
    var onActionCancelProcessing: (() -> Void)?
    /// The answer card's buttons and the done chip's Undo — wired by `VoiceActionsController`.
    var onAnswerCopy: (() -> Void)?
    var onAnswerSaveNote: (() -> Void)?
    var onAnswerOpenSource: (() -> Void)?
    /// A file row on the answer card: show it in Finder / open it. The argument is the row id.
    var onFileReveal: ((Int) -> Void)?
    var onFileOpen: ((Int) -> Void)?
    var onAnswerOpenInAssistant: (() -> Void)?
    /// The failure card's offer ("Search Apple Notes?").
    var onAnswerSuggestion: (() -> Void)?
    var onAnswerClose: (() -> Void)?
    /// The footer's follow-up control (a click starts listening; the chord does the same).
    var onAnswerFollowUp: (() -> Void)?
    var onDoneUndo: (() -> Void)?
    /// The voice-edit row's ✕ and esc: put the original selection back (`VoiceEditController.undo`).
    var onVoiceEditUndo: (() -> Void)?
    /// The restyle row's chips, Copy toggle and ✕ (`RestyleController`).
    var onRestylePick: ((RestyleStyle) -> Void)?
    var onRestyleToggleCopy: (() -> Void)?
    var onRestyleCancel: (() -> Void)?

    private var smoothed: Double = 0
    private var lastPush = Date.distantPast
    private var meter = AdaptiveLevelMeter()

    /// Feeds one RMS reading; throttled to ~33 updates per second.
    ///
    /// Uses `AdaptiveLevelMeter` (MurmurCore) rather than a fixed dB range: with Apple's voice
    /// processing off by default, a whisper (~-54 dBFS) and normal speech (~-38 dBFS) both need
    /// to visibly move the bars, and a fixed -55…-10 mapping barely registers whispers.
    func push(rms: Float, now: Date = Date()) {
        if awaitsFirstAudio { awaitsFirstAudio = false }
        let normalized = meter.push(rms: rms)
        // Fast attack, slower release, so bars jump with speech and fall gently.
        let factor = normalized > smoothed ? 0.6 : 0.2
        smoothed += (normalized - smoothed) * factor

        guard now.timeIntervalSince(lastPush) >= Self.levelUpdateInterval else { return }
        lastPush = now
        previousLevels = levels
        levelsUpdatedAt = now
        levels = Array(levels.dropFirst()) + [smoothed]
        peaks = zip(levels, Array(peaks.dropFirst()) + [smoothed]).map { level, peak in
            max(level, peak * Self.peakDecayPerTick)
        }
    }

    /// Per-update (≈30 ms) decay of a peak ghost: 0.86^20 ≈ 5% after ~600 ms (`Motion.coolDuration`).
    static let peakDecayPerTick = 0.86
    static let levelUpdateInterval: TimeInterval = 0.03

    func resetLevels() {
        smoothed = 0
        meter.reset()
        levels = Array(repeating: 0, count: Self.barCount)
        peaks = levels
        previousLevels = []
        levelsUpdatedAt = nil
        awaitsFirstAudio = false
    }

    /// Sets the waveform bars directly, bypassing the smoothing `push(rms:)` does. Used by
    /// snapshot rendering and previews to show a representative waveform without faking audio.
    func setLevels(_ levels: [Double], peaks: [Double]? = nil) {
        self.levels = levels
        self.peaks = peaks ?? levels
        previousLevels = []
        levelsUpdatedAt = nil
        awaitsFirstAudio = false
    }

    var isVisible: Bool {
        if banner != nil { return true }
        if case .idle = state { return showWhenIdle && !isHiddenByDistraction }
        return true
    }

    /// Video playback, a call, or a full-screen app on the pill's display (when the setting is on).
    var isHiddenByDistraction: Bool {
        guard hideIdleDuringVideoOrFullScreen else { return false }
        if videoPlaying { return true }
        return isHiddenByFullScreen
    }

    /// The frontmost app is full screen on the pill's own display.
    var isHiddenByFullScreen: Bool {
        displayID.map { fullScreenDisplayIDs.contains($0) } ?? false
    }
}

private extension PillModel.ProcessingStage {
    var order: Int {
        switch self {
        case .hearing: 0
        case .polishing: 1
        case .typing: 2
        }
    }
}
