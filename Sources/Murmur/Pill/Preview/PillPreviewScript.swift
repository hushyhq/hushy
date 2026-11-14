import Foundation
import MurmurCore

/// The pill preview's script: every pill state and the changes between them, as data. No
/// microphone, no recogniser, no model and no clipboard are involved; every word in it is
/// invented here. `PillPreviewRunner` plays it on the real pill.
struct PillPreviewStep: Equatable {
    /// What the control window says is happening, in plain words.
    var caption: String
    var state: PillState
    /// How long the step stays at normal speed.
    var hold: Duration
    /// What the invented microphone does during the step.
    var voice: PillPreviewVoice = .none
    /// Invented words behind a card or a held row (`PillModel.present(_:text:)`).
    var text: String?
    /// Invented progress reports during a wait: which sentence group finished, and when.
    var progress: [PillPreviewProgress] = []
}

/// One invented "sentence group finished" report: `done` of `count` groups, `at` seconds into the step.
struct PillPreviewProgress: Equatable {
    var at: TimeInterval
    var done: Int
    var count: Int
}

/// The invented microphone. Levels are a fixed function of time, so a preview looks the same every run.
enum PillPreviewVoice: Equatable {
    /// The mic is not open.
    case none
    /// Open, nobody speaking: room noise only.
    case silence
    /// Open, a person speaking in phrases with short pauses.
    case speech

    /// The level (RMS, as the real microphone reports it) `time` seconds into the step.
    func rms(at time: TimeInterval) -> Float {
        switch self {
        case .none: return 0
        case .silence: return 0.0012
        case .speech:
            // Phrases of about two seconds with a breath between them; syllables at about four a second.
            let inPhrase = time.truncatingRemainder(dividingBy: 2.6) < 2.1
            guard inPhrase else { return 0.0015 }
            let syllable = abs(sin(time * 2 * .pi * 2.05))
            let stress = 0.65 + 0.35 * sin(time * 2 * .pi * 0.7)
            return Float(0.004 + 0.05 * syllable * stress)
        }
    }
}

/// One short story the pill tells. The reel is all of them in this order.
enum PillPreviewScene: String, CaseIterable, Identifiable, Sendable {
    case quick
    case longWait
    case stall
    case handsFree
    case tooShort
    case cancelled
    case notPasted
    case pastedUnchecked
    case password
    case heardNothing
    case failed
    case micError
    case voiceAction
    case voiceActionCards
    case answer
    case note
    case nameOffer
    case voiceEdit
    case restyle

    var id: String { rawValue }

    var title: String {
        switch self {
        case .quick: "A quick dictation"
        case .longWait: "A longer wait"
        case .stall: "A wait that stalls on one sentence"
        case .handsFree: "Hands-free"
        case .tooShort: "A tap too short to count"
        case .cancelled: "Cancelled with esc"
        case .notPasted: "Not pasted: the card"
        case .pastedUnchecked: "Pasted, but the field could not be read"
        case .password: "A password field"
        case .heardNothing: "Nothing heard"
        case .failed: "Could not transcribe"
        case .micError: "The mic did not start"
        case .voiceAction: "A voice action"
        case .voiceActionCards: "A voice action to confirm"
        case .answer: "An answer card"
        case .note: "Recording a note"
        case .nameOffer: "A new name Hushy was unsure of"
        case .voiceEdit: "Editing selected text by voice"
        case .restyle: "Restyling selected text with the shortcut"
        }
    }
}

/// Which case of `PillState` a state is. The switch below has no default on purpose: a state added
/// to the pill stops this file compiling until the preview shows it.
enum PillStateKind: String, CaseIterable, Sendable {
    case idle, listening, handsFree, processing, done, copied, held, error, failed, recordingNote
    case actionListening, actionProcessing, actionConfirm, answer, actionDone, noField, pastedUnchecked, nameOffer
    case voiceEdit, restyle

    init(_ state: PillState) {
        switch state {
        case .idle: self = .idle
        case .listening: self = .listening
        case .handsFree: self = .handsFree
        case .processing: self = .processing
        case .done: self = .done
        case .copied: self = .copied
        case .held: self = .held
        case .error: self = .error
        case .failed: self = .failed
        case .recordingNote: self = .recordingNote
        case .actionListening: self = .actionListening
        case .actionProcessing: self = .actionProcessing
        case .actionConfirm: self = .actionConfirm
        case .answer: self = .answer
        case .actionDone: self = .actionDone
        case .noField: self = .noField
        case .pastedUnchecked: self = .pastedUnchecked
        case .nameOffer: self = .nameOffer
        case .voiceEdit: self = .voiceEdit
        case .restyle: self = .restyle
        }
    }
}

@MainActor
enum PillPreviewScript {
    /// Every scene, in order.
    static let reel = PillPreviewScene.allCases

    /// The invented dictation behind the cards. Nothing here was ever spoken by anyone.
    static let inventedShort = "Lunch on Thursday works for me."
    static let inventedName = "Pria"
    static let inventedLong = """
        Thanks for sending the draft. I read it on the train this morning and I think the second \
        section is the strongest part. Could we move the pricing table up, and cut the last \
        paragraph? I can go through it again on Friday if that helps.
        """

