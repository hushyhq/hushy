import AppKit
import Carbon.HIToolbox
import MurmurCore
import Testing
@testable import Murmur

/// Restyle selection, through the controller's real delivery path (`VoiceEditController.deliver`,
/// `TextInserter.deliver`, `ClipboardPaster`) with an injected selection, a private pasteboard and a key poster that
/// posts nothing, as the voice-edit tests do. Nothing reads the Mac: no Accessibility, no system clipboard.
@MainActor
final class RestyleBench {
    static let text = "hey can u send me the file asap, i will not be in on friday"
    static let rewrite = "Hi, could you please send me the file as soon as possible? I will not be in on Friday."
    /// The same rewrite with the "not" gone.
    static let dropsNegation = "Hi, could you please send me the file as soon as possible? I will be in on Friday."

    let desk: VoiceEditDesk
    let pill = PillModel()
    var reading: SelectionReader.Reading?
    var isEnabled = true
    var isDenied = false
    private(set) var reads = 0
    private(set) var controller: RestyleController!

    init(reply: String = rewrite, reading: SelectionReader.Reading? = .init(text: text, location: 12, isEditable: true)) {
        self.reading = reading
        desk = VoiceEditDesk(selectedNow: reading.flatMap { SelectedText(text: $0.text, location: $0.location) })
        let model = VoiceEditRewriteModel(rewrite: reply)
        controller = RestyleController(
            model: model, pill: pill, voiceEdits: VoiceEditController(model: model, pill: pill, field: desk.field),
            field: desk.field, environment: environment)
    }

    var environment: RestyleController.Environment {
        RestyleController.Environment(
            isEnabled: { [unowned self] in self.isEnabled }, isDenied: { [unowned self] in self.isDenied },
            reading: { [unowned self] in self.reads += 1; return self.reading }, target: { .fieldForTests })
    }

    func servicePasteboard(_ text: String = text) -> NSPasteboard {
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("app.hushy.tests.restyle-service.\(UUID().uuidString)"))
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        return pasteboard
    }
}

@MainActor
@Suite("Restyle selection: the shortcut", .serialized)
struct RestyleShortcutFlowTests {
    @Test("nothing is read until the shortcut is pressed, then the chips show over the selection")
    func readsOnlyOnTheAction() {
        let bench = RestyleBench()
        #expect(bench.reads == 0)
        #expect(bench.pill.state == .idle)
        bench.controller.begin()
        #expect(bench.reads == 1)
        #expect(bench.pill.state == .restyle(RestyleChooser(copy: false, copyOnly: false)))
    }

    @Test("an editable field is replaced through the production delivery path, with undo")
    func replaced() async {
        let bench = RestyleBench()
        bench.controller.begin()
        await bench.controller.pick(.professional)
        #expect(bench.desk.pasted == [RestyleBench.rewrite], "⌘V went out with the rewrite staged")
        #expect(bench.pill.state == .voiceEdit(.edited(canUndo: true)))
    }

    @Test("the Copy toggle leaves the selection alone and puts the rewrite on the clipboard")
    func copyToggle() async {
        let bench = RestyleBench()
        bench.controller.begin()
        bench.controller.toggleCopy()
        #expect(bench.pill.state == .restyle(RestyleChooser(copy: true, copyOnly: false)))
        await bench.controller.pick(.prompt)
        #expect(bench.desk.pasted.isEmpty, "no ⌘V")
        #expect(bench.desk.copied == RestyleBench.rewrite)
        #expect(bench.pill.state == .voiceEdit(.restyleCopied))
    }

