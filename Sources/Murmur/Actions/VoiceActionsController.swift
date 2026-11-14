import AppKit
import Foundation
import MurmurCore
import Observation
import os

/// The fn+⌃ "Action mode" state machine: hold the chord (or tap the pill's Action button),
/// speak one utterance, and Hushy either does it, asks first, or answers:
///
/// - **Ask** (`AskRouter`, before anything else): "ask Claude …" opens that service with the
///   question; "what groceries do I need" answers from your own stuff on the answer card;
///   "summarize this" reads the front window. While the answer card is open, holding the chord
///   again asks a follow-up in the same thread (`VoiceActionsController+Ask`).
/// - **Do** (`OpenCommandParser`, then `ActionExtractor`): `ActionPolicy` decides per action
///   whether it acts at once with "Done · Undo" or goes on the confirm card.
///
/// Deliberately a separate controller from `DictationController` — this pipeline never inserts
/// text into the focused app and never runs while plain dictation is active, so the two are
/// mutually exclusive by construction (see `handle`'s guard against `dictation.isBusy`).
/// Why a confirmed action didn't happen, in the words the card shows.
struct ActionExecutionFailure: Error, Equatable {
    let message: String
    /// Whether trying again is safe (`.failed`), could do it twice (`.uncertain`) or can't work
    /// until something changes (`.blocked`).
    var kind: ActionFailureKind = .failed
    /// The action itself ran (the Shortcut ran, the event was saved) but Hushy could not save its
    /// History record. Never retryable: it is done, only the note of it is missing.
    var didRun = false
}

@MainActor
@Observable
final class VoiceActionsController {
    @ObservationIgnored private let hotkeys: ActionHotkeyMonitor
    @ObservationIgnored let pill: PillModel
    @ObservationIgnored private let speech: SpeechEngine
    @ObservationIgnored private let modelStatus: SpeechModelStatus
    @ObservationIgnored let store: Store
    @ObservationIgnored private var maxListenTask: Task<Void, Never>?
    @ObservationIgnored let audio = AudioCapture()
    @ObservationIgnored let extractor: ActionExtractor
    @ObservationIgnored private let executor: ActionExecutor
    @ObservationIgnored let answerer: OwnStuffAnswerer
    @ObservationIgnored let summarizer: ScreenSummarizer
    @ObservationIgnored let log = Logger(subsystem: "app.hushy", category: "voice-actions")

    /// Checked before starting: plain dictation and note recording take priority over the
    /// action trigger firing accidentally mid-session (mirrors `DictationController.canBeginRecording`).
    @ObservationIgnored var canBeginRecording: (() -> Bool)?
    /// Usage numbers: one call per action that reached a terminal state (succeeded, failed or
    /// cancelled). Closed vocabulary only, never the action, its text or the error's message.
    @ObservationIgnored var onMetric: ((VoiceActionMetricEvent) -> Void)?
    /// The "Reduce background noise" setting, read at each start so the action records the same
    /// way dictation does (see `AudioCapture.voiceProcessing` for why they must match).
    @ObservationIgnored var usesVoiceProcessing: (() -> Bool)?
    /// The Microphone setting (nil is Automatic), read at each start, and the app's one selector:
    /// an action records from the microphone a dictation would (`MicrophoneSelector`).
    @ObservationIgnored var pickedMicrophone: () -> String? = { nil }
    @ObservationIgnored var microphones = MicrophoneSelector.shared
    /// Whether the entitlement allows executing confirmed actions (`Entitlements.has(.voiceActions)`).
    /// Voice actions are free (founder, 2026-11-11), so this is true; it stays as the one hook a
    /// future Teams policy would use. Read per use, never cached.
    @ObservationIgnored var isEntitled: () -> Bool = { Entitlements.has(.voiceActions) }
    /// The voice-action practice (Settings → Voice actions): while set, an utterance is transcribed
    /// and handed here instead of being routed, executed or counted — nothing is created and
    /// nothing is charged to the allowance (`AppModel.beginActionRehearsal`).
    @ObservationIgnored var rehearsal: ((String) -> Void)?
    /// Settings → Voice actions → "Ask before doing" (`ActionPolicy.AskBeforeDoing`), read per utterance.
    @ObservationIgnored var askBeforeDoing: () -> ActionPolicy.AskBeforeDoing = { .risky }
    /// Whether Apple Notes may be searched (Settings; needs the Automation permission).
    @ObservationIgnored var searchesAppleNotes: () -> Bool = { false }
    /// Turns Apple Notes search on from the failure card's offer (through `AppleNotesToggle`, so
    /// the setting stays off unless access was granted); returns what macOS and Notes said.
    @ObservationIgnored var enableAppleNotes: () -> AppleNotesAccessResult = { .notesUnavailable }
    /// An extra source consulted only when `searchesAppleNotes()` (the Apple Notes source).
    @ObservationIgnored var optionalSource: (any OwnStuffSource)?
    /// "Open in Assistant": the thread as text goes to the Assistant's draft.
    @ObservationIgnored var onHandoffProposed: ((HandoffProposal) -> Void)?
    @ObservationIgnored var onOpenInAssistant: ((String) -> Void)?
    /// "Open source" on a Hushy note.
    @ObservationIgnored var onOpenNote: ((Int64) -> Void)?
    /// How long Undo works after an action: the done chip's lifetime and the record's expiry
    /// (`ActionUndoWindow`, the one constant onboarding's copy reads too).
    static let defaultUndoWindow = ActionUndoWindow.interval
    @ObservationIgnored var undoWindow: TimeInterval = VoiceActionsController.defaultUndoWindow

