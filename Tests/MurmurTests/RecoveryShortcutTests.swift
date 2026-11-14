import Carbon.HIToolbox
import CoreGraphics
import Foundation
import Testing
@testable import Murmur

/// The shortcut that brings the last dictation back is named, in words, where a dictation was
/// just not pasted, and nowhere it would mislead: not beside a password field, and not on a
/// failure, where the last dictation is an older one.
@Suite("Recovery: paste last is named where it helps")
@MainActor
struct RecoveryShortcutTests {
    nonisolated static let cardModes: [NoFieldMode] = [
        .offerCopy, .copied, .copiedAutomatically, .copiedAutomaticallyUnconfirmed, .copiedUnconfirmed,
        .notPasted(.targetChanged(.app)), .notPasted(.pasteFailed), .notPastedCopiedAgain(.pasteFailed),
        .plainNotPasted, .plainNotPastedCopied,
    ]

    @Test("the not-pasted card says how to get the dictation back, in words with the shortcut", arguments: cardModes)
    func cardNamesPasteLast(mode: NoFieldMode) {
        #expect(mode.recoveryLine == "⌃⌘V pastes your last dictation")
        #expect(mode.recoveryLine == ShortcutHelp.pasteLastLine)
    }

    @Test("the words name the keys the app really listens for")
    func wordsMatchTheShortcuts() {
        let chord: CGEventFlags = [.maskControl, .maskCommand]
        #expect(HotkeyMonitor.globalShortcut(keyCode: kVK_ANSI_V, flags: chord) == .pasteLast)
        #expect(HotkeyMonitor.globalShortcut(keyCode: kVK_ANSI_C, flags: chord) == .copyLast)
        #expect(ShortcutHelp.pasteLast == "⌃⌘V")
        #expect(ShortcutHelp.copyLast == "⌃⌘C")
        #expect(ShortcutHelp.pasteLastLine.hasPrefix(ShortcutHelp.pasteLast))
        #expect(ShortcutHelp.copyLastKeys.joined() == ShortcutHelp.copyLast)
    }

    @Test("the capsule under a card whose text is not on the clipboard names copy last, and says why it opened")
    func capsuleLabel() {
        #expect(NoFieldMode.offerCopy.capsuleLabel == "Not typed")
        #expect(NoFieldMode.plainNotPasted.capsuleLabel == "Not pasted")
        for mode in [NoFieldMode.copiedAutomatically, .copied, .notPasted(.pasteFailed), .plainNotPastedCopied] {
            #expect(mode.capsuleLabel == nil, "already on the clipboard: the capsule says so instead (\(mode))")
        }
    }

    @Test("the password row never names a paste shortcut: it would invite pasting into that field")
    func passwordRowStaysQuiet() {
        let pill = PillModel()
        pill.present(.held(copied: false), text: "hunter2")
        #expect(PillState.held(copied: false).hoverDetail == nil)
        #expect(!pill.accessibilityLabel.contains("Command V"))
        #expect(!pill.accessibilityLabel.contains("⌘V"))
    }

    @Test("a failure never names paste last: the last dictation is an older one",
          arguments: RecoveryFailureTests.all)
    func failuresDoNotNameIt(failure: DictationFailure) {
        #expect(!failure.line.contains("⌘"))
        #expect(!failure.accessibilityText.contains("Command"))
    }

    @Test("a pasted dictation carries no shortcut hint: the ordinary pill is unchanged")
    @MainActor
    func pastedIsUnchanged() {
        #expect(PillState.done(words: 9).hoverDetail == nil)
        #expect(PillModel.doneLine(words: 9, asHeard: false, notSent: false) == nil)
    }

    @Test("the line keeps the app's voice")
    func voice() {
        let line = ShortcutHelp.pasteLastLine
        #expect(!line.contains("!"))
        #expect(!line.contains("—"))
        let words = line.lowercased().split { !$0.isLetter }.map(String.init)
        #expect(!words.contains("simply"))
        #expect(!words.contains("just"))
    }
}