    @Test("a selection that cannot be replaced is always copied, and Copy shows on")
    func readOnlyCopied() async {
        let bench = RestyleBench(reading: .init(text: RestyleBench.text, location: 12, isEditable: false))
        bench.controller.begin()
        #expect(bench.pill.state == .restyle(RestyleChooser(copy: false, copyOnly: true)))
        bench.controller.toggleCopy()
        #expect(bench.pill.state == .restyle(RestyleChooser(copy: false, copyOnly: true)), "the toggle cannot turn it off")
        await bench.controller.pick(.casual)
        #expect(bench.desk.pasted.isEmpty)
        #expect(bench.desk.copied == RestyleBench.rewrite)
        #expect(bench.pill.state == .voiceEdit(.restyleCopied))
    }

    @Test("a refused rewrite keeps the original text, copies nothing and says so in the pill", arguments: RestyleStyle.allCases)
    func refusedKeepsOriginal(style: RestyleStyle) async {
        let bench = RestyleBench(reply: RestyleBench.dropsNegation)
        bench.controller.begin()
        await bench.controller.pick(style)
        #expect(bench.desk.pasted.isEmpty, "the selection is not pasted over")
        #expect(bench.desk.copied == nil, "the clipboard is as the person had it")
        #expect(bench.pill.state == .voiceEdit(.declined(.wouldChangeMeaning)))
        #expect(VoiceEditDecline.wouldChangeMeaning.line.contains("text kept"))
    }

    @Test("a refused rewrite is kept with the Copy toggle on too")
    func refusedWhileCopying() async {
        let bench = RestyleBench(reply: RestyleBench.dropsNegation)
        bench.controller.begin()
        bench.controller.toggleCopy()
        await bench.controller.pick(.professional)
        #expect(bench.desk.copied == nil)
        #expect(bench.pill.state == .voiceEdit(.declined(.wouldChangeMeaning)))
    }

    @Test("a selection that moved while the model wrote is never pasted over; the rewrite is copied")
    func selectionMoved() async {
        let bench = RestyleBench()
        bench.controller.begin()
        bench.desk.selectedNow = SelectedText(text: "Another sentence entirely.", location: 12)
        await bench.controller.pick(.professional)
        #expect(bench.desk.pasted.isEmpty)
        #expect(bench.desk.copied == RestyleBench.rewrite)
        #expect(bench.pill.state == .voiceEdit(.copiedInstead))
    }

    @Test("no selection, too much text, a protected app, or the flag off, change nothing", arguments: [
        (nil as String?, RestyleCopy.nothingSelected),
        ("  \n", RestyleCopy.nothingSelected),
        (String(repeating: "a", count: SelectedText.maxCharacters + 1), RestyleCopy.tooLong),
    ])
    func noChips(text: String?, line: String) {
        let bench = RestyleBench(reading: text.map { .init(text: $0, location: 0, isEditable: true) })
        bench.controller.begin()
        #expect(bench.pill.state == .voiceEdit(.restyleNote(line)))
    }

    @Test("a protected app is never read, and the flag off stops the shortcut at once")
    func deniedAndOff() {
        let denied = RestyleBench()
        denied.isDenied = true
        denied.controller.begin()
        #expect(denied.reads == 0)
        #expect(denied.pill.state == .voiceEdit(.restyleNote(RestyleCopy.notHere)))
        let off = RestyleBench()
        off.isEnabled = false
        off.controller.begin()
        #expect(off.reads == 0)
        #expect(off.pill.state == .idle)
    }

    @Test("closing the chips lets the selection go: a late pick does nothing")
    func cancelled() async {
        let bench = RestyleBench()
        bench.controller.begin()
        bench.pill.answer(.dismiss)
        #expect(bench.pill.state == .idle)
        await bench.controller.pick(.professional)
        #expect(bench.desk.pasted.isEmpty && bench.desk.copied == nil)
    }