    private var startedAt: Date? { didSet { publishListening() } }
    private var undoTimer: Task<Void, Never>?
    @ObservationIgnored private var headsUpTimer: Task<Void, Never>?
    /// Transcribing, routing and extracting the utterance ("Working…"); esc cancels it before
    /// anything is created (`cancelProcessing`).
    @ObservationIgnored private var processingTask: Task<Void, Never>?
    /// Which utterance owns the pill. Bumped when a new one starts (`begin`); every async result
    /// that wants to replace the pill's state checks it first, so an older action finishing late
    /// can never cover a newer card. History is still written: the effect happened.
    @ObservationIgnored private(set) var utteranceEpoch = 0
    /// The utterance (epoch) whose act-first action is in the executor right now. A cancel of that
    /// utterance reports nothing, because the action's own result reports; a cancel of any other
    /// utterance is its own event.
    @ObservationIgnored private var executingEpoch: Int?
    /// The store's refunds are reconciled once per controller lifetime, and again only after a
    /// failed attempt, so starting to speak never pays a database scan.
    @ObservationIgnored private var needsRefundReconcile = true
    /// Test seams. Defaults are the real extractor and store.
    @ObservationIgnored var extract: ((String, DateContext) async -> ActionExtractor.Output)?
    @ObservationIgnored var saveRecord: ((ActionRecord) throws -> ActionRecord)?
    /// Test seam for the dictation fallback: replaces the real paste into the focused app.
    @ObservationIgnored var transcribeSamples: (([Float]) async throws -> String)?
    @ObservationIgnored var insertFallbackText: ((String) async -> Void)?
    @ObservationIgnored var refundUse: ((Int64) throws -> Void)?
    /// Records whose monthly use could not be given back yet; settled on the next Undo or use.
    @ObservationIgnored private var refundsPending: Set<Int64> = []
    @ObservationIgnored var writeUndone: ((Int64) throws -> Void)?
    @ObservationIgnored var writeUndoFailed: ((Int64) throws -> Void)?
    @ObservationIgnored var writeUndoExpired: ((Int64) throws -> Void)?
    /// Undone items whose record could not be updated yet; settled on the next Undo attempt.
    @ObservationIgnored private var undoneUnrecorded: Set<Int64> = []
    /// The answer card a follow-up interrupted, restored if the follow-up is discarded.
    @ObservationIgnored var interruptedAnswer: AnswerCardState?

    /// Whether an action utterance is currently being recorded or processed — checked by
    /// `DictationController.canBeginRecording` so plain dictation can't start mid-action and
    /// vice versa (the two pipelines are mutually exclusive, never concurrent).
    var isActionInProgress: Bool {
        startedAt != nil || isProcessing
    }
    var isProcessing = false

    init(
        hotkeys: ActionHotkeyMonitor, pill: PillModel, speech: SpeechEngine, modelStatus: SpeechModelStatus,
        store: Store, calendarBackend: any CalendarActionBackend, shortcutsBackend: any ShortcutsActionBackend,
        linkBackend: any LinkOpeningBackend = NoLinkBackend(), ownStuffSources: [any OwnStuffSource] = []
    ) {
        self.hotkeys = hotkeys
        self.pill = pill
        self.speech = speech
        self.modelStatus = modelStatus
        self.store = store
        self.executor = ActionExecutor(calendar: calendarBackend, shortcuts: shortcutsBackend, links: linkBackend)
        // Only Shortcuts the user actually has can be proposed (never a free-form name).
        self.extractor = ActionExtractor.explicit(shortcutLibrary: { await shortcutsBackend.availableShortcuts() })
        self.answerer = OwnStuffAnswerer(sources: ownStuffSources)
        self.summarizer = ScreenSummarizer()
        hotkeys.onEvent = { [weak self] event in self?.handle(event) }
        let listening = listeningForTap
        hotkeys.isHandsFreeListening = { @Sendable in listening.withLock { $0 } }
        pill.onActionCardChange = { [weak self] card, state in self?.reportUnansweredOffers(leaving: card, for: state) }
    }

    private func handle(_ event: ActionHotkeyEvent) {
        switch event {
        case .pressed:
            begin(chordHeld: true)
        case .released:
            // A hands-free session has no key held, so the chord's release is not its end.
            guard startedAt != nil, !handsFreeSession else { return }
            finish()
        case .doubleTapped:
            begin(handsFree: true)
        case .tapCancelled:
            guard isHandsFreeListening else { return }
            discardListening()
        }
    }

    /// The listening started by a double tap, which no key is held for. One bare tap of the
    /// key cancels it while this is true (`ActionHotkeyMonitor.isHandsFreeListening`); the key
    /// itself is never swallowed.
    var isHandsFreeListening: Bool { startedAt != nil && handsFreeSession }
    @ObservationIgnored private var handsFreeSession = false { didSet { publishListening() } }
    /// `isHandsFreeListening` for the event tap, which asks it on its own thread.
    @ObservationIgnored private let listeningForTap = OSAllocatedUnfairLock(initialState: false)

    private func publishListening() {
        let listening = isHandsFreeListening
        listeningForTap.withLock { $0 = listening }
    }

    /// Also called by the pill's Action button (a click starts the same flow as holding the
    /// chord, per the brief: "Also an Action button next to the mic (click to start an action)").
    /// Since a click has no natural "hold" duration, tapping again while listening finishes it.
    func toggleFromButton() {
        if startedAt != nil { finish() } else { begin() }
    }

    /// The pill's Stop button: process what was said so far.
    func stopListening() {
        guard startedAt != nil else { return }
        finish()
    }

    /// The pill's × or Esc: drop the utterance without calling the model or executing anything.
    func discardListening() {
        guard startedAt != nil else { return }
        maxListenTask?.cancel()
        startedAt = nil
        pill.actionCancelKey = nil
        pill.actionChordHeld = false
        _ = audio.stop()
        if let interrupted = interruptedAnswer {
            interruptedAnswer = nil
            pill.state = .answer(interrupted)
        } else {
            pill.state = .idle
        }
    }

