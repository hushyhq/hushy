import AppKit
import Carbon.HIToolbox
import Foundation
import Testing
@testable import Murmur

/// `ClipboardPaster.isAsLastWritten`: whether anything but the paster has written the clipboard since the paste. The
/// second look at a paste asks it before putting the dictation back on the clipboard, so a copy the person made in
/// between is never overwritten. Every test uses a private, uniquely named pasteboard and a fake ⌘V.
@Suite("Clipboard paster: has the clipboard been written by someone else", .serialized)
@MainActor
final class ClipboardLastWrittenTests {
    private let pasteboard = NSPasteboard(name: NSPasteboard.Name("app.hushy.tests.lastwritten.\(UUID().uuidString)"))
    private var paster: ClipboardPaster!
    /// Runs inside the fake ⌘V, i.e. while the dictation is staged.
    private var duringPaste: () -> Void = {}

    init() {
        paster = ClipboardPaster(pasteboard: pasteboard, postKey: { [unowned self] key, _ in
            if key == CGKeyCode(kVK_ANSI_V) { duringPaste() }
            return true
        }, restoreDelay: .milliseconds(20), returnDelay: .milliseconds(1))
    }

    isolated deinit { pasteboard.releaseGlobally() }

    private func copyText(_ text: String) {
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }

    private func dictate(_ text: String) async {
        _ = await paster.paste(text, pressReturn: false, awaitLanding: nil, hasFocus: { true })
        await paster.waitForPendingRestore()
    }

    @Test("after a paste and its restore, the clipboard is as the paster left it")
    func restoredPasteLeavesItAsWritten() async {
        copyText("a link the person copied")
        await dictate("Ship it on Thursday.")
        #expect(pasteboard.string(forType: .string) == "a link the person copied")
        #expect(paster.isAsLastWritten)
    }

    @Test("a copy the person makes after the restore moves it")
    func aLaterCopyMovesIt() async {
        copyText("a link the person copied")
        await dictate("Ship it on Thursday.")
        copyText("something newer")
        #expect(!paster.isAsLastWritten)
    }

    @Test("a copy made while the dictation was staged moves it, and the restore leaves that copy alone")
    func aCopyDuringTheStagingMovesIt() async {
        copyText("a link the person copied")
        duringPaste = { [unowned self] in copyText("copied during the paste") }
        await dictate("Ship it on Thursday.")
        #expect(pasteboard.string(forType: .string) == "copied during the paste")
        #expect(!paster.isAsLastWritten)
    }

    @Test("the paster's own copy is as written, and the person's next copy moves it")
    func ownCopy() {
        paster.copyForManualPaste("Ship it on Thursday.")
        #expect(paster.isAsLastWritten)
        copyText("something newer")
        #expect(!paster.isAsLastWritten)
    }
}
