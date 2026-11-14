import AppKit
import Foundation
import MurmurCore
import Testing
@testable import Murmur

/// Pill-only dictation outcomes (docs/product/UI-ROUND-2026-09-28.md §1): one-line rows, the
/// password-field row that never shows, keeps or stages the text without an explicit Copy, the
/// panel that stays pill-sized except for a stacked confirm card, and which rows take clicks.
@Suite("Pill outcomes — copied / held rows, panel size, interactivity")
@MainActor
struct PillOutcomeTests {
    private let secret = "hunter2 correct horse battery staple"

    /// A pill whose Copy writes into `copies` instead of the clipboard.
    private func pill(recording copies: Recorder) -> PillModel {
        let pill = PillModel()
        pill.onCopy = { copies.values.append($0) }
        return pill
    }

    final class Recorder { var values: [String] = [] }

    // MARK: Held (password field)

    @Test("a held row shows no text, keeps it out of state and never copies on its own")
    func heldKeepsTextOutOfState() {
        let copies = Recorder()
        let pill = pill(recording: copies)
        pill.present(.held(copied: false), text: secret)
        #expect(pill.state == .held(copied: false))
        #expect(!String(reflecting: pill.state).contains("hunter2"))
        #expect(!pill.accessibilityLabel.contains("hunter2"))
        #expect(copies.values.isEmpty, "nothing reaches the clipboard without a Copy tap")
    }

    @Test("Copy on the held row copies once, then reads Copied without the ⌘V hint")
    func heldCopyOnTap() {
        let copies = Recorder()
        let pill = pill(recording: copies)
        pill.present(.held(copied: false), text: secret)
        pill.copyHeldText()
        #expect(copies.values == [secret])
        #expect(pill.state == .held(copied: true))
        #expect(!pill.accessibilityLabel.contains("hunter2"))
        #expect(!pill.accessibilityLabel.contains("Command V"), "never invite ⌘V beside a password field")
        pill.copyHeldText()
        #expect(copies.values == [secret], "a second tap copies nothing more")
    }

    @Test("the held text is dropped as soon as the row goes away")
    func heldTextDroppedWhenRowLeaves() {
        let copies = Recorder()
        let pill = pill(recording: copies)
        pill.present(.held(copied: false), text: secret)
        pill.state = .idle
        pill.state = .held(copied: false) // e.g. a snapshot or a stray state write
        pill.copyHeldText()
        #expect(copies.values.isEmpty)
    }

    @Test("only a held row keeps text for Copy; a copied row keeps nothing")
    func onlyHeldKeepsText() {
        let copies = Recorder()
        let pill = pill(recording: copies)
        pill.present(.copied(reason: .pasteFailed), text: secret)
        #expect(pill.state == .copied(reason: .pasteFailed))
        pill.copyHeldText()
        #expect(copies.values.isEmpty)
    }

    @Test("a newer held row copies its own text, not the previous one's")
    func newerHeldRowWins() {
        let copies = Recorder()
        let pill = pill(recording: copies)
        pill.present(.held(copied: false), text: "first")
        pill.present(.held(copied: false), text: "second")
        pill.copyHeldText()
        #expect(copies.values == ["second"])
    }

    @Test("held-row VoiceOver names the field and the Copy button, never the text")
    func heldAccessibility() {
        let pill = PillModel()
        pill.state = .held(copied: false)
        #expect(pill.accessibilityLabel == "Not pasted: a password field has focus. Press Copy to copy the text, or History to read it.")
    }

    // MARK: Copied rows

    @Test("a copied row's VoiceOver is its reason's text", arguments: [
        CopyReason.pasteFailed, .targetChanged(.app), .targetChanged(.fieldClosed),
    ])
    func copiedAccessibility(reason: CopyReason) {
        let pill = PillModel()
        pill.state = .copied(reason: reason)
        #expect(pill.accessibilityLabel == reason.accessibilityText)
    }

    // MARK: Done

