import AppKit
import MurmurCore
import os

/// Restyle selection (`FeatureFlags.restyleSelection`): the person asks for a tone on the text they selected, with
/// Hushy's shortcut (tone chips in the pill) or a right-click Services item (`RestyleServicesProvider`). Nothing is
/// spoken. Nothing is read until that one action: no timer, no observer, no look at the clipboard or the selection
/// on Hushy's own. The text lives in `offer` for the seconds the chips are showing, and is never logged or stored.
///
/// The rewrite is a voice edit with a fixed instruction (`SelectionRestyler`), so the guard that keeps a dropped
/// "not", a changed number or a lost name from replacing the text applies here as it does there. Replacing goes through
/// `VoiceEditController.deliver`, with its last look before ⌘V and its one undo.
@MainActor
final class RestyleController {
    /// What the controller reads from the Mac. Live, the focused app and Accessibility; tests pass their own.
    struct Environment {
        var isEnabled: @MainActor () -> Bool
        /// The frontmost app is one whose text is never read (a password manager, a credential pane).
        var isDenied: @MainActor () -> Bool
        var reading: @MainActor () -> SelectionReader.Reading?
        var target: @MainActor () -> FocusTarget

        @MainActor static var live: Environment { Environment(
            isEnabled: { FeatureFlags.restyleSelection },
            isDenied: { ContextReader.isDenylisted(bundleID: NSWorkspace.shared.frontmostApplication?.bundleIdentifier) },
            reading: { SelectionReader.readAny(app: NSWorkspace.shared.frontmostApplication) },
            target: { FocusTarget.current() }) }
    }

    private struct Offer {
        let selection: SelectedText
        let target: FocusTarget
    }

    private let model: any LanguageModel
    private let pill: PillModel
    private let voiceEdits: VoiceEditController
    private let field: VoiceEditController.Field
    private let environment: Environment
    private var offer: Offer?
    private var expiry: Task<Void, Never>?
    private let log = Logger(subsystem: "app.hushy", category: "restyle")
    private(set) lazy var servicesProvider = RestyleServicesProvider(restyle: self)

    init(model: any LanguageModel, pill: PillModel, voiceEdits: VoiceEditController,
         field: VoiceEditController.Field = .live, environment: Environment = .live) {
        self.model = model
        self.pill = pill
        self.voiceEdits = voiceEdits
        self.field = field
        self.environment = environment
        pill.onRestylePick = { [weak self] style in Task { @MainActor in await self?.pick(style) } }
        pill.onRestyleToggleCopy = { [weak self] in self?.toggleCopy() }
        pill.onRestyleCancel = { [weak self] in self?.cancel() }
    }

    // MARK: The shortcut

    /// The shortcut was pressed: read the selection now, once, and show the chips.
    func begin() {
        guard environment.isEnabled() else { return }
        guard let (selection, reading) = readSelection() else { return }
        offer = Offer(selection: selection, target: environment.target())
        // Without a place in the field the paste cannot be told from another copy of the text (voice edit's rule).
        let copyOnly = !reading.isEditable || selection.location == nil
        pill.state = .restyle(RestyleChooser(copy: false, copyOnly: copyOnly))
        expiry?.cancel()
        expiry = Task { [weak self] in
            try? await Task.sleep(for: RestyleChooser.lifetime)
            guard !Task.isCancelled, let self, case .restyle = self.pill.state else { return }
            self.cancel()
        }
    }

    /// A chip was picked. Rewrites, then replaces the selection or copies, as the Copy toggle and the field allow.
    func pick(_ style: RestyleStyle) async {
        guard let offer, case .restyle(let chooser) = pill.state else { return }
        self.offer = nil
        expiry?.cancel()
        let processing = PillState.processing(modeName: VoiceEditController.processingName)
        pill.state = processing
        let started = ContinuousClock.now
        let outcome = await SelectionRestyler.restyle(offer.selection.text, as: style, model: model)
        let characters = offer.selection.text.count
        log.notice("restyle: style=\(style.rawValue, privacy: .public) outcome=\(Self.code(outcome), privacy: .public) chars=\(characters) ms=\(Int(ModelPace.ms(ContinuousClock.now - started))) copy=\(chooser.copies)")
        // Something else took the pill while the model worked: the person moved on, so nothing is delivered.
        guard pill.state == processing else { return }
        switch outcome {
        case .kept(let why):
            pill.state = .voiceEdit(.declined(why))
        case .rewritten(let text) where chooser.copies:
            field.paster.copy(text)
            pill.state = .voiceEdit(.restyleCopied)
        case .rewritten(let text):
            _ = await voiceEdits.deliver(text, replacing: offer.selection, target: offer.target, askedAt: started)
        }
    }

