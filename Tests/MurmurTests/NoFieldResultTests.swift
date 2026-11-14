import AppKit
import Carbon.HIToolbox
import Foundation
import MurmurCore
import Testing
@testable import Murmur

/// The no-field result card and copy-last (⌃⌘C): what a dictation that ends with no editable
/// text field shows, what the clipboard does, when the card goes away, and the shortcut that
/// copies the last dictation. Pure logic only — the card never needs a live pointer or a Mac
/// with a focused app to be checked.
@Suite("No-field result card and copy-last")
@MainActor
struct NoFieldResultTests {
    private let text = "Ship it on Thursday, and tell Dana."
    private let secret = "hunter2 correct horse battery staple"

    private func make(_ result: DeliveryResult, text: String? = nil) -> DeliveryPresentation {
        DeliveryPresentation.make(result, text: text ?? self.text, usedContext: false, asHeard: false)
    }

    private final class Recorder { var values: [String] = [] }

    private func pill(recording copies: Recorder) -> PillModel {
        let pill = PillModel()
        pill.onPlainCopy = { copies.values.append($0) }
        return pill
    }

    // MARK: Presentation decision

    @Test("no field, clipboard untouched: the card offers Copy and holds nothing for the controller")
    func offersCopy() {
        let shown = make(.noField(copied: false))
        #expect(shown.status == .notInserted, "History keeps the text either way")
        #expect(shown.feedback == .pill(.noField(.offerCopy)))
        #expect(shown.hold == .zero, "the card's own timer and hover rule own its lifetime")
    }

    @Test("no field, clipboard already written: the card says so and offers Copy again")
    func copiedAutomatically() {
        let shown = make(.noField(copied: true))
        #expect(shown.status == .notInserted)
        #expect(shown.feedback == .pill(.noField(.copiedAutomatically)))
        #expect(shown.hold == .zero)
    }

    @Test("a lone Return that found no field is still a quiet notice, not an empty card")
    func emptyTextIsANotice() {
        #expect(make(.noField(copied: false), text: "").feedback == .notice("Couldn't press Return here"))
    }

    @Test("the card state never carries the dictated words")
    func stateCarriesNoText() {
        let shown = make(.noField(copied: false), text: secret)
        #expect(!String(reflecting: shown).contains("hunter2"))
        let pill = PillModel()
        pill.present(.noField(.offerCopy), text: secret)
        #expect(!String(reflecting: pill.state).contains("hunter2"))
        #expect(!pill.accessibilityLabel.contains("hunter2"))
    }

    // MARK: The clipboard rule

    @Test("the default copies for ⌘V (founder rule); leaving the clipboard alone is one case away")
    func clipboardRuleDefault() {
        #expect(NoFieldClipboardPolicy.current == .copyAutomatically)
        #expect(!NoFieldClipboardPolicy.leaveClipboardAlone.copiesAutomatically)
        #expect(NoFieldClipboardPolicy.copyAutomatically.copiesAutomatically)
    }

    // MARK: Card modes