    /// The rest between scenes, so one story ends before the next begins.
    static let rest = PillPreviewStep(caption: "At rest. Hover it to see the two buttons.", state: .idle, hold: .milliseconds(900))

    /// States that carry a start time are written with this placeholder and stamped when played.
    static let placeholder = Date.distantPast

    /// The same state with its start time set to `now` (hands-free and note timers count from it).
    static func stamped(_ state: PillState, now: Date) -> PillState {
        switch state {
        case .handsFree: .handsFree(startedAt: now)
        case .recordingNote: .recordingNote(startedAt: now)
        default: state
        }
    }

    static func steps(for scene: PillPreviewScene) -> [PillPreviewStep] {
        switch scene {
        case .quick:
            return [
                step("Key down. Speaking.", .listening, 2.2, voice: .speech),
                step("Key up. A short wait: about two in three dictations.", .processing(), 0.2),
                step("Pasted.", .done(words: 6), 0.7),
            ]
        case .longWait:
            return [
                step("Key down, then a moment of silence.", .listening, 0.9, voice: .silence),
                step("Speaking for a while.", .listening, 5.2, voice: .speech),
                step("Key up. A wait of a second and a half, three sentence groups: the line shows how far it has got.",
                     .processing(), 1.5, progress: groups(3, at: [0.35, 0.7, 1.1, 1.4])),
                step("Pasted, with the word count a long result gets.", .done(words: 58), 0.9),
            ]
        case .stall:
            return [
                step("Speaking.", .listening, 4.2, voice: .speech),
                step("Key up. The second of four sentence groups takes five seconds: the line stops where the truth is and the dots breathe.",
                     .processing(), 6.2, progress: groups(4, at: [0.4, 0.7, 5.6, 5.9, 6.1])),
                step("Pasted.", .done(words: 66), 0.9),
            ]
        case .handsFree:
            return [
                step("A double tap: hands-free, with cancel and done.", .handsFree(startedAt: placeholder), 4.6, voice: .speech),
                step("Done pressed.", .processing(), 0.6),
                step("Pasted as heard: the model did not answer in time.", .done(words: 31, asHeard: true), 1.4),
            ]
        case .tooShort:
            return [step("Key down and straight back up. Nothing is kept.", .listening, 0.18, voice: .silence)]
        case .cancelled:
            return [
                step("Speaking.", .listening, 1.6, voice: .speech),
                step("Key up.", .processing(), 0.5),
                step("Esc. The pill leaves without a tick.", .idle, 0.6),
            ]
        case .notPasted:
            return [
                step("Speaking.", .listening, 2.0, voice: .speech),
                step("Key up.", .processing(), 0.4),
                step("Focus moved, so nothing was pasted. The card shows the words.",
                     .noField(.notPasted(.targetChanged(.app))), 4.0, text: inventedLong),
                step("Copy again pressed.", .noField(.notPastedCopiedAgain(.targetChanged(.app))), 1.2, text: inventedLong),
                step("Return was withheld because focus moved just before it.", .done(words: 6, notSent: true), 2.2),
                step("The one-line copied row.", .copied(reason: .pasteFailed), 2.4),
            ]
        case .pastedUnchecked:
            return [
                step("Speaking.", .listening, 1.8, voice: .speech),
                step("Key up.", .processing(), 0.4),
                step("Pasted, but this app's field cannot be read back: a grey tick and a way to see the words.",
                     .pastedUnchecked, 2.2, text: inventedShort),
                step("The row clicked: the words, and where they are.",
                     .noField(.copiedAutomaticallyUnconfirmed), 3.2, text: inventedShort),
            ]
        case .password:
            return [
                step("Speaking.", .listening, 1.4, voice: .speech),
                step("Key up.", .processing(), 0.3),
                step("A password field has focus. The words are never shown.", .held(copied: false), 3.0, text: inventedShort),
                step("Copy pressed.", .held(copied: true), 1.2),
            ]
        case .heardNothing:
            return [
                step("Key down, nobody speaks.", .listening, 1.6, voice: .silence),
                step("Nothing heard. The row stays until it is dismissed.", .failed(.heardNothing), 3.0),
            ]
        case .failed:
            return [
                step("Speaking.", .listening, 1.6, voice: .speech),
                step("Key up.", .processing(), 0.8),
                step("Recognition failed. The recording is kept, with Try again.", .failed(.transcription(recordingKept: true)), 3.2),
            ]
        case .micError:
            return [step("A short notice with the fix in its words.", .error(PillModel.microphoneFailedMessage), 2.5)]
        case .voiceAction:
            return [
                step("The action chord: listening for an action.", .actionListening, 2.4, voice: .speech),
                step("Working on it.", .actionProcessing, 1.6),
                step("Done, with Undo.", .actionDone(DoneChipState(title: "Added: Call Dana", detail: "Fri 9:00 AM",
                                                                   kind: .createReminder, undoRecordID: 1)), 2.6),
            ]
        case .voiceActionCards:
            let actions = sampleActions
            return [
                step("One action to confirm: the pill itself.", .actionConfirm(ActionConfirmationCardState(actions: [actions[0]])), 2.8),
                step("Three: rows stacked on the capsule.", .actionConfirm(ActionConfirmationCardState(actions: actions)), 3.4),
                step("Working on one that names a list.", .actionProcessing, 1.0),
                step("That list is not there: the pill asks, with a cross and a tick.", .actionConfirm(missingListQuestion), 3.6),
            ]
        case .answer:
            let question = "what groceries do i need this weekend"
            let groceries = AnswerCardState.AnswerContent(
                text: "You need four things this weekend.", items: ["oat milk", "eggs", "sourdough", "coffee beans"],
                sourceLabel: "From your note 'Groceries' · Sep 26", sourceLink: .note(id: 1))
            return [
                step("A question about your own notes: thinking.", .answer(AnswerCardState(question: question, phase: .thinking)), 1.8),
                step("The answer, with where it came from.", .answer(AnswerCardState(question: question, phase: .answer(groceries))), 3.6),
            ]
        case .note:
            return [step("A note being recorded.", .recordingNote(startedAt: placeholder), 3.6, voice: .speech)]
        case .nameOffer:
            return [
                step("Speaking, with a name in it.", .listening, 1.8, voice: .speech),
                step("Key up.", .processing(), 0.4),
                step("Pasted, and a name Hushy was unsure of is offered for the Dictionary.",
                     .nameOffer(.offered, words: 6), 3.4, text: inventedName),
            ]
        case .voiceEdit:
            return [
                step("Text selected. Key down: \"make this shorter\".", .listening, 1.6, voice: .speech),
                step("Key up. The selection is being rewritten.", .processing(modeName: VoiceEditController.processingName), 0.9),
                step("Replaced in place. ✕ or esc puts the original back; ✓ keeps it.", .voiceEdit(.edited(canUndo: true)), 2.6),
                step("Put back.", .voiceEdit(.undone), 1.0),
                step("Asked for something the text does not have: nothing changes.", .voiceEdit(.declined(.cannotDo)), 2.0),
            ]
        case .restyle:
            return [
                step("Text selected, shortcut pressed: tone chips and a Copy toggle.", .restyle(RestyleChooser()), 2.4),
                step("A tone is picked. The selection is being rewritten.", .processing(modeName: VoiceEditController.processingName), 0.9),
                step("Replaced in place. ✕ or esc puts the original back.", .voiceEdit(.edited(canUndo: true)), 2.2),
                step("Copy on, or a selection that cannot be replaced: the result is copied.", .voiceEdit(.restyleCopied), 1.6),
                step("The rewrite would have changed a number, a name or a \"not\": the text is kept.", .voiceEdit(.declined(.wouldChangeMeaning)), 2.0),
            ]
        }
    }