    @Test("the number keys pick, C toggles Copy and esc closes, only while the chips show and without a modifier")
    func keys() {
        let chips = PillState.restyle(RestyleChooser())
        #expect(chips.keyScope == .restyle)
        let expected: [(Int, PillKey)] = [
            (kVK_ANSI_1, .restylePick(.professional)), (kVK_ANSI_2, .restylePick(.casual)),
            (kVK_ANSI_3, .restylePick(.refined)), (kVK_ANSI_4, .restylePick(.prompt)),
            (kVK_ANSI_C, .restyleToggleCopy), (kVK_Escape, .dismiss),
        ]
        for (code, key) in expected {
            #expect(PillKeyRouter.key(keyCode: code, flags: [], scope: .restyle) == key)
            #expect(PillKeyRouter.key(keyCode: code, flags: .maskCommand, scope: .restyle) == nil)
            #expect(PillKeyRouter.key(keyCode: code, flags: [], scope: .none) == nil, "other rows never take these keys")
        }
        #expect(PillKeyRouter.key(keyCode: kVK_ANSI_5, flags: [], scope: .restyle) == nil)
        #expect(PillKeyRouter.key(keyCode: kVK_Return, flags: [], scope: .restyle) == nil, "⏎ stays the app's")
    }

    @Test("a key the chips take reaches the controller")
    func keysReachTheController() {
        let bench = RestyleBench()
        bench.controller.begin()
        bench.pill.answer(.restyleToggleCopy)
        #expect(bench.pill.state == .restyle(RestyleChooser(copy: true, copyOnly: false)))
    }

    @Test("the row is as wide as the failure row, takes clicks, and its lines are one pill line")
    func rowShape() {
        let chips = PillState.restyle(RestyleChooser())
        #expect(PillPanel.size(for: chips).width == PillPanel.failureSize.width)
        #expect(chips.isInteractive)
        for chip in [VoiceEditChip.restyleCopied, .restyleNote(RestyleCopy.nothingSelected)] {
            #expect(PillState.voiceEdit(chip).selfDismissDelay != nil)
            #expect(PillPanel.size(for: .voiceEdit(chip)) == PillPanel.size(for: .voiceEdit(.declined(.noAnswer))))
        }
    }
}

@MainActor
@Suite("Restyle selection: the chord and the setting", .serialized)
struct RestyleChordTests {
    private func keyDown(_ code: Int, _ flags: CGEventFlags, isRepeat: Bool = false) -> CGEvent {
        let event = CGEvent(keyboardEventSource: nil, virtualKey: CGKeyCode(code), keyDown: true)!
        event.flags = flags
        if isRepeat { event.setIntegerValueField(.keyboardEventAutorepeat, value: 1) }
        return event
    }

    @Test("⌃⌘T is taken and sent as one event; the same chord with ⌥ or ⇧, a plain ⌘T and a held key are not")
    func chord() {
        let monitor = HotkeyMonitor()
        var events: [HotkeyEvent] = []
        monitor.onEvent = { events.append($0) }
        #expect(monitor.handle(type: .keyDown, event: keyDown(kVK_ANSI_T, [.maskControl, .maskCommand])))
        #expect(events == [.restyleSelection])
        for flags: CGEventFlags in [[.maskCommand], [.maskControl], [.maskControl, .maskCommand, .maskAlternate], [.maskControl, .maskCommand, .maskShift]] {
            #expect(!monitor.handle(type: .keyDown, event: keyDown(kVK_ANSI_T, flags)))
        }
        #expect(!monitor.handle(type: .keyDown, event: keyDown(kVK_ANSI_T, [.maskControl, .maskCommand], isRepeat: true)))
        #expect(!monitor.handle(type: .keyDown, event: keyDown(kVK_ANSI_Y, [.maskControl, .maskCommand])))
        #expect(events == [.restyleSelection])
    }

    @Test("the other choices: ⌃⌥⌘T needs the ⌥, and Off takes nothing")
    func choices() {
        let monitor = HotkeyMonitor()
        var events: [HotkeyEvent] = []
        monitor.onEvent = { events.append($0) }
        monitor.restyleShortcut = .controlOptionCommandT
        #expect(!monitor.handle(type: .keyDown, event: keyDown(kVK_ANSI_T, [.maskControl, .maskCommand])))
        #expect(monitor.handle(type: .keyDown, event: keyDown(kVK_ANSI_T, [.maskControl, .maskCommand, .maskAlternate])))
        monitor.restyleShortcut = .off
        #expect(!monitor.handle(type: .keyDown, event: keyDown(kVK_ANSI_T, [.maskControl, .maskCommand])))
        #expect(events == [.restyleSelection])
    }