    @Test("each mode's copy: reason line, button, spoken text")
    func modeCopy() {
        #expect(NoFieldMode.reason == "No text field to type into")
        #expect(NoFieldMode.copiedAutomatically.copyButtonTitle == "Copy again")
        #expect(NoFieldMode.offerCopy.copyButtonTitle == "Copy")
        #expect(NoFieldMode.copied.copyButtonTitle == "Copied")
        #expect(NoFieldMode.copiedAutomatically.statusLine == "Copied to clipboard")
        #expect(NoFieldMode.offerCopy.statusLine == nil)
        #expect(NoFieldMode.offerCopy.accessibilityText
                == "No text field to type into. Press Copy to copy what you said.")
        #expect(NoFieldMode.copied.accessibilityText == "No text field to type into. Copied.")
        #expect(NoFieldMode.copiedAutomatically.accessibilityText
                == "No text field to type into. Copied to the clipboard.")
        #expect(NoFieldMode.copiedAutomaticallyUnconfirmed.reasonLine == "Couldn't confirm the paste")
        #expect(NoFieldMode.copiedAutomaticallyUnconfirmed.statusLine == "On clipboard · ⌘V")
        #expect(NoFieldMode.copiedAutomaticallyUnconfirmed.copyButtonTitle == "Copy again")
        #expect(NoFieldMode.copiedUnconfirmed.copyButtonTitle == "Copied")
        #expect(NoFieldMode.copiedUnconfirmed.statusLine == nil)
        #expect(NoFieldMode.copiedUnconfirmed.accessibilityText == "Couldn't confirm the paste. Copied.")
        #expect(NoFieldMode.copiedAutomaticallyUnconfirmed.accessibilityText
                == "Couldn't confirm the paste. Check the field first. Your text may already be there. Copied to the clipboard.")
        #expect(NoFieldMode.copiedAutomaticallyUnconfirmed.hintLine == "Check the field first. Your text may already be there.")
        #expect(NoFieldMode.copiedUnconfirmed.hintLine == NoFieldMode.unconfirmedHint, "the card does not change height when pressed")
        for mode in [NoFieldMode.offerCopy, .copied, .copiedAutomatically, .notPasted(.pasteFailed),
                     .notPastedCopiedAgain(.targetChanged(.app))] {
            #expect(mode.hintLine == nil, "\(mode)")
        }
    }

    @Test("the pill's VoiceOver label follows the card mode and never names the words",
          arguments: [NoFieldMode.offerCopy, .copied, .copiedAutomatically])
    func accessibilityLabel(mode: NoFieldMode) {
        let pill = PillModel()
        pill.present(.noField(mode), text: secret)
        #expect(pill.accessibilityLabel == mode.accessibilityText)
        #expect(!pill.accessibilityLabel.contains("hunter2"))
    }

    // MARK: The words on the card

    @Test("a short dictation shows whole")
    func shortText() {
        #expect(NoFieldText.display(text) == text)
    }

    @Test("line breaks and runs of spaces collapse so a short dictation stays a few lines")
    func textCollapsesWhitespace() {
        #expect(NoFieldText.display("  one\n\ntwo   three\t four \n") == "one two three four")
    }

    @Test("a long dictation keeps every word: nothing is cut and there is no ellipsis")
    func longText() {
        let long = Array(repeating: "word", count: 400).joined(separator: " ")
        let shown = NoFieldText.display(long)
        #expect(shown == long)
        #expect(!shown.contains("…"))
    }

    @Test("one huge unbroken word is shown whole too")
    func unbrokenText() {
        let word = String(repeating: "a", count: 1_000)
        #expect(NoFieldText.display(word) == word)
    }

    @Test("the text is drawn inside a bounded height: about six lines, then it scrolls")
    func boundedHeight() {
        #expect(NoFieldCard.textMaxHeight == 104)
        #expect(NoFieldCard.textMaxHeight < NoFieldCard.panelHeight, "the panel has room for the tallest card")
        #expect(NoFieldWords.scrollCue(words: 124) == "Scroll to read all 124 words")
    }

    // MARK: Auto-dismiss

    @Test("the card clears itself: 10 s to read and decide, 1.4 s after Copy")
    func selfDismiss() {
        #expect(PillState.noField(.offerCopy).selfDismissDelay == .seconds(10))
        #expect(PillState.noField(.copied).selfDismissDelay == .milliseconds(1_400))
        #expect(PillState.noField(.copiedAutomatically).selfDismissDelay == .seconds(10))
    }

    @Test("the timer fires and the card goes, unless the pointer is over it")
    func hoverHold() {
        let card = PillState.noField(.offerCopy)
        #expect(card.selfDismissDecision(pointerOverCard: false) == .dismiss)
        #expect(card.selfDismissDecision(pointerOverCard: true) == .wait(PillState.pointerGrace))
        #expect(PillState.pointerGrace == .milliseconds(1_500))
    }

    @Test("every other self-dismissing row ignores the pointer rule")
    func hoverRuleIsForTheCardOnly() {
        let held = PillState.held(copied: true)
        #expect(held.selfDismissDecision(pointerOverCard: true) == .dismiss)
    }

    // MARK: Interactivity, keys, size

    @Test("the card takes clicks and claims no keys, so it can never eat an Enter or an esc")
    func interactivityAndKeys() {
        for mode in [NoFieldMode.offerCopy, .copied, .copiedAutomatically] {
            #expect(PillState.noField(mode).isInteractive, "\(mode)")
            #expect(PillState.noField(mode).keyScope == .none, "\(mode)")
        }
    }

    @Test("the panel grows to hold the card, like the answer card, and never stands vertical")
    func panelSize() {
        let size = PillPanel.size(for: .noField(.offerCopy))
        #expect(size.width == NoFieldCard.width + 24)
        #expect(size.height == PillPanel.size.height + NoFieldCard.panelHeight)
        // Only a card with a hint line under its reason is taller, by that one line.
        for mode in [NoFieldMode.copiedAutomaticallyUnconfirmed, .copiedUnconfirmed] {
            #expect(PillPanel.size(for: .noField(mode)).height == size.height + NoFieldCard.hintLineHeight, "\(mode)")
        }
        for mode in [NoFieldMode.copied, .copiedAutomatically, .notPasted(.pasteFailed)] {
            #expect(PillPanel.size(for: .noField(mode)).height == size.height, "\(mode)")
        }
        #expect(PillPanel.size(for: .noField(.offerCopy), anchor: .right).height == size.height)
        #expect(!PillLayout(anchor: .right).isVertical(.noField(.offerCopy)))
    }

    // MARK: The model: Copy, hover, text

    @Test("Copy copies once, then the card reads Copied")
    func copyOnce() {
        let copies = Recorder()
        let pill = pill(recording: copies)
        pill.present(.noField(.offerCopy), text: secret)
        #expect(copies.values.isEmpty, "nothing reaches the clipboard without a Copy tap")
        pill.copyNoFieldText()
        #expect(copies.values == [secret])
        #expect(pill.state == .noField(.copied))
        pill.copyNoFieldText()
        #expect(copies.values == [secret], "a second tap copies nothing more")
    }

    @Test("the card's text is the model's to show, and goes when the card goes")
    func textLifetime() {
        let pill = PillModel()
        pill.present(.noField(.offerCopy), text: text)
        #expect(pill.noFieldText == text)
        pill.state = .idle
        #expect(pill.noFieldText == nil)
        pill.state = .noField(.offerCopy) // a stray state write must not resurrect the words
        #expect(pill.noFieldText == nil)
    }

    @Test("a newer card replaces the older one's text and Copy copies the newer")
    func newerCardWins() {
        let copies = Recorder()
        let pill = pill(recording: copies)
        pill.present(.noField(.offerCopy), text: "first")
        pill.present(.noField(.offerCopy), text: "second")
        pill.copyNoFieldText()
        #expect(copies.values == ["second"])
    }

    @Test("unconfirmed card shows the staged dictation and writes nothing until Copy again is pressed, then once")
    func unconfirmedCopy() {
        let copies = Recorder()
        let pill = pill(recording: copies)
        pill.present(.noField(.copiedAutomaticallyUnconfirmed), text: secret)
        #expect(pill.noFieldText == secret)
        #expect(copies.values.isEmpty, "no second automatic write")
        #expect(pill.state == .noField(.copiedAutomaticallyUnconfirmed))
        #expect(pill.accessibilityLabel
                == "Couldn't confirm the paste. Check the field first. Your text may already be there. Copied to the clipboard.")
        pill.copyNoFieldText()
        pill.copyNoFieldText()
        #expect(copies.values == [secret])
        #expect(pill.state == .noField(.copiedUnconfirmed))
        #expect(pill.state.selfDismissDelay == .milliseconds(1_400))
    }

    @Test("the pointer-over-card flag resets when the card goes")
    func pointerFlagResets() {
        let pill = PillModel()
        pill.present(.noField(.offerCopy), text: text)
        pill.isPointerOverCard = true
        pill.state = .idle
        #expect(!pill.isPointerOverCard)
    }

    @Test("the old copy-on-everything paths are untouched: the held row still copies transiently")
    func heldStillUsesTheTransientCopy() {
        let transient = Recorder()
        let plain = Recorder()
        let pill = PillModel()
        pill.onCopy = { transient.values.append($0) }
        pill.onPlainCopy = { plain.values.append($0) }
        pill.present(.held(copied: false), text: secret)
        pill.copyHeldText()
        #expect(transient.values == [secret])
        #expect(plain.values.isEmpty)
    }

    // MARK: Copy-last

    @Test("copy-last with a previous dictation copies its final text")
    func copyLastWithDictation() throws {
        let store = try Store()
        _ = try store.save(Dictation(createdAt: Date(timeIntervalSince1970: 100), rawText: "um ship it", text: "Ship it.", durationSeconds: 1))
        _ = try store.save(Dictation(createdAt: Date(timeIntervalSince1970: 200), rawText: "um later one", text: "A later one.", durationSeconds: 1))
        #expect(try CopyLast.resolve(from: store) == .copy("A later one."))
    }

    @Test("copy-last skips a cancelled dictation")
    func copyLastSkipsCancelled() throws {
        let store = try Store()
        _ = try store.save(Dictation(createdAt: Date(timeIntervalSince1970: 100), rawText: "kept", text: "Kept.", durationSeconds: 1))
        _ = try store.save(Dictation(createdAt: Date(timeIntervalSince1970: 200), rawText: "gone", text: "Gone.", durationSeconds: 1, status: .cancelled))
        #expect(try CopyLast.resolve(from: store) == .copy("Kept."))
    }

    @Test("copy-last with no dictation yet says so and copies nothing")
    func copyLastEmpty() throws {
        let store = try Store()
        #expect(try CopyLast.resolve(from: store) == .nothingToCopy)
        #expect(CopyLast.nothingMessage == "Nothing to copy yet")
    }

    @Test("copy-last treats blank text as nothing to copy")
    func copyLastBlank() {
        #expect(CopyLast.resolve(lastText: nil) == .nothingToCopy)
        #expect(CopyLast.resolve(lastText: "") == .nothingToCopy)
        #expect(CopyLast.resolve(lastText: " \n ") == .nothingToCopy)
        #expect(CopyLast.resolve(lastText: "  hi ") == .copy("  hi "), "the text is copied exactly as saved")
    }

    // MARK: The shortcut

    @Test("⌃⌘C is copy-last and ⌃⌘V is paste-last; extra modifiers or other keys are not")
    func shortcutRouting() {
        let both: CGEventFlags = [.maskControl, .maskCommand]
        #expect(HotkeyMonitor.globalShortcut(keyCode: kVK_ANSI_C, flags: both) == .copyLast)
        #expect(HotkeyMonitor.globalShortcut(keyCode: kVK_ANSI_V, flags: both) == .pasteLast)
        #expect(HotkeyMonitor.globalShortcut(keyCode: kVK_ANSI_C, flags: [.maskCommand]) == nil, "plain ⌘C is the app's")
        #expect(HotkeyMonitor.globalShortcut(keyCode: kVK_ANSI_C, flags: [.maskControl]) == nil)
        #expect(HotkeyMonitor.globalShortcut(keyCode: kVK_ANSI_C, flags: both.union(.maskShift)) == nil)
        #expect(HotkeyMonitor.globalShortcut(keyCode: kVK_ANSI_C, flags: both.union(.maskAlternate)) == nil)
        #expect(HotkeyMonitor.globalShortcut(keyCode: kVK_ANSI_X, flags: both) == nil)
    }

    @Test("the shortcut is listed wherever paste-last is")
    func shortcutListing() {
        #expect(ShortcutHelp.copyLast == "⌃⌘C")
        #expect(ShortcutHelp.pasteLast == "⌃⌘V")
        let line = ShortcutHelp.settingsLine(actionKey: .control)
        #expect(line.contains("Paste last ⌃⌘V"))
        #expect(line.contains("Copy last ⌃⌘C"))
        #expect(line.contains("press control twice"))
        #expect(ShortcutHelp.settingsLine(actionKey: .rightCommand).contains("press right command twice"))
    }
}