    /// A click-started action has no key release to end it; never listen longer than this.
    static let maxListenDuration: Duration = .seconds(30)
    /// A hands-free listening that nobody ends stops by itself after this, and the pill says so,
    /// so an accidental double tap never leaves the microphone open. It discards rather than
    /// sends: nothing runs that nobody asked for.
    static let handsFreeListenLimit: Duration = .seconds(20)

    /// A new utterance starts: whatever was still working for an older one no longer owns the pill.
    func supersedePresentation() { utteranceEpoch &+= 1 }

    /// The real extractor, or the test seam.
    func runExtraction(_ transcript: String) async -> ActionExtractor.Output {
        if let extract { return await extract(transcript, .current()) }
        return await extractor.extract(transcript, context: .current())
    }

    /// `chordHeld`: fn + control started this and is still down, so letting go sends it and the pill
    /// draws no buttons. A click on the pill's ⚡ and a double tap hold nothing: the pill carries ✕ and ✓.
    private func begin(handsFree: Bool = false, chordHeld: Bool = false) {
        guard startedAt == nil else { return }
        guard canBeginRecording?() ?? true else { return }
        settleRefunds()
        guard modelStatus.isReady else {
            pill.state = .error(modelStatus.label)
            return
        }
        guard AVAuthorization.microphoneGranted else {
            pill.state = .error("Microphone access needed")
            return
        }
        supersedePresentation()
        extractor.prewarm()
        answerer.prewarm()
        pill.resetLevels()
        let now = Date()
        startedAt = now
        handsFreeSession = handsFree
        pill.actionCancelKey = handsFree ? hotkeys.trigger.keyCap : nil
        pill.actionChordHeld = chordHeld
        prepareMicrophone()
        audio.voiceProcessing = usesVoiceProcessing?() ?? false
        do {
            try audio.start { [weak self] rms in
                Task { @MainActor in self?.pill.push(rms: rms) }
            }
        } catch {
            log.error("action mic start failed: \(error.localizedDescription)")
            pill.present(failure: .didNotStart(PillModel.microphoneFailedMessage))
            startedAt = nil
            pill.actionChordHeld = false
            return
        }
        // A chord held while the answer card is open is a follow-up: the card stays and glows.
        if case .answer(var card) = pill.state, !card.isThinking {
            interruptedAnswer = card
            card.phase = .listening
            pill.state = .answer(card)
        } else {
            interruptedAnswer = nil
            pill.state = .actionListening
        }
        maxListenTask?.cancel()
        maxListenTask = Task { [weak self] in
            try? await Task.sleep(for: handsFree ? Self.handsFreeListenLimit : Self.maxListenDuration)
            guard !Task.isCancelled else { return }
            if handsFree { self?.timeOutListening() } else { self?.stopListening() }
        }
    }

    /// The hands-free limit ran out: stop the microphone, send nothing, and say so. A follow-up
    /// on an open answer card just goes back to the card.
    func timeOutListening() {
        guard isHandsFreeListening else { return }
        let hadCard = interruptedAnswer != nil
        discardListening()
        if !hadCard { pill.state = .error("Stopped listening") }
    }

    /// Test seam: a listening session without a microphone, so the hands-free rules can be
    /// checked without audio hardware. Not hands-free is the held chord, unless `chordHeld` says
    /// it was started from the pill's ⚡ button.
    func beginListeningForTests(handsFree: Bool, chordHeld: Bool? = nil) {
        startedAt = Date()
        handsFreeSession = handsFree
        pill.actionCancelKey = handsFree ? hotkeys.trigger.keyCap : nil
        pill.actionChordHeld = chordHeld ?? !handsFree
        pill.state = .actionListening
    }

    private func finish() {
        guard let start = startedAt else { return }
        maxListenTask?.cancel()
        startedAt = nil
        pill.actionCancelKey = nil
        pill.actionChordHeld = false
        let samples = audio.stop()
        // A very short hold (accidental tap) isn't worth a model round trip.
        guard Date().timeIntervalSince(start) >= 0.3, !samples.isEmpty else {
            discardShortHold()
            return
        }
        let followUp = interruptedAnswer
        interruptedAnswer = nil
        if let followUp {
            var card = followUp
            card.phase = .thinking
            pill.state = .answer(card)
        } else {
            // Its own state, not dictation's "Hearing": the stop is acknowledged at once, the
            // label says Hushy is working on the action, and esc cancels it (`PillKeyScope`).
            pill.state = .actionProcessing
        }
        isProcessing = true
        processingTask?.cancel()
        processingTask = Task { [weak self] in
            guard let self else { return }
            await process(samples, followUp: followUp)
            guard !Task.isCancelled else { return }
            isProcessing = false
        }
    }

    /// Esc while "Working…": stop before anything is created. Whatever the transcriber or the
    /// model returns afterwards is dropped (`process` checks for cancellation after each wait).
    func cancelProcessing() {
        guard isProcessing else { return }
        // Once the action has started executing, its own result reports (one event per attempt).
        if executingEpoch != utteranceEpoch { onMetric?(VoiceActionMetricEvent(outcome: .cancelled, failure: nil)) }
        processingTask?.cancel()
        processingTask = nil
        supersedePresentation()
        isProcessing = false
        if case .actionProcessing = pill.state { pill.state = .idle }
        if case .answer(let card) = pill.state, card.isThinking { pill.state = .idle }
    }

    private func discardShortHold() {
        if let interrupted = interruptedAnswer {
            interruptedAnswer = nil
            pill.state = .answer(interrupted)
        } else {
            pill.state = .idle
        }
    }

