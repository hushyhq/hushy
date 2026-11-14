import AppKit
import MurmurCore
import Testing
@testable import Murmur

/// Why "action done → idle" felt abrupt and what pins it now.
///
/// The panel frame used to snap from the 360 pt row size to the 280 pt idle size the instant the
/// state changed, while the chip inside was still animating narrower — so the chip and its shadow
/// were clipped mid-animation. At the bottom and top edges the panel now keeps one width for every
/// state (`PillPanel.centredWidth`), so there is nothing to clip and nothing to wait for. At a side
/// edge, and for a card's height, a shrinking panel still waits for the content to settle, and
/// both exits use the one state-change motion token.
@Suite("Pill — action done to idle, one smooth size change", .serialized)
@MainActor
struct PillActionDoneExitTests {
    private let chip = DoneChipState(title: "Added: Call Dana", kind: .createReminder, undoRecordID: 1)
    private static let display = PillPanelInteractionTests.fakeDisplay

    private func makePanel(anchor: PillAnchor = .bottom) -> (PillPanel, PillModel) {
        _ = NSApplication.shared
        let model = PillModel()
        model.showWhenIdle = true
        let panel = PillPanel(model: model, environment: PillPanelInteractionTests.fakeEnvironment())
        if anchor != .bottom, let id = Self.display.id {
            panel.prefs.set(anchor, forScreen: id)
            panel.reposition()
        }
        return (panel, model)
    }

    /// What the coordinator does on every state change.
    private func go(_ state: PillState, _ panel: PillPanel, _ model: PillModel) {
        model.state = state
        panel.setState(state)
    }

    // MARK: At the bottom edge: one width, nothing to wait for

    @Test("at the bottom edge a row changes nothing about the panel: same frame as at rest")
    func bottomKeepsOneFrame() {
        let (panel, model) = makePanel()
        let rest = panel.frame
        #expect(rest.width == PillPanel.centredWidth)
        go(.actionDone(chip), panel, model)
        #expect(panel.frame == rest)
        go(.idle, panel, model)
        #expect(panel.frame == rest)
        #expect(!panel.hasPendingResize, "nothing shrinks, so nothing waits")
    }

    @Test("dictation Done → idle needs no panel resize at all")
    func dictationDoneNeedsNoResize() {
        let (panel, model) = makePanel()
        let rest = panel.frame
        go(.done(words: 4), panel, model)
        go(.idle, panel, model)
        #expect(!panel.hasPendingResize)
        #expect(panel.frame == rest)
    }

    // MARK: At a side edge: the width follows the state, and a shrink waits

    /// A narrow row to come from and go back to. (The resting pill stands vertical at a side
    /// edge, so its panel is taller than a row's; these tests are about width.)
    private let narrow = PillState.done(words: 4)

    /// A panel at the right edge, showing the narrow row with nothing waiting.
    private func makeSidePanel() -> (PillPanel, PillModel) {
        let (panel, model) = makePanel(anchor: .right)
        go(narrow, panel, model)
        panel.finishPendingResize()
        return (panel, model)
    }

    @Test("a growing panel resizes at once")
    func growsImmediately() {
        let (panel, model) = makeSidePanel()
        #expect(panel.frame.width == PillPanel.size.width)
        go(.actionDone(chip), panel, model)
        #expect(panel.frame.width == PillPanel.rowSize.width)
        #expect(!panel.hasPendingResize)
    }

    @Test("the panel holds its row width until the chip has settled, then shrinks once")
    func exitSequence() {
        let (panel, model) = makeSidePanel()
        var steps: [(String, CGFloat)] = []
        func note(_ label: String) { steps.append((label, panel.frame.width)) }

        note("narrow")
        go(.actionDone(chip), panel, model); note("done")
        go(narrow, panel, model); note("narrow, content animating")
        panel.finishPendingResize(); note("narrow, settled")

        #expect(steps.map(\.0) == ["narrow", "done", "narrow, content animating", "narrow, settled"])
        #expect(steps.map(\.1) == [
            PillPanel.size.width, PillPanel.rowSize.width, PillPanel.rowSize.width, PillPanel.size.width,
        ])
    }

    @Test("Undone → a narrower row takes the same path")
    func undoneExit() {
        let (panel, model) = makeSidePanel()
        var undone = chip
        undone.undone = true
        go(.actionDone(chip), panel, model)
        go(.actionDone(undone), panel, model)
        #expect(panel.frame.width == PillPanel.rowSize.width)
        go(narrow, panel, model)
        #expect(panel.hasPendingResize)
        #expect(panel.frame.width == PillPanel.rowSize.width)
        panel.finishPendingResize()
        #expect(panel.frame.width == PillPanel.size.width)
    }

    @Test("a new state during the wait cancels the shrink")
    func newStateCancels() {
        let (panel, model) = makeSidePanel()
        go(.actionDone(chip), panel, model)
        go(narrow, panel, model)
        #expect(panel.hasPendingResize)
        go(.actionDone(chip), panel, model)
        #expect(!panel.hasPendingResize)
        #expect(panel.frame.width == PillPanel.rowSize.width)
    }

    @Test("a wider state that follows a shrink-in-waiting is not clipped")
    func widerThanBoth() {
        let (panel, model) = makeSidePanel()
        go(.actionDone(chip), panel, model)
        go(narrow, panel, model)
        go(.handsFree(startedAt: Date()), panel, model)
        #expect(panel.frame.width == PillPanel.hintSize.width)
    }

    @Test("at a side edge the panel's outer edge never moves, whatever its width")
    func sideEdgeStaysPut() {
        let (panel, model) = makePanel(anchor: .right)
        let edge = panel.frame.maxX
        for state in [PillState.actionDone(chip), .failed(.noWords), .idle, .handsFree(startedAt: Date())] {
            go(state, panel, model)
            #expect(panel.frame.maxX == edge, "\(state)")
        }
    }

    // MARK: A card's height still waits

    @Test("a card that closes keeps its height until the content has settled, at the one width")
    func cardHeightWaits() {
        let (panel, model) = makePanel()
        let rest = panel.frame
        model.present(.noField(.offerCopy), text: "Vela toggles the amber beacon before the ferry leaves.")
        panel.setState(model.state)
        #expect(panel.frame.height > rest.height)
        #expect(panel.frame.width == rest.width && panel.frame.minX == rest.minX)
        go(.idle, panel, model)
        #expect(panel.hasPendingResize)
        #expect(panel.frame.height > rest.height)
        panel.finishPendingResize()
        #expect(panel.frame == rest)
    }

    @Test("both Done exits use the same state-change motion, and Reduce Motion fades")
    func sharedMotionToken() {
        let motion = PillMotion.standard
        #expect(PillMotion.role(from: .done(words: 4), to: .idle) == .close)
        #expect(PillMotion.role(from: .actionDone(chip), to: .idle) == .close)
        #expect(motion.animation(.close, reduceMotion: true) == motion.animation(.fade))
        #expect(motion.shrinkDelay(reduceMotion: true) < motion.shrinkDelay(reduceMotion: false))
    }
}