    /// Every step of every scene, with the rest between scenes.
    static var allSteps: [PillPreviewStep] {
        reel.flatMap { steps(for: $0) + [rest] }
    }

    private static func step(
        _ caption: String, _ state: PillState, _ seconds: Double, voice: PillPreviewVoice = .none, text: String? = nil,
        progress: [PillPreviewProgress] = []
    ) -> PillPreviewStep {
        PillPreviewStep(caption: caption, state: state, hold: .milliseconds(Int(seconds * 1_000)), voice: voice, text: text,
                        progress: progress)
    }

    /// Reports for a wait of `count` sentence groups: the first time is "nothing done yet", then
    /// one group finishes at each later time.
    private static func groups(_ count: Int, at times: [TimeInterval]) -> [PillPreviewProgress] {
        times.enumerated().map { PillPreviewProgress(at: $1, done: min($0, count), count: count) }
    }

    /// A reminder for a list that does not exist, refused with the offer of the default list.
    static var missingListQuestion: ActionConfirmationCardState {
        var card = ActionConfirmationCardState(actions: [
            ProposedAction(kind: .createReminder, title: "Buy oat milk", listName: "Errands", sourceText: "add oat milk to errands"),
        ])
        card.rows[0].refuse(ActionExecutionError.targetNotFound(.list, "Errands"), recordID: nil)
        return card
    }

    private static var sampleActions: [ProposedAction] {
        let tomorrow = Calendar.current.date(bySettingHour: 15, minute: 0, second: 0, of: Date().addingTimeInterval(86_400)) ?? Date()
        return [
            ProposedAction(kind: .createEvent, title: "Dentist", start: tomorrow, end: tomorrow.addingTimeInterval(3_600),
                           sourceText: "dentist tomorrow at three"),
            ProposedAction(kind: .createReminder, title: "Send Priya the deck", start: tomorrow,
                           sourceText: "remind me to send priya the deck"),
            ProposedAction(kind: .createReminder, title: "Buy oat milk", sourceText: "add oat milk"),
        ]
    }
}