    func process(_ samples: [Float], followUp: AnswerCardState?) async {
        let epoch = utteranceEpoch
        let transcript: String
        do {
            if let transcribeSamples {
                transcript = try await transcribeSamples(samples)
            } else {
                transcript = try await speech.transcribe(samples)
            }
        } catch {
            // Dropped when cancelled or when a newer utterance owns the pill now.
            guard !Task.isCancelled, epoch == utteranceEpoch else { return }
            log.error("action transcription failed: \(error.localizedDescription)")
            pill.state = .error("Couldn't hear that")
            return
        }
        guard !Task.isCancelled, epoch == utteranceEpoch else { return }
        guard !transcript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            pill.state = followUp.map { .answer($0) } ?? .idle
            return
        }
        if let rehearsal {
            pill.state = .idle
            rehearsal(transcript)
            return
        }
        if FeatureFlags.taskHandoff,
           let proposal = await TaskHandoffIntent.propose(transcript) {
            guard !Task.isCancelled, epoch == utteranceEpoch else { return }
            pill.state = .idle
            onHandoffProposed?(proposal)
            return
        }
        guard !Task.isCancelled, epoch == utteranceEpoch else { return }
        // Shapes the rules recognise for sure go first (questions, then open/go to). Anything else
        // is for the model; a rule never decides a sentence is not a command. With the flag off,
        // only the original Do path runs.
        switch FeatureFlags.askActions ? AskRouter.route(transcript) : .none {
        case .askAI(let service, let question):
            await handOff(service: service, question: question, utterance: transcript)
        case .askOwn(let question):
            await askOwn(question, thread: Self.thread(after: followUp))
        case .summarizeScreen(let focus):
            await summarizeScreen(focus: focus, utterance: transcript)
        case .findFile(let request):
            await findFile(request, utterance: transcript)
        case .maybeFile(let question):
            await maybeFindFile(question: question, utterance: transcript, followUp: followUp)
        case .none:
            if let followUp {
                // A follow-up that isn't a question ("add coffee") is a Do in the thread's
                // context; anything else continues the thread as a question.
                await followUpDo(transcript, after: followUp)
            } else if let request = Self.recognisedOpen(transcript) {
                await dispatch(Self.openAction(request, utterance: transcript), utterance: transcript)
            } else {
                await extractAndDispatch(transcript)
            }
        }
    }

    private func extractAndDispatch(_ transcript: String, listHint: String? = nil) async {
        let epoch = utteranceEpoch
        let output = await runExtraction(transcript)
        guard !Task.isCancelled, epoch == utteranceEpoch else { return }
        let outcome = ExtractionOutcome(output.result)
        if let outcome { log.info("\(outcome.logLine, privacy: .public)") }
        switch output.result {
        case .actions(var actions):
            if let listHint {
                for index in actions.indices where actions[index].kind == .createReminder && actions[index].listName == nil {
                    actions[index].listName = listHint
                }
            }
            await dispatch(actions, utterance: transcript)
        case .refused(let refusal):
            // A command Hushy won't carry out (reschedule, a missing or destructive Shortcut):
            // say so rather than pasting the command into the focused app as if it were dictation.
            log.info("voice action refused: \(refusal.reason.rawValue, privacy: .public)")
            pill.state = .error(refusal.message)
        case .notAnAction:
            // The person started a voice action on purpose, so their words never go into the
            // front app as text. Say so plainly, show what was heard, offer another try.
            couldNotAct(transcript, outcome: .notAnAction, message: Self.notUnderstoodLine)
        case .modelUnavailable:
            pill.state = .error("Actions need Apple Intelligence")
        case .rejected:
            couldNotAct(transcript, outcome: outcome ?? .modelError, message: Self.assistantBusyLine)
        }
    }

    static let notUnderstoodLine = "Hushy didn't understand that as an action."
    static let assistantBusyLine = "The assistant was busy. Try again?"

    /// An explicit action that could not be carried out and has nothing to ask: one usage event
    /// by a fixed category, the words heard, and "Try again".
    private func couldNotAct(_ transcript: String, outcome: ExtractionOutcome, message: String) {
        if let metric = outcome.metric { onMetric?(metric) }
        pill.state = .answer(AnswerCardState(
            question: transcript,
            phase: .failure(.init(message: message, suggestion: "Try again", retriesAction: true))))
    }

    /// "Try again" on the failure card: the same words, asked of the extractor again. It goes
    /// through the same task and flag as a first attempt, so Esc cancels it and a second tap finds
    /// the card gone. Only the card that offers it can start it, once.
    func retryAction(_ transcript: String) {
        guard !isProcessing, case .answer(let card) = pill.state, card.question == transcript,
              case .failure(let failure) = card.phase, failure.retriesAction else { return }
        supersedePresentation()
        pill.state = .actionProcessing
        isProcessing = true
        processingTask?.cancel()
        processingTask = Task { [weak self] in
            guard let self else { return }
            await extractAndDispatch(transcript)
            guard !Task.isCancelled else { return }
            isProcessing = false
        }
    }

    // MARK: - Policy: act first, or ask first

    /// One certain Tier-1 action acts now and shows the done chip; everything else is the card.
    func dispatch(_ actions: [ProposedAction], utterance: String) async {
        let setting = FeatureFlags.askActions ? askBeforeDoing() : .always
        switch ActionDispatch.plan(actions, utterance: utterance, setting: setting) {
        case .actNow(let action):
            await actNow(action)
        case .card(let rows):
            guard !rows.isEmpty else {
                pill.state = .idle
                return
            }
            pill.state = .actionConfirm(ActionConfirmationCardState(actions: rows))
        }
    }

    /// Executes at once. A failure turns into the card with the failed row, so the user sees why
    /// and can retry when retrying is safe (or ✕ / esc it; it clears itself after
    /// `PillState.selfDismissDelay`); success is "✓ Added: … · Undo" for `ActionUndoWindow`
    /// seconds, logged with undo. Every outcome is recorded in History: done, failed or uncertain.
    private func actNow(_ action: ProposedAction) async {
        let epoch = utteranceEpoch
        executingEpoch = epoch
        defer { if executingEpoch == epoch { executingEpoch = nil } }
        do {
            let result = try await executor.execute(action)
            if executingEpoch == epoch { executingEpoch = nil }
            let record = recordHistory(action, undoToken: result.undoToken, placedIn: result.placedIn)
            countUse(.action, recordID: record?.id)
            if result.undoToken != nil { scheduleUndoExpiry(recordID: record?.id) }
            onMetric?(VoiceActionMetricEvent(outcome: .succeeded, failure: nil))
            // A newer utterance owns the pill now: the action is done and recorded, the chip is not shown.
            guard epoch == utteranceEpoch else { return }
            pill.state = .actionDone(DoneChipState(
                title: ActionDispatch.doneTitle(for: action), detail: Self.detail(for: action, placedIn: result.placedIn),
                kind: action.kind, undoRecordID: result.undoToken == nil ? nil : record?.id))
        } catch {
            // A "Did you mean…" choice is not a failure and reports nothing.
            if let choice = (error as? ActionExecutionError).flatMap({ Self.choiceCard(for: $0, action: action) }) {
                guard epoch == utteranceEpoch else { return }
                pill.state = .actionConfirm(choice)
                return
            }
            // The card for it: one row carrying the plain line, with Retry only when nothing
            // happened and repeating can work. The attempt goes in History.
            var card = ActionConfirmationCardState(actions: [action])
            card.rows[0].refuse(error, recordID: recordFailure(of: action, error: error)?.id)
            let isShown = epoch == utteranceEpoch
            // A question that is shown reports once, when it is settled (`reportUnansweredOffers`).
            if !isShown || !card.waitsOnOffer { reportFailure(error) }
            guard isShown else { return }
            pill.state = .actionConfirm(card)
        }
    }

    /// The done chip's Undo: really reverts (deletes the reminder or event). The chip reads
    /// "Undoing…" while it runs and "Undone" only once the item is gone; if the delete fails it
    /// says so and the record stays not undone.
    func undoDone() {
        guard case .actionDone(var chip) = pill.state, let recordID = chip.undoRecordID, chip.canUndo else { return }
        chip.isUndoing = true
        chip.undoFailure = nil
        pill.state = .actionDone(chip)
        Task {
            let outcome = await performUndo(recordID: recordID)
            // The chip may have gone (esc, a new action) while the delete ran; the record is
            // already updated either way.
            guard case .actionDone(var current) = pill.state, current.undoRecordID == recordID else { return }
            current.isUndoing = false
            switch outcome {
            case .undone: current.undone = true
            case .removedNotRecorded:
                current.undoRecordID = nil
                current.undoFailure = ActionWording.undoNotRecorded
            case .failed(let line): current.undoFailure = line
            case .unavailable:
                current.undoRecordID = nil
                current.undoFailure = "Undo is no longer available."
            }
            pill.state = .actionDone(current)
        }
    }

    /// The `.openLink` action for an open request. The app's name travels in `appName`, never in
    /// the title: "Open Chrome" is what the card says, "Chrome" is what gets looked up. An AI
    /// service opens its Mac app when installed and its site otherwise (`ActionExecutor`).
    /// The open request the rules are sure of. `OpenCommandParser` takes any "open", "start" or
    /// "show" sentence and makes an app name of the rest; a name that resembles no app on this Mac
    /// is not a recognised command (it may be "start a timer for five minutes"), so it is nil and
    /// the sentence goes to the model like any other. A rule may say yes, never "couldn't find".
    static func recognisedOpen(_ transcript: String) -> OpenRequest? {
        guard let request = OpenCommandParser.parse(transcript, context: .current()) else { return nil }
        guard case .app(let name) = request else { return request }
        return WorkspaceLinkBackend.recognisesApp(heard: name) ? request : nil
    }

    static func openAction(_ request: OpenRequest, utterance: String) -> [ProposedAction] {
        switch request {
        case .app(let name):
            return [ProposedAction(kind: .openLink, title: "Open \(name)", appName: name, sourceText: utterance)]
        case .aiService(let service):
            return [ProposedAction(
                kind: .openLink, title: "Open \(service.displayName)", appName: service.displayName,
                url: service.homeURL.absoluteString, sourceText: utterance)]
        case .link(let link):
            return [ProposedAction(kind: .openLink, title: link.summary, url: link.url.absoluteString, sourceText: utterance)]
        }
    }

    /// The done chip's second line: when (an event's length too), where it landed when Hushy
    /// chose the place (the default calendar or list, the default browser), the host, or nothing.
    /// Nothing Hushy filled in is left off the chip.
    static func detail(for action: ProposedAction) -> String? { detail(for: action, placedIn: nil) }

    static func detail(for action: ProposedAction, placedIn: String?) -> String? {
        let parts: [String?]
        switch action.kind {
        case .createEvent, .createReminder:
            parts = [ActionDisplay.whenText(for: action), placedIn]
        case .runShortcut:
            parts = []
        case .openLink:
            // A link shows its site. An app shows nothing more: the title already names it.
            parts = [action.url.flatMap { URL(string: $0)?.host }, placedIn]
        }
        let line = parts.compactMap { $0 }.joined(separator: " \u{00B7} ")
        return line.isEmpty ? nil : line
    }

    /// Voice-actions.md §2.3's "Foundation Models unavailable/refused: fall back silently to
    /// plain dictation of the utterance" — reuses the same paste path `DictationController` uses
    /// so the fallback behaves identically to an ordinary dictation from the user's perspective,
    /// with only a brief distinguishing notice in the pill.
    func fallbackToDictation(_ transcript: String) {
        let epoch = utteranceEpoch
        let insert = insertFallbackText
        let target = insert == nil ? FocusTarget.current() : nil
        Task {
            // Keep the success notice tied to the actual paste outcome.
            let outcome: TextInserter.InsertOutcome
            if let insert {
                await insert(transcript)
                outcome = .pasted
            } else if let target {
                outcome = await TextInserter.insert(transcript, into: target)
            } else {
                outcome = .focusChanged
            }
            await MainActor.run {
                // An older fallback finishing late must not cover a newer card.
                guard epoch == self.utteranceEpoch else { return }
                self.pill.state = Self.fallbackState(for: outcome, words: TextStats.wordCount(transcript))
            }
        }
    }

    static func fallbackState(for outcome: TextInserter.InsertOutcome, words: Int) -> PillState {
        switch outcome {
        case .pasted, .pastedReturnSkipped: .done(words: words)
        case .focusChanged, .dispatchFailed: .error("Couldn't paste here")
        }
    }

    // MARK: - Confirmation card actions (called by the pill's UI)

    func confirm(_ row: ActionConfirmationRow, in card: ActionConfirmationCardState) {
        guard case .actionConfirm(var current) = pill.state,
              let index = current.rows.firstIndex(where: { $0.id == row.id }),
              // Never again after a run that may have happened, never after a refusal, never
              // twice at once: only a pending or plainly failed row goes to the executor.
              current.rows[index].status.canRunAgain else { return }
        current.rows[index].status = .confirming
        pill.state = .actionConfirm(current)
        Task { await execute(rowID: row.id) }
    }

    func cancel(_ row: ActionConfirmationRow) {
        guard case .actionConfirm(var current) = pill.state,
              let index = current.rows.firstIndex(where: { $0.id == row.id }) else { return }
        let wasPending = current.rows[index].status == .pending
        current.rows[index].status = .cancelled
        current.rows[index].offer = nil
        // Only a row still waiting is a cancelled attempt. One that already failed (or is running,
        // or was refused) has reported, or will report, its own event: a question dismissed here
        // reports its refusal as the card changes (`reportUnansweredOffers`). An alternative that
        // was not picked ("Did you mean…") was never an attempt.
        if wasPending, !current.isChoice { onMetric?(VoiceActionMetricEvent(outcome: .cancelled, failure: nil)) }
        pill.state = current.allResolved ? .idle : .actionConfirm(current)
    }

    /// Return: confirm every still-pending row at once (brief: "Return = confirm all").
    func confirmAll() {
        guard case .actionConfirm(let current) = pill.state else { return }
        if let offered = current.soleOfferRow { return acceptOffer(offered) }
        // A "Did you mean…" card holds alternatives: Return opens the closest one only.
        for row in current.rowsToConfirmWithReturn {
            confirm(row, in: current)
        }
    }

    /// Esc: cancel the whole card without executing anything.
    func cancelAll() {
        guard case .actionConfirm(let current) = pill.state else { return }
        for row in current.rows where row.status == .pending && !current.isChoice {
            onMetric?(VoiceActionMetricEvent(outcome: .cancelled, failure: nil))
        }
        pill.state = .idle
    }

    func update(_ action: ProposedAction) {
        guard case .actionConfirm(var current) = pill.state,
              let index = current.rows.firstIndex(where: { $0.id == action.id }) else { return }
        current.rows[index].action = action
        pill.state = .actionConfirm(current)
    }

    /// Runs one confirmed row. The result is recorded in History whatever the card looks like by
    /// then (it may have been dismissed while this ran): the effect happened or it didn't.
    func execute(rowID: UUID) async {
        guard case .actionConfirm(let started) = pill.state,
              let startIndex = started.rows.firstIndex(where: { $0.id == rowID }),
              started.rows[startIndex].status == .confirming else { return }
        let action = started.rows[startIndex].action
        let replaced = started.rows[startIndex].recoveryRecordID
        let result: ActionExecutionResult
        do {
            result = try await executor.execute(action)
        } catch {
            finishFailed(rowID: rowID, action: action, error: error, replacing: replaced)
            return
        }
        let record = recordHistory(action, undoToken: result.undoToken, placedIn: result.placedIn, replacing: replaced)
        onMetric?(VoiceActionMetricEvent(outcome: .succeeded, failure: nil))
        // Read the card again: other rows may have finished while this one ran.
        var firstUse = true
        if case .actionConfirm(var current) = pill.state, let index = current.rows.firstIndex(where: { $0.id == rowID }) {
            current.rows[index].status = .succeeded(undoToken: result.undoToken)
            current.rows[index].placedIn = result.placedIn
            current.settleChoice(afterOpening: rowID)
            if current.allResolved, current.rows.count == 1 {
                // One confirmed action ends as the done chip, like an act-first one: it names the
                // defaults Hushy chose and carries Undo.
                pill.state = .actionDone(DoneChipState(
                    title: ActionDispatch.doneTitle(for: action), detail: Self.detail(for: action, placedIn: result.placedIn),
                    kind: action.kind, undoRecordID: result.undoToken == nil ? nil : record?.id))
            } else {
                pill.state = current.allResolved ? .idle : .actionConfirm(current)
            }
            // A confirmed card is one chord use, however many rows the user ticks.
            firstUse = current.rows.count(where: { if case .succeeded = $0.status { true } else { false } }) == 1
        }
        if firstUse { countUse(.action, recordID: record?.id) }
        if result.undoToken != nil {
            scheduleUndoExpiry(recordID: record?.id)
        }
    }

    /// A row that didn't go through: the card says why in one line, offers Retry only when nothing
    /// happened and repeating can work, and the attempt goes in History.
    private func finishFailed(rowID: UUID, action: ProposedAction, error: Error, replacing replaced: Int64?) {
        guard case .actionConfirm(var current) = pill.state,
              let index = current.rows.firstIndex(where: { $0.id == rowID }) else {
            recordFailure(of: action, error: error, replacing: replaced)
            reportFailure(error)
            return
        }
        if current.rows.count == 1, let choice = (error as? ActionExecutionError).flatMap({ Self.choiceCard(for: $0, action: action) }) {
            pill.state = .actionConfirm(choice)
            return
        }
        current.rows[index].refuse(error, recordID: recordFailure(of: action, error: error, replacing: replaced)?.id)
        // A refusal that asks a question reports once, when it is settled (`reportUnansweredOffers`).
        if current.rows[index].openOffer == nil { reportFailure(error) }
        pill.state = .actionConfirm(current)
    }

    /// One usage event for an attempt that did not complete, by a fixed category: never the error's
    /// message, which can name a calendar, list, Shortcut or app. A Shortcut that may have run is
    /// not a success, so it counts as failed (timed out, or the backend's category).
    private func reportFailure(_ error: Error) {
        let category = (error as? ActionExecutionError).map(VoiceActionFailureCategory.init) ?? .other
        onMetric?(VoiceActionMetricEvent(outcome: .failed, failure: category))
    }

    /// What a row becomes when the executor threw: a plain failure (Retry), a run that may have
    /// happened (no Retry) or a refusal for something missing (no Retry).
    static func rowStatus(for error: Error) -> ActionConfirmationRow.RowStatus {
        guard let error = error as? ActionExecutionError else { return .failed(error.localizedDescription) }
        let line = ActionWording.line(for: error)
        switch error.failureKind {
        case .failed: return .failed(line)
        case .uncertain: return .uncertain(line)
        case .blocked: return .blocked(line)
        }
    }


    /// "Did you mean…": when no app matched for sure but a few are close, the card offers them in
    /// place of a dead end. Nil for every other failure.
    static func choiceCard(for error: ActionExecutionError, action: ProposedAction) -> ActionConfirmationCardState? {
        guard case .closestApps(let heard, let apps) = error, !apps.isEmpty else { return nil }
        return ActionConfirmationCardState(choosingAmong: apps, heard: heard, sourceText: action.sourceText)
    }

    /// `replaced`: the refused attempt this result recovers (`acceptOffer`), written over so History keeps one row.
    @discardableResult
    private func recordHistory(
        _ action: ProposedAction, undoToken: ActionUndoToken?, status: ActionRecord.Status = .completed,
        placedIn: String? = nil, replacing replaced: Int64? = nil
    ) -> ActionRecord? {
        // A done action keeps what it always kept, and where it landed when Hushy chose the place.
        // A failed or uncertain attempt keeps only the title, the kind and the date line: not the
        // words that were spoken, which a done action's card already showed the person.
        let isDone = status == .completed
        let historyTitle = isDone && action.kind == .openLink && ActionPolicy.actionClass(of: action) == .aiHandoff
            ? ActionDispatch.doneTitle(for: action) : action.title
        let record = ActionRecord(
            id: replaced, kind: action.kind, title: historyTitle, detail: Self.historyDetail(for: action, placedIn: placedIn),
            sourceText: isDone ? action.sourceText : "", status: status, undoBackendID: undoToken?.backendID)
        return writeHistory(record)
    }

    /// Records an attempt that did not complete: `failed` when nothing happened, `uncertain` when it
    /// may have. Only the title, the kind and the date line; never the reason or the spoken words,
    /// which can carry names the person did not see. A "Did you mean…" prompt is not an
    /// attempt and is not recorded. Never counted against the Free allowance.
    @discardableResult
    private func recordFailure(of action: ProposedAction, error: Error, replacing replaced: Int64? = nil) -> ActionRecord? {
        if case ActionExecutionError.closestApps? = error as? ActionExecutionError { return nil }
        let kind = (error as? ActionExecutionError)?.failureKind ?? .failed
        // Only fixed vocabulary. Error payloads can contain private text or target names.
        let reason = (error as? ActionExecutionError)?.logStepAndReason ?? "execution: unknown failure"
        log.error("action failed: \(reason, privacy: .public)")
        return recordHistory(action, undoToken: nil, status: kind == .uncertain ? .uncertain : .failed, replacing: replaced)
    }

    // MARK: - Actions confirmed elsewhere (the Assistant chat's cards)

    /// Executes an action the user just confirmed on an Assistant chat card, through the same
    /// executor and History record as a voice action. Callers gate on `isEntitled()` first; this
    /// checks again so no path can execute an action without it.
    func executeConfirmed(_ action: ProposedAction) async -> Result<ActionRecord, ActionExecutionFailure> {
        guard isEntitled() else { return .failure(ActionExecutionFailure(message: "Actions are turned off")) }
        do {
            let result = try await executor.execute(action)
            // It ran: a success for the usage numbers, whether or not History could save the note.
            onMetric?(VoiceActionMetricEvent(outcome: .succeeded, failure: nil))
            guard let record = recordHistory(action, undoToken: result.undoToken, placedIn: result.placedIn) else {
                // It ran. Only the History note is missing, so it is never offered as a retry.
                return .failure(ActionExecutionFailure(
                    message: ActionWording.notRecorded, kind: .uncertain, didRun: true))
            }
            return .success(record)
        } catch {
            recordFailure(of: action, error: error)
            reportFailure(error)
            let kind = (error as? ActionExecutionError)?.failureKind ?? .failed
            let line = (error as? ActionExecutionError).map(ActionWording.line(for:)) ?? error.localizedDescription
            return .failure(ActionExecutionFailure(message: line, kind: kind))
        }
    }

    /// Undoes an action by its History record id (the Assistant card's Undo, the done chip).
    /// True only when the item is really gone.
    func undo(recordID: Int64) async -> Bool {
        if case .undone = await performUndo(recordID: recordID) { return true }
        return false
    }

    /// What an Undo did: removed the item, couldn't (with the plain line), or isn't offered.
    enum UndoOutcome: Equatable {
        case undone
        /// The item is gone, but Hushy could not update its History record. Not shown as plain
        /// "Undone": the record may still offer an Undo that no longer has anything to remove.
        case removedNotRecorded
        case failed(String)
        case unavailable
    }

    /// Records being undone right now, so a second tap can't delete twice.
    @ObservationIgnored private var undoing: Set<Int64> = []

    /// Deletes the item and updates the record, in that order: "undone" is written only after the
    /// delete succeeded. A failed delete leaves the record completed with its undo token (so Undo
    /// can be tried again while it is offered) and marks the failure for History. An item that is
    /// already gone (deleted by hand) counts as undone: it is not there any more.
    func performUndo(recordID: Int64) async -> UndoOutcome {
        settleRefunds()
        guard let record = try? store.actionRecord(id: recordID), record.status == .completed,
              let backendID = record.undoBackendID, !undoing.contains(recordID) else { return .unavailable }
        undoing.insert(recordID)
        defer { undoing.remove(recordID) }
        // Removed earlier, only the record write failed: settle the record, do not delete again.
        if !undoneUnrecorded.contains(recordID) {
            do {
                try await executor.undo(ActionUndoToken(backendID: backendID), kind: record.kind)
            } catch ActionExecutionError.notFound {
                // Already gone: nothing left to delete.
            } catch {
                log.error("undo failed")
                do { try (writeUndoFailed ?? { try self.store.markActionUndoFailed(id: $0) })(recordID) } catch {
                    log.error("history write failed: the undo-failed mark")
                }
                return .failed(ActionWording.undoFailed(for: record.kind))
            }
        }
        // The item is gone, so its monthly use goes back whatever happens to the record below.
        // That write is its own: it never changes what the person is told about History.
        refundsPending.insert(recordID)
        settleRefunds()
        do {
            try (writeUndone ?? { try self.store.markActionUndone(id: $0) })(recordID)
            undoneUnrecorded.remove(recordID)
            return .undone
        } catch {
            log.error("history write failed: the undone mark")
        }
        // The item is gone but the record still says it can be undone. Take the stored token away
        // so History stops offering an Undo with nothing to remove; if even that fails, remember
        // it and settle on the next attempt.
        do {
            try (writeUndoExpired ?? { try self.store.expireActionUndo(id: $0) })(recordID)
            undoneUnrecorded.remove(recordID)
        } catch {
            undoneUnrecorded.insert(recordID)
        }
        return .removedNotRecorded
    }

    /// Gives back the monthly use of every Undone item whose refund has not landed. A failure is
    /// logged without any name and tried again next time.
    func settleRefunds() {
        // After a quit the in-memory list is gone: the store itself knows which uses belong to
        // records already marked undone.
        if needsRefundReconcile {
            do {
                try store.reconcileVoiceActionRefunds()
                needsRefundReconcile = false
            } catch {
                log.error("store write failed: reconciling monthly uses")
            }
        }
        for id in refundsPending {
            do {
                try (refundUse ?? { try self.store.markVoiceActionUseUndone(actionRecordID: $0) })(id)
                refundsPending.remove(id)
            } catch {
                log.error("store write failed: giving back a monthly use")
            }
        }
    }

    /// Undo affordance expires after `undoWindow`: the record's `undoBackendID` is cleared
    /// so History stops offering "Undo" for it (the confirmation-card row itself is already
    /// gone by then) — the actual "Undo" tap target lives in the success toast UI, which
    /// independently disables itself on the same timer.
    private func scheduleUndoExpiry(recordID: Int64?) {
        undoTimer?.cancel()
        undoTimer = Task { @MainActor [undoWindow, weak self] in
            try? await Task.sleep(for: .seconds(undoWindow))
            guard !Task.isCancelled else { return }
            if let recordID {
                do {
                    try self?.store.expireActionUndo(id: recordID)
                } catch {
                    self?.log.error("history write failed: the undo expiry")
                }
            }
        }
    }

    /// Called by the shared timeline's "Undo" link on a History/Home action row. Reconstructs
    /// the token from the persisted `ActionRecord` rather than requiring the in-memory
    /// `ActionUndoToken` from the original toast, since the row may be tapped well after that
    /// toast — and its own session — is gone. Only offered while `record.undoBackendID` is
    /// still set (cleared by `markActionUndone`), so a record that's already been undone, or
    /// whose backend never supports undo (Shortcuts), never shows the link in the first place.
    /// A failure is written on the record, and History shows it.
    func undo(record: ActionRecord) async {
        guard let recordID = record.id else { return }
        _ = await performUndo(recordID: recordID)
    }

    // MARK: - Use counting (dormant)

    /// Counts one chord use that did something (`VoiceActionUse`) when the entitlement is off.
    /// Voice actions are free (founder, 2026-11-11), so nothing is counted and nothing is ever
    /// shown; the count stays only until the paywall plumbing is deleted after Product Hunt.
    func countUse(_ kind: VoiceActionUse.Kind, recordID: Int64? = nil) {
        settleRefunds()
        guard !isEntitled() else { return }
        do {
            try store.recordVoiceActionUse(VoiceActionUse(kind: kind, actionRecordID: recordID))
        } catch {
            log.error("store write failed: counting a monthly use")
        }
    }

    static func historyDetail(for action: ProposedAction, placedIn: String? = nil) -> String {
        let base: String
        switch action.kind {
        case .createEvent, .createReminder:
            if let start = action.start {
                base = DateFormatter.localizedString(from: start, dateStyle: .medium, timeStyle: .short)
            } else {
                base = "No date set"
            }
        case .runShortcut:
            base = "Shortcut: \(action.shortcutName ?? action.title)"
        case .openLink:
            base = action.url.flatMap { URL(string: $0)?.host } ?? action.appName ?? "App"
        }
        guard let placedIn, !placedIn.isEmpty else { return base }
        return "\(base) \u{00B7} \(placedIn)"
    }

    static func message(for error: ActionExecutionError) -> String {
        ActionWording.line(for: error)
    }
}