    @Test("the choice is saved and read back, and defaults to ⌃⌘T")
    func setting() throws {
        let suite = "hushy-test-restyle-shortcut-\(UUID().uuidString)"
        defer { UserDefaults.standard.removePersistentDomain(forName: suite) }
        let defaults = try #require(UserDefaults(suiteName: suite))
        let first = AppSettings(defaults: defaults, calendarAuthorization: .notDetermined)
        #expect(first.restyleShortcut == .controlCommandT)
        first.restyleShortcut = .off
        #expect(AppSettings(defaults: defaults, calendarAuthorization: .notDetermined).restyleShortcut == .off)
    }
}

@MainActor
@Suite("Restyle selection: through the dictation controller", .serialized, .timeLimit(.minutes(1)))
struct RestyleThroughControllerTests {
    @Test("the shortcut event shows the chips and a pick replaces the selection, as in the app")
    func eventToReplace() async throws {
        let suite = "hushy-test-restyle-controller-\(UUID().uuidString)"
        defer { UserDefaults.standard.removePersistentDomain(forName: suite) }
        let bench = RestyleBench()
        let defaults = try #require(UserDefaults(suiteName: suite))
        let settings = AppSettings(defaults: defaults, calendarAuthorization: .notDetermined)
        let sounds = Sounds()
        sounds.isEnabled = false
        let status = SpeechModelStatus()
        let integrity = SpeechModelIntegrity(fetchManifest: { _ in throw CocoaError(.fileReadUnknown) }, defaultsSuiteName: suite)
        let controller = DictationController(
            speech: SpeechEngine(status: status, integrity: integrity), modelStatus: status, store: try Store(),
            settings: settings, pill: bench.pill, sounds: sounds, hotkeys: HotkeyMonitor(),
            encryption: EncryptionController(settings: settings, keyManager: EncryptionKeyManager(keyStore: InMemoryKeyStore())),
            cleanupModel: VoiceEditRewriteModel(rewrite: RestyleBench.rewrite),
            voiceEditField: bench.desk.field, restyleEnvironment: bench.environment)
        controller.handle(.restyleSelection)
        #expect(bench.pill.state == .restyle(RestyleChooser(copy: false, copyOnly: false)))
        await controller.restyle.pick(.professional)
        #expect(bench.desk.pasted == [RestyleBench.rewrite])
        #expect(bench.pill.state == .voiceEdit(.edited(canUndo: true)))
    }
}

@MainActor
@Suite("Restyle selection: the Services handlers", .serialized)
struct RestyleServiceTests {
    @Test("a rewrite item hands the new text back on the pasteboard and leaves the clipboard alone", arguments: [
        RestyleService.makeProfessional, .makeCasual, .cleanUp,
    ])
    func rewriteItems(item: RestyleService) {
        let bench = RestyleBench()
        let pasteboard = bench.servicePasteboard()
        defer { pasteboard.releaseGlobally() }
        bench.controller.servicesProvider.run(item, pasteboard: pasteboard)
        #expect(pasteboard.string(forType: .string) == RestyleBench.rewrite)
        #expect(bench.desk.copied == nil, "the clipboard is as the person had it")
        #expect(bench.pill.state == .voiceEdit(.edited(canUndo: false)))
    }