    @Test("unreadable paste opens the staged-text card and drops its text after dismissal")
    func unverifiedCopy() {
        let copies = Recorder()
        let pill = PillModel()
        pill.onPlainCopy = { copies.values.append($0) }
        pill.present(.noField(.copiedAutomaticallyUnconfirmed), text: secret)
        #expect(pill.state.isInteractive)
        #expect(pill.accessibilityLabel
                == "Couldn't confirm the paste. Check the field first. Your text may already be there. Copied to the clipboard.")
        #expect(PillPanel.size(for: pill.state).height > PillPanel.size.height)
        #expect(!String(reflecting: pill.state).contains("hunter2"))
        #expect(pill.state.selfDismissDelay == .seconds(8))
        pill.present(.noField(.copiedAutomaticallyUnconfirmed), text: secret)
        pill.state = .idle
        pill.state = .noField(.copiedAutomaticallyUnconfirmed)
        pill.copyNoFieldText()
        #expect(copies.values.isEmpty)
    }

    @Test("unreadable recovery card can be replaced immediately by listening")
    func unverifiedNextDictation() {
        let copies = Recorder()
        let pill = PillModel()
        pill.onPlainCopy = { copies.values.append($0) }
        pill.present(.noField(.copiedAutomaticallyUnconfirmed), text: secret)
        pill.state = .listening
        pill.copyNoFieldText()
        #expect(pill.state == .listening)
        #expect(copies.values.isEmpty)
    }

    @Test("Pasted shows a word count only from 20 words")
    func doneCount() {
        #expect(PillModel.pastedCount(words: 0) == nil)
        #expect(PillModel.pastedCount(words: 19) == nil)
        #expect(PillModel.pastedCount(words: 20) == "20 words")
        #expect(PillModel.pastedCount(words: 142) == "142 words")
    }

    // MARK: Timing owned by the pill itself

    @Test("rows the pill clears on its own: held-copied after 1.4 s")
    func selfDismissDelays() {
        #expect(PillState.held(copied: true).selfDismissDelay == .milliseconds(1_400))
        #expect(PillState.held(copied: false).selfDismissDelay == .seconds(6), "the pill times it, so the pointer can hold it")
        #expect(PillState.copied(reason: .pasteFailed).selfDismissDelay == nil)
        #expect(PillState.idle.selfDismissDelay == nil)
    }

    // MARK: Interactivity

    @Test("rows with a button take clicks; copied rows are click-through (⌘V belongs to the host app)")
    func interactivity() {
        #expect(PillState.held(copied: false).isInteractive)
        #expect(PillState.actionConfirm(Self.card(rows: 1)).isInteractive)
        #expect(!PillState.held(copied: true).isInteractive)
        #expect(!PillState.copied(reason: .pasteFailed).isInteractive)
        #expect(!PillState.copied(reason: .targetChanged(.app)).isInteractive)
        #expect(!PillState.done(words: 3).isInteractive)
    }

    // MARK: Panel size

    @Test("every outcome row is one line: pill height, wide enough for the longest reason")
    func outcomeRowsStayPillSized() {
        let states: [PillState] = [
            .copied(reason: .pasteFailed), .copied(reason: .targetChanged(.field)),
            .held(copied: false), .held(copied: true), .done(words: 142), .done(words: 142, asHeard: true, notSent: true), .error(PillModel.microphoneFailedMessage),
        ]
        for state in states {
            #expect(PillPanel.size(for: state).height == PillPanel.size.height, "\(state)")
            #expect(PillPanel.size(for: state).width <= PillPanel.rowSize.width, "\(state)")
        }
    }

    /// The 440 pt card plus room for its shadow on both sides.
    private static let confirmPanelWidth = ActionConfirmationCard.width + 24

    @Test("the idle pill keeps its small click-blocking panel")
    func idlePanel() {
        #expect(PillPanel.size(for: .idle) == NSSize(width: 280, height: 104))
        #expect(PillPanel.size(for: .listening) == PillPanel.size)
    }

    @Test("a single action is an inline row: wider, never taller")
    func singleActionPanel() {
        let size = PillPanel.size(for: .actionConfirm(Self.card(rows: 1)))
        #expect(size.height == PillPanel.size.height)
        #expect(size.width == Self.confirmPanelWidth)
        #expect(ActionConfirmationCard.width == 440)
    }

    @Test("stacked confirm cards grow 52 pt per row, capped at 3 rows", arguments: [(2, 208.0), (3, 260.0), (4, 260.0)])
    func stackedPanel(rows: Int, height: Double) {
        let size = PillPanel.size(for: .actionConfirm(Self.card(rows: rows)))
        #expect(size == NSSize(width: Self.confirmPanelWidth, height: height))
    }

    // MARK: Confirm layouts (A2)

    @Test("one row renders inline in the pill; two or three stack above it", arguments: [(1, true), (2, false), (3, false)])
    func confirmLayout(rows: Int, inline: Bool) {
        #expect(ActionConfirmationCard.Layout(rowCount: rows) == (inline ? .inline : .stacked))
    }

    @Test("VoiceOver counts the actions to confirm")
    func confirmAccessibility() {
        #expect(ActionConfirmationCard.accessibilityText(count: 1) == "1 action to confirm")
        #expect(ActionConfirmationCard.accessibilityText(count: 3) == "3 actions to confirm")
        let pill = PillModel()
        pill.state = .actionConfirm(Self.card(rows: 3))
        #expect(pill.accessibilityLabel == "3 actions to confirm")
    }

    static func card(rows: Int) -> ActionConfirmationCardState {
        let actions = (0..<rows).map { ProposedAction(kind: .createReminder, title: "Item \($0)", sourceText: "item") }
        return ActionConfirmationCardState(actions: actions)
    }
}
