import AppKit
import Carbon.HIToolbox
import MurmurCore
import Testing
@testable import Murmur

/// A paste into a target Hushy was not sure of, end to end against this test's own off-screen
/// window: the real delivery decision, the real `ClipboardPaster` on a private named pasteboard,
/// and counts and caret positions read from a real field editor. Key events are captured, never
/// posted, and no other app is touched (the same tier as `FocusedPasteIntegrationTests`).
///
/// What it pins: only a read of the field brings the earlier clipboard back; a paste that could
/// not be read keeps the dictation on the clipboard and shows the quiet row; a field that was read
/// and did not change opens the card.
@MainActor
@Suite("Uncertain paste — own window, private pasteboard", .serialized)
final class UncertainPasteOwnWindowTests {
    private static let words = "Vela raises the amber sail."
    private static let userClipboard = "the user's clipboard"

    private let window: NSWindow
    private let composer = NSView(frame: NSRect(x: 0, y: 40, width: 300, height: 60))
    private let sidebar = NSView(frame: NSRect(x: 0, y: 0, width: 300, height: 40))
    private let field = NSTextField(frame: NSRect(x: 10, y: 10, width: 280, height: 24))
    private let otherField = NSTextField(frame: NSRect(x: 10, y: 8, width: 280, height: 24))
    private let pasteboard = NSPasteboard(name: NSPasteboard.Name("app.hushy.tests.\(UUID().uuidString)"))
    private let reader: WindowFocusReader
    private var paster: ClipboardPaster!
    private var keys: [String] = []
    /// False: ⌘V is posted but the field takes nothing (an app that ignored the paste).
    private var fieldTakesPaste = true
    /// Runs right after a captured ⌘V: what the person does while Hushy is checking.
    private var afterPasteKey: () -> Void = {}

