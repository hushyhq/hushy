import Foundation
import MurmurCore
import Testing
@testable import Murmur

/// A dictation that was not pasted never hides its words: the card shows all of them, stays long
/// enough to read them and while it is pointed at, and the one row that never draws them (a
/// password field) leads to that dictation in History.
@Suite("Recovery: a not-pasted result never hides the words")
@MainActor
struct RecoveryNotPastedTests {
    /// About 120 invented words, the length the card used to cut to three lines.
    private let long = Array(repeating: "the harbour ferry leaves at nine and the amber lamp stays on", count: 10)
        .joined(separator: " ")
    private let short = "Ship it on Thursday, and tell Dana."
    private let secret = "hunter2 correct horse battery staple"

    private final class Recorder { var values: [String] = [] }

    // MARK: Reading time

    @Test("a short dictation keeps the card's own 10 s")
    func shortKeepsTheFloor() {
        #expect(NoFieldMode.copiedAutomatically.dismissDelay(words: 7) == .seconds(10))
        #expect(NoFieldMode.copiedAutomaticallyUnconfirmed.dismissDelay(words: 7) == .seconds(8))
        #expect(NoFieldMode.offerCopy.dismissDelay(words: 0) == .seconds(10))
    }

    @Test("a long dictation gets the time it takes to read every word, up to a minute")
    func longGetsReadingTime() {
        let delay = NoFieldMode.notPasted(.targetChanged(.app)).dismissDelay(words: 120)
        #expect(delay == .seconds(44), "4 s to notice, then 120 words at 3 a second")
        #expect(NoFieldMode.copiedAutomatically.dismissDelay(words: 5_000) == NoFieldReading.longest)
        #expect(NoFieldReading.longest == .seconds(60))
    }

    @Test("once Copy was pressed the card closes on the short delay, whatever its length",
          arguments: [NoFieldMode.copied, .copiedUnconfirmed, .notPastedCopiedAgain(.pasteFailed), .plainNotPastedCopied])
    func pressedClosesSoon(mode: NoFieldMode) {
        #expect(mode.dismissDelay(words: 5_000) == .milliseconds(1_400))
    }

    @Test("the pill times its card by the words it is showing")
    func pillUsesTheText() {
        let pill = PillModel()
        pill.present(.noField(.copiedAutomatically), text: long)
        #expect(TextStats.wordCount(long) == 120)
        #expect(pill.selfDismissDelay == .seconds(44))
        pill.present(.noField(.copiedAutomatically), text: short)
        #expect(pill.selfDismissDelay == .seconds(10))
        pill.state = .held(copied: true)
        #expect(pill.selfDismissDelay == .milliseconds(1_400), "every other row keeps its own delay")
        pill.state = .idle
        #expect(pill.selfDismissDelay == nil)
    }

    // MARK: Pointing at it

    @Test("the card and the password row stay while the pointer is on them")
    func pointerHolds() {
        for state: PillState in [.noField(.offerCopy), .noField(.plainNotPasted), .held(copied: false)] {
            #expect(state.holdsUnpastedWords, "\(state)")
            #expect(state.selfDismissDecision(pointerOverCard: true) == .wait(PillState.pointerGrace), "\(state)")
            #expect(state.selfDismissDecision(pointerOverCard: false) == .dismiss, "\(state)")
        }
        #expect(!PillState.held(copied: true).holdsUnpastedWords, "Copied has nothing left to reach for")
    }

    // MARK: The card that offers Copy after a paste gave way

    @Test("a paste that gave way opens the card with the words and a live Copy, clipboard untouched")
    func plainNotPasted() {
        let mode = NoFieldMode.plainNotPasted
        #expect(mode.reasonLine == "Not pasted")
        #expect(mode.hintLine == nil)
        #expect(!mode.wasCopiedAutomatically, "nothing was written to the clipboard for it")
        #expect(mode.statusLine == nil)
        #expect(mode.copyButtonTitle == "Copy")
        #expect(mode.accessibilityText == "Not pasted. Press Copy to copy what you said.")
        let copies = Recorder()
        let pill = PillModel()
        pill.onPlainCopy = { copies.values.append($0) }
        pill.present(.noField(mode), text: short)
        #expect(pill.noFieldText == short)
        #expect(copies.values.isEmpty)
        pill.copyNoFieldText()
        #expect(copies.values == [short])
        #expect(pill.state == .noField(.plainNotPastedCopied))
        #expect(NoFieldMode.plainNotPastedCopied.reasonLine == "Not pasted")
        #expect(NoFieldMode.plainNotPastedCopied.copyButtonTitle == "Copied")
        #expect(NoFieldMode.plainNotPastedCopied.afterCopy == nil)
    }

    // MARK: The password row: History, never the words

    @Test("the password row's History button asks for that dictation and closes the row")
    func heldOpensHistory() {
        let asked = Recorder()
        let pill = PillModel()
        pill.onOpenInHistory = { asked.values.append($0) }
        pill.present(.held(copied: false), text: secret)
        #expect(pill.noFieldText == nil, "the row still draws no words")
        pill.openHeldInHistory()
        #expect(asked.values == [secret])
        #expect(pill.state == .idle)
        pill.openHeldInHistory()
        #expect(asked.values == [secret], "nothing is kept once the row has gone")
    }

    @Test("History opens on the newest dictation only when it is the one the row held")
    func historyItemMatchesTheText() {
        let saved = Dictation(id: 41, rawText: secret, text: secret, durationSeconds: 2, status: .notInserted)
        #expect(HistoryRoute.itemID(matching: secret, last: saved) == 41)
        #expect(HistoryRoute.itemID(matching: "something else", last: saved) == nil, "never the wrong item")
        #expect(HistoryRoute.itemID(matching: secret, last: nil) == nil)
    }

    // MARK: Room for it

    @Test("the panel reserves room for the tallest card and stays click-through outside what is drawn")
    func panelRoom() {
        let size = PillPanel.size(for: .noField(.copiedAutomatically))
        #expect(size.height == PillPanel.size.height + NoFieldCard.panelHeight)
        #expect(NoFieldCard.panelHeight >= NoFieldCard.textMaxHeight + 100, "header, button row, padding and shadow")
        #expect(PillPanel.size(for: .held(copied: false)).height == PillPanel.size.height, "the password row stays pill-sized")
    }
}
