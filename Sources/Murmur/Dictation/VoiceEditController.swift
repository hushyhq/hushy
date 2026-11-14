import AppKit
import ApplicationServices
import MurmurCore
import os

/// Words spoken over a selection (`FeatureFlags.voiceEdit`): an instruction rewrites the selection in
/// place with the cleanup model (`VoiceEditor`), new text goes back to dictation. Owns the one undo.
///
/// Nothing here is stored: the selection, the instruction and the edit live for one dictation and in
/// `pending` for the undo window. The log line carries counts and outcomes, never text.
@MainActor
final class VoiceEditController {
    enum Handling: Equatable {
        /// Not an instruction: the dictation carries on and pastes over the selection.
        case dictate
        /// Edited, declined or not delivered; the dictation is over.
        case finished(DictationMetricInput.Result)
    }

    /// "Applying your edit…" while the model works (`PillInk`).
    static let processingName = "your edit"

    private struct Pending {
        let undo: VoiceEditUndo
        let location: Int?
        let target: FocusTarget
    }

    /// How the controller reads the focused field and reaches the clipboard and the keys. The edit always goes out
    /// through `TextInserter.deliver`; tests pass a private pasteboard, a key poster that posts nothing, and their own
    /// selection and focus reads.
    struct Field {
        /// The selection in the target's focused field now, as `SelectionReader` reads it at key-down.
        var selection: @MainActor (FocusTarget) -> SelectedText?
        /// Whether focus is still on the target (`FocusTarget.verdict`).
        var focus: @MainActor (FocusTarget) -> TargetVerdict
        /// Stages the edit and sends ⌘V, or leaves the edit on the clipboard.
        var paster: ClipboardPaster
        /// How long ago the person last pressed a key or a mouse button, or dragged.
        var sinceLastInput: @MainActor () -> Duration

        @MainActor static var live: Field { Field(
            selection: { target in
                SelectionReader.read(app: target.processID.flatMap { NSRunningApplication(processIdentifier: $0) })
            },
            focus: { $0.verdict() },
            paster: TextInserter.shared,
            sinceLastInput: {
                let kinds: [CGEventType] = [.keyDown, .leftMouseDown, .leftMouseDragged, .rightMouseDown, .otherMouseDown]
                let seconds = kinds.map { CGEventSource.secondsSinceLastEventType(.hidSystemState, eventType: $0) }.min() ?? .infinity
                return seconds.isFinite ? .seconds(seconds) : .seconds(3_600)
            }) }
    }

    private let model: any LanguageModel
    private let pill: PillModel
    private let field: Field
    private var pending: Pending?
    /// Set when the paster's last look before ⌘V found the selection changed, so the pill says why it copied.
    private var selectionMoved = false
    private var expiry: Task<Void, Never>?
    private let log = Logger(subsystem: "app.hushy", category: "voice-edit")

    init(model: any LanguageModel, pill: PillModel, field: Field = .live) {
        self.model = model
        self.pill = pill
        self.field = field
    }

    func handle(spoken: String, selection: SelectedText, target: FocusTarget, isCancelled: () -> Bool) async -> Handling {
        let started = ContinuousClock.now
        let signals = VoiceEditRouter.signals(spoken: spoken, selection: selection.text)
        if signals.mightBeInstruction { pill.state = .processing(modeName: Self.processingName) }
        let run = await VoiceEditor.run(spoken: spoken, selection: selection, model: model)
        let ms = Int(ModelPace.ms(ContinuousClock.now - started))
        let characters = selection.text.count
        log.notice("voice edit: asked=\(run.trace != nil) kind=\(run.trace?.kind ?? "-", privacy: .public) outcome=\(Self.code(run.outcome), privacy: .public) words=\(signals.words) chars=\(characters) ms=\(ms)")
        if isCancelled() { return .finished(.cancelled) }
        switch run.outcome {
        case .dictation:
            return .dictate
        case .declined(let why):
            pill.state = .voiceEdit(.declined(why))
            return .finished(.failed)
        case .edited(let text):
            return await deliver(text, replacing: selection, target: target, askedAt: started)
        }
    }

    /// A click or key press younger than this may still be on its way to the field: it was not handled when the
    /// selection was read, and it lands before ⌘V. Responsive apps handle input within a frame or two.
    static let inputInFlight: Duration = .milliseconds(250)

    /// ⌘V replaces whatever is selected when the app handles it, and macOS has no "replace only if still this".
    /// So the paste goes out only right after a read shows the same text at the same place, with no click or key
    /// press since the edit was asked for that the field may not have handled yet. A place the field does not report
    /// is never the same place: the person may have selected another copy of the text. The paster asks this again as
    /// its last step before ⌘V, with no wait in between; anything else gets the edit on the clipboard.
    private func stillSelected(_ selection: SelectedText, target: FocusTarget, askedAt: ContinuousClock.Instant) -> Bool {
        guard selection.location != nil else { return false }
        let sinceInput = field.sinceLastInput()
        if sinceInput < min(ContinuousClock.now - askedAt, Self.inputInFlight) { return false }
        return field.selection(target) == selection
    }