    init() {
        _ = NSApplication.shared
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 100),
                          styleMask: [.titled], backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        composer.addSubview(field)
        sidebar.addSubview(otherField)
        window.contentView?.addSubview(composer)
        window.contentView?.addSubview(sidebar)
        reader = WindowFocusReader(window: window, ownPID: ProcessInfo.processInfo.processIdentifier,
                                   ownBundle: Bundle.main.bundleIdentifier)
        paster = ClipboardPaster(pasteboard: pasteboard, postKey: { [unowned self] key, flags in
            self.capture(key: key, flags: flags)
        }, restoreDelay: .milliseconds(20), returnDelay: .milliseconds(5))
        pasteboard.clearContents()
        pasteboard.setString(Self.userClipboard, forType: .string)
        field.stringValue = "Hi. "
        #expect(window.makeFirstResponder(field))
        editor?.selectedRange = NSRange(location: 4, length: 0)
    }

    isolated deinit {
        pasteboard.releaseGlobally()
    }

    private var editor: NSText? { field.currentEditor() }

    /// AppKit's paste without the event system: the focused field's editor inserts the pasteboard
    /// string at its caret.
    private func capture(key: CGKeyCode, flags: CGEventFlags) -> Bool {
        guard key == CGKeyCode(kVK_ANSI_V), flags.contains(.maskCommand) else { return true }
        keys.append("⌘V")
        defer { afterPasteKey() }
        guard fieldTakesPaste, let editor, let string = pasteboard.string(forType: .string) else { return true }
        let selection = editor.selectedRange
        editor.replaceCharacters(in: selection, with: string)
        editor.selectedRange = NSRange(location: selection.location + string.utf16.count, length: 0)
        return true
    }

    private var bound: BoundFocus<NSView> {
        let pid = reader.frontmostApp()?.processID
        return BoundFocus(processID: pid, bundleID: reader.frontmostApp()?.bundleID,
                          field: pid.flatMap(reader.focusedField), window: pid.flatMap(reader.focusedWindow))
    }

    /// What Hushy can read of the field: `count` and `caret` say which numbers it exposes.
    private func probe(count: Bool, caret: Bool) -> LandingProbe? {
        guard count || caret, let editor else { return nil }
        return LandingProbe(characterCount: count ? editor.string.utf16.count : nil,
                            selectedLength: caret ? editor.selectedRange.length : nil,
                            caretLocation: caret ? editor.selectedRange.location : nil)
    }

    private func deliver(count: Bool, caret: Bool) async -> DeliveryResult {
        let bound = bound
        let reader = reader
        let result = await TargetedDelivery.deliver(
            text: Self.words, pressReturn: false, answer: .unknown,
            check: { TargetGuard.check(bound, reader: reader) },
            landing: { [unowned self] in self.probe(count: count, caret: caret) }, paster: paster)
        await paster.waitForPendingRestore()
        return result
    }

    private var clipboardHoldsTheDictation: Bool {
        pasteboard.string(forType: .string) == Self.words
            && pasteboard.data(forType: ClipboardPaster.transientType) != nil
    }

    private func presentation(_ result: DeliveryResult) -> DeliveryPresentation {
        DeliveryPresentation.make(result, text: Self.words, usedContext: false, asHeard: false)
    }

    @Test("the field's count changed: confirmed, the earlier clipboard is back, the ordinary tick")
    func countConfirms() async {
        let result = await deliver(count: true, caret: false)
        #expect(result == .unknownConfirmed)
        #expect(field.stringValue == "Hi. " + Self.words)
        #expect(pasteboard.string(forType: .string) == Self.userClipboard)
        #expect(presentation(result).feedback == .pill(.done(words: 5)))
    }

    @Test("only the caret can be read and it moved: confirmed, the earlier clipboard is back")
    func caretConfirms() async {
        let result = await deliver(count: false, caret: true)
        #expect(result == .unknownConfirmed)
        #expect(field.stringValue == "Hi. " + Self.words)
        #expect(pasteboard.string(forType: .string) == Self.userClipboard)
    }

    @Test("the text landed but nothing can be read: the dictation stays on the clipboard and the pill is one quiet line")
    func unreadableIsQuietAndKeepsTheWords() async {
        let result = await deliver(count: false, caret: false)
        #expect(result == .unknownUnreadable)
        #expect(field.stringValue == "Hi. " + Self.words, "it did land; Hushy just could not see it")
        #expect(keys == ["⌘V"])
        #expect(clipboardHoldsTheDictation, "never restored on a guess")
        let shown = presentation(result)
        #expect(shown.feedback == .pill(.pastedUnchecked))
        // One click from the row to every word.
        let pill = PillModel()
        guard case .pill(let state) = shown.feedback else { return }
        pill.present(state, text: Self.words)
        pill.showUncheckedWords()
        #expect(pill.state == .noField(.copiedAutomaticallyUnconfirmed))
        #expect(pill.noFieldText == Self.words)
    }

    @Test("nothing landed and nothing can be read: the words are still on the clipboard, one ⌘V away")
    func unreadableAndNotLandedStillKeepsTheWords() async {
        fieldTakesPaste = false
        let result = await deliver(count: false, caret: false)
        #expect(result == .unknownUnreadable)
        #expect(field.stringValue == "Hi. ")
        #expect(clipboardHoldsTheDictation, "the opposite failure must never come back: no dictation is lost")
    }

    @Test("the field was read and did not change: evidence of failure, the card opens with the words")
    func readAndUnchangedOpensTheCard() async {
        fieldTakesPaste = false
        let result = await deliver(count: true, caret: true)
        #expect(result == .unknownNotLanded)
        #expect(clipboardHoldsTheDictation)
        #expect(presentation(result).feedback == .pill(.noField(.copiedAutomaticallyUnconfirmed)))
    }

    @Test("only the caret can be read and it did not move: not called a failure, the words stay")
    func caretOnlyUnmovedIsQuiet() async {
        fieldTakesPaste = false
        let result = await deliver(count: false, caret: true)
        #expect(result == .unknownUnreadable)
        #expect(clipboardHoldsTheDictation)
        #expect(presentation(result).feedback == .pill(.pastedUnchecked))
    }

    // MARK: A caret that moved some other way

    @Test("nothing landed and the person moved the caret during the check: never confirmed, the words stay",
          arguments: [(4, 0), (4, 2), (0, 3), (1, 4), (0, 4)])
    func caretMovedByHandIsNotAPaste(from start: Int, to location: Int) async {
        fieldTakesPaste = false
        editor?.selectedRange = NSRange(location: start, length: 0)
        afterPasteKey = { [unowned self] in editor?.selectedRange = NSRange(location: location, length: 0) }
        let result = await deliver(count: false, caret: true)
        #expect(result == .unknownUnreadable)
        #expect(field.stringValue == "Hi. ")
        #expect(clipboardHoldsTheDictation, "a wrong confirm would have put the earlier clipboard back")
    }

    @Test("the text landed over a selection: the caret ends at the selection start plus the pasted length, confirmed")
    func pasteOverASelectionConfirmsByCaret() async {
        editor?.selectedRange = NSRange(location: 0, length: 3)
        let result = await deliver(count: false, caret: true)
        #expect(result == .unknownConfirmed)
        #expect(field.stringValue == Self.words + " ")
        #expect(pasteboard.string(forType: .string) == Self.userClipboard)
    }

    // MARK: The same field before and after

    /// Nothing was bound at key-down, so each read looks at whichever field has focus now, as
    /// `FocusTarget.landingRead` does, through the same pin.
    private func deliverUnbound() async -> DeliveryResult {
        let focus = reader
        let pid = focus.frontmostApp()?.processID
        let bound = BoundFocus<NSView>(processID: pid, bundleID: focus.frontmostApp()?.bundleID,
                                       field: nil, window: pid.flatMap(focus.focusedWindow))
        var pin = LandingPin<NSView>()
        let result = await TargetedDelivery.deliver(
            text: Self.words, pressReturn: false, answer: .unknown,
            check: { TargetGuard.check(bound, reader: focus) },
            landing: {
                guard let focused = focus.currentField as? NSTextField, pin.admits(focused, isSame: { $0 === $1 }) else { return nil }
                return LandingProbe(characterCount: focused.stringValue.utf16.count, selectedLength: 0)
            }, paster: paster)
        await paster.waitForPendingRestore()
        return result
    }

    @Test("with nothing bound, the same field read before and after confirms as usual")
    func unboundSameFieldConfirms() async {
        let result = await deliverUnbound()
        #expect(result == .unknownConfirmed)
        #expect(pasteboard.string(forType: .string) == Self.userClipboard)
    }

    @Test("with nothing bound, another field focused during the check is never compared with the first: the words stay")
    func unboundOtherFieldIsNotAConfirmation() async {
        // Nothing lands; the person clicks into a second field that happens to hold more text.
        // Its count differs from the first field's, and that difference is not a paste.
        fieldTakesPaste = false
        otherField.stringValue = "A longer note that was already there."
        afterPasteKey = { [unowned self] in _ = window.makeFirstResponder(otherField) }
        let result = await deliverUnbound()
        #expect(result == .unknownUnreadable)
        #expect(field.stringValue == "Hi. ")
        #expect(clipboardHoldsTheDictation)
    }

    // MARK: A late field inside what key-down saw

    private func inside(_ view: NSView, _ container: NSView, limit: Int = FocusRefresh.ancestorLimit) -> Bool {
        FocusRefresh.isInside(view, ancestor: container, limit: limit, parent: { $0.superview }, isSame: { $0 === $1 })
    }

    @Test("a field inside the key-down container is adopted; one in another part of the window is not")
    func adoptionFollowsTheRealViewTree() {
        #expect(inside(field, composer))
        #expect(!inside(otherField, composer), "a field outside that subtree is still focus moved")
        #expect(FocusRefresh.mayAdopt(original: .unknown, hadElement: true, sameApp: true, sameWindow: true,
                                      current: .field, insideOriginal: inside(field, composer),
                                      security: reader.security(field)))
        #expect(!FocusRefresh.mayAdopt(original: .unknown, hadElement: true, sameApp: true, sameWindow: true,
                                       current: .field, insideOriginal: inside(otherField, composer),
                                       security: reader.security(otherField)))
    }

    @Test("a password field inside the container is never adopted")
    func passwordFieldInsideTheContainerIsRefused() {
        let password = NSSecureTextField(frame: NSRect(x: 10, y: 36, width: 280, height: 20))
        composer.addSubview(password)
        #expect(inside(password, composer))
        #expect(!FocusRefresh.mayAdopt(original: .unknown, hadElement: true, sameApp: true, sameWindow: true,
                                       current: .field, insideOriginal: true, security: reader.security(password)))
    }

    @Test("a field too deep to reach within the bound is not adopted")
    func tooDeepIsRefused() {
        #expect(inside(field, window.contentView!, limit: 2))
        #expect(!inside(field, window.contentView!, limit: 1))
    }
}