    @Test("a copy item puts the new text on the clipboard and hands nothing back, so the selection stays", arguments: [
        RestyleService.copyAsProfessional, .copyAsPrompt,
    ])
    func copyItems(item: RestyleService) {
        let bench = RestyleBench()
        let pasteboard = bench.servicePasteboard()
        defer { pasteboard.releaseGlobally() }
        bench.controller.servicesProvider.run(item, pasteboard: pasteboard)
        #expect(pasteboard.string(forType: .string) == RestyleBench.text, "the text the app sent is still what it holds")
        #expect(bench.desk.copied == RestyleBench.rewrite)
        #expect(bench.pill.state == .voiceEdit(.restyleCopied))
    }

    @Test("a refused rewrite keeps the original text in every item and says so in the pill", arguments: RestyleService.allCases)
    func refusedKeepsOriginal(item: RestyleService) {
        let bench = RestyleBench(reply: RestyleBench.dropsNegation)
        let pasteboard = bench.servicePasteboard()
        defer { pasteboard.releaseGlobally() }
        bench.controller.servicesProvider.run(item, pasteboard: pasteboard)
        #expect(pasteboard.string(forType: .string) == RestyleBench.text)
        #expect(bench.desk.copied == nil)
        #expect(bench.pill.state == .voiceEdit(.declined(.wouldChangeMeaning)))
    }

    @Test("blank text, too much text, a protected app and the flag off leave the text as it was")
    func nothingToDo() {
        for (text, expected) in [("  ", RestyleCopy.nothingSelected), (String(repeating: "a", count: SelectedText.maxCharacters + 1), RestyleCopy.tooLong)] {
            let bench = RestyleBench()
            let pasteboard = bench.servicePasteboard(text)
            defer { pasteboard.releaseGlobally() }
            bench.controller.servicesProvider.run(.makeCasual, pasteboard: pasteboard)
            #expect(pasteboard.string(forType: .string) == text)
            #expect(bench.pill.state == .voiceEdit(.restyleNote(expected)))
        }
        let denied = RestyleBench()
        denied.isDenied = true
        let deniedBoard = denied.servicePasteboard()
        defer { deniedBoard.releaseGlobally() }
        denied.controller.servicesProvider.run(.makeCasual, pasteboard: deniedBoard)
        #expect(deniedBoard.string(forType: .string) == RestyleBench.text)
        #expect(denied.pill.state == .voiceEdit(.restyleNote(RestyleCopy.notHere)))
        let off = RestyleBench()
        off.isEnabled = false
        let offBoard = off.servicePasteboard()
        defer { offBoard.releaseGlobally() }
        off.controller.servicesProvider.run(.makeCasual, pasteboard: offBoard)
        #expect(offBoard.string(forType: .string) == RestyleBench.text)
        #expect(off.pill.state == .idle)
    }

    @Test("the provider answers every message Info.plist names, and the real handler does the same work")
    func messages() {
        let bench = RestyleBench()
        let provider = bench.controller.servicesProvider
        for item in RestyleService.allCases {
            #expect(provider.responds(to: NSSelectorFromString("\(item.message):userData:error:")), "\(item.message)")
        }
        let pasteboard = bench.servicePasteboard()
        defer { pasteboard.releaseGlobally() }
        var error: NSString = ""
        provider.makeProfessional(pasteboard, userData: "", error: &error)
        #expect(pasteboard.string(forType: .string) == RestyleBench.rewrite)
    }

    @Test("every string a person reads is a bracketed placeholder")
    func placeholders() {
        let lines = [RestyleCopy.copyToggle, RestyleCopy.copied, RestyleCopy.nothingSelected, RestyleCopy.tooLong, RestyleCopy.notHere,
                     RestyleCopy.close, RestyleCopy.on, RestyleCopy.off, RestyleCopy.chooserAccessibility,
                     RestyleCopy.shortcutSettingTitle, RestyleCopy.shortcutSettingDetail]
            + RestyleStyle.allCases.map(RestyleCopy.chip) + RestyleService.allCases.map(RestyleCopy.serviceItem)
        for line in lines { #expect(line.hasPrefix("[") && line.hasSuffix("]"), "\(line)") }
    }
}