    /// Replaces `selection` with `text` the way an edit does, with the same last look before ⌘V, the same copy
    /// when anything moved, and the one undo. Restyle (`RestyleController`) delivers through it too.
    func deliver(
        _ text: String, replacing selection: SelectedText, target: FocusTarget, askedAt: ContinuousClock.Instant
    ) async -> Handling {
        guard stillSelected(selection, target: target, askedAt: askedAt) else { return copiedInstead(text) }
        selectionMoved = false
        // The paster asks this again as its last step before ⌘V, and copies instead on false.
        let focus = field.focus
        let delivery = await TextInserter.deliver(text, to: target, pressReturn: false, alsoRequire: { [weak self] in
            guard let self else { return false }
            let holds = self.stillSelected(selection, target: target, askedAt: askedAt)
            if !holds { self.selectionMoved = true }
            return holds
        }, paster: field.paster, access: { bound in
            var access = TextInserter.FieldAccess.live(bound)
            access.verdict = { focus(bound) }
            return access
        }).result
        if selectionMoved, case .copied = delivery { return copiedInstead(text, copied: true) }
        switch delivery {
        case .pasted, .unknownConfirmed, .unknownUnreadable, .unknownNotLanded:
            remember(VoiceEditUndo(original: selection.text, replacement: text, bundleID: target.bundleID,
                                   processID: target.processID ?? 0, madeAt: Date()),
                     location: selection.location, target: target)
            pill.state = .voiceEdit(.edited(canUndo: true))
            return .finished(.pasted)
        default:
            // Focus moved or the field went away: the edit is on the clipboard, as any dictation would be.
            let presentation = DeliveryPresentation.make(delivery, text: text, usedContext: false, asHeard: false)
            switch presentation.feedback {
            case .pill(let state): pill.present(state, text: text)
            case .notice(let message): pill.state = .error(message)
            }
            return .finished(.copied)
        }
    }

    private func copiedInstead(_ text: String, copied: Bool = false) -> Handling {
        if !copied { field.paster.copy(text) }
        log.notice("voice edit: selection changed before paste, edit copied")
        pill.state = .voiceEdit(.copiedInstead)
        return .finished(.copied)
    }

    private func remember(_ undo: VoiceEditUndo, location: Int?, target: FocusTarget) {
        pending = Pending(undo: undo, location: location, target: target)
        expiry?.cancel()
        expiry = Task { [weak self] in
            try? await Task.sleep(for: VoiceEditUndo.window)
            guard !Task.isCancelled, let self else { return }
            self.pending = nil
            if case .voiceEdit(.edited(canUndo: true)) = self.pill.state { self.pill.state = .voiceEdit(.edited(canUndo: false)) }
        }
    }

    /// Puts the original selection back: selects the edit (only when the field shows exactly the edit
    /// there) and pastes the original over it. Anything less certain leaves the field alone and says so.
    func undo() {
        guard let pending, pending.undo.isOpen(at: Date()) else { return }
        self.pending = nil
        expiry?.cancel()
        pill.state = .voiceEdit(.undoing)
        Task { [weak self] in
            guard let self else { return }
            let result = await self.restore(pending)
            self.log.notice("voice edit undo: \(result == nil ? "done" : "refused", privacy: .public)")
            self.pill.state = .voiceEdit(result.map(VoiceEditChip.undoFailed) ?? .undone)
        }
    }

    /// nil when the original is back; otherwise the line saying why not.
    private func restore(_ pending: Pending) async -> String? {
        let undo = pending.undo
        guard NSWorkspace.shared.frontmostApplication?.processIdentifier == undo.processID,
              let element = SelectionReader.focusedElement(of: undo.processID) else {
            return "Couldn't put it back · app not in front"
        }
        guard let location = pending.location,
              SelectionReader.select(location: location, length: undo.replacement.utf16.count, in: element),
              SelectionReader.selectedText(of: element) == undo.replacement else {
            return "Couldn't put it back · use ⌘Z there"
        }
        switch await TextInserter.insert(undo.original, into: pending.target) {
        case .pasted, .pastedReturnSkipped: return nil
        case .focusChanged, .dispatchFailed: return "Couldn't put it back · use ⌘Z there"
        }
    }

    private static func code(_ outcome: VoiceEditOutcome) -> String {
        switch outcome {
        case .edited: "edited"
        case .dictation: "dictation"
        case .declined(let why): "declined-\(why.rawValue)"
        }
    }
}