    func toggleCopy() {
        guard case .restyle(var chooser) = pill.state, !chooser.copyOnly else { return }
        chooser.copy.toggle()
        pill.state = .restyle(chooser)
    }

    func cancel() {
        offer = nil
        expiry?.cancel()
        if case .restyle = pill.state { pill.state = .idle }
    }

    // MARK: Services

    /// One Services call in flight. The caller is waiting on the main thread, so the model's work is not tied to the
    /// main actor (`RestyleServicesProvider.run`): `startService` and `finishService` are the two main-actor halves.
    struct ServiceRun {
        let selection: SelectedText
        let model: any LanguageModel
        fileprivate let started: ContinuousClock.Instant
        fileprivate let processing: PillState
    }

    /// A Services item was picked and `text` is what the calling app handed over. Nil when there is nothing to do
    /// (the flag is off, a protected app, blank or too much text; the pill says which).
    func startService(text: String) -> ServiceRun? {
        guard environment.isEnabled(), let selection = checked(text) else { return nil }
        let processing = PillState.processing(modeName: VoiceEditController.processingName)
        pill.state = processing
        return ServiceRun(selection: selection, model: model, started: ContinuousClock.now, processing: processing)
    }

    /// The model's answer (nil: no answer in time). Returns the text the app should put in the selection's place, or
    /// nil when the selection stays as it was: a copy item, a refusal, or anything the guard declined (the pill says so).
    func finishService(_ item: RestyleService, run: ServiceRun, outcome: RestyleOutcome?) -> String? {
        let outcome = outcome ?? .kept(.noAnswer)
        let characters = run.selection.text.count
        log.notice("restyle service: item=\(item.rawValue, privacy: .public) outcome=\(Self.code(outcome), privacy: .public) chars=\(characters) ms=\(Int(ModelPace.ms(ContinuousClock.now - run.started)))")
        guard pill.state == run.processing else { return nil }
        switch (outcome, item.delivery) {
        case (.kept(let why), _):
            pill.state = .voiceEdit(.declined(why))
            return nil
        case (.rewritten(let rewritten), .copyToClipboard):
            field.paster.copy(rewritten)
            pill.state = .voiceEdit(.restyleCopied)
            return nil
        case (.rewritten(let rewritten), .replaceSelection):
            pill.state = .voiceEdit(.edited(canUndo: false))
            return rewritten
        }
    }

    // MARK: Reading

    private func readSelection() -> (SelectedText, SelectionReader.Reading)? {
        if environment.isDenied() { note(RestyleCopy.notHere); return nil }
        guard let reading = environment.reading() else { note(RestyleCopy.nothingSelected); return nil }
        guard let selection = checked(reading.text, location: reading.location) else { return nil }
        return (selection, reading)
    }

    /// The text as a selection to restyle, or the pill's one line saying why it is not.
    private func checked(_ text: String, location: Int? = nil) -> SelectedText? {
        if environment.isDenied() { note(RestyleCopy.notHere); return nil }
        if let selection = SelectedText(text: text, location: location) { return selection }
        note(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? RestyleCopy.nothingSelected : RestyleCopy.tooLong)
        return nil
    }

    private func note(_ line: String) {
        pill.state = .voiceEdit(.restyleNote(line))
    }

    private static func code(_ outcome: RestyleOutcome) -> String {
        switch outcome {
        case .rewritten: "rewritten"
        case .kept(let why): "kept-\(why.rawValue)"
        }
    }
}
