import AppKit
import MurmurCore
import Testing
@testable import Murmur

/// Where the pill's rows sit on the display: every row, whatever its width, is centred on the
/// point the resting pill is centred on, and closing a row never moves that point.
///
/// The real `PillPanel` and `PillView`, placed by the panel's own `reposition()` on a display
/// parked far off every real screen, with invented text. What is checked is what the app's log
/// reports and what the pointer hits: the drawn shapes (`PillModel.hitRegions`) converted to
/// screen points with the panel's frame (`PillHitTest.screenRect`).
@Suite("Pill — every row is centred where the resting pill is", .serialized)
@MainActor
struct PillCentringTests {
    /// Invented.
    nonisolated static let words = "Vela toggles the amber beacon before the ferry leaves."
    /// Invented: the word a name offer shows.
    nonisolated static let name = "Tavrenna"
    static let display = PillPanelInteractionTests.fakeDisplay

    struct Row: Sendable, CustomTestStringConvertible {
        let name: String
        let state: @MainActor @Sendable () -> PillState
        /// The dictated words behind a card or a held row.
        var text: String?
        /// A row whose words reach the model another way (the name offer).
        var present: (@MainActor @Sendable (PillModel) -> Void)?
        var testDescription: String { name }
    }

    /// A few of them, for checks that do not depend on the row's width.
    nonisolated static var sample: [Row] {
        rows.filter { ["loading the model", "failure: nothing to write", "done", "not pasted card", "action: done"].contains($0.name) }
    }

    /// The rows whose closing is watched: every failure, and one of each other kind.
    nonisolated static var closing: [Row] {
        rows.filter { $0.name.hasPrefix("failure") } + sample.filter { !$0.name.hasPrefix("failure") }
            + rows.filter { ["held for a password field", "pasted, not checked", "hands-free", "name offer", "name offer: spelling open"].contains($0.name) }
    }

    nonisolated static var rows: [Row] {
        let chip = DoneChipState(title: "Added: Call Dana", detail: "Fri 9:00 AM", kind: .createReminder, undoRecordID: 1)
        let reminder = ProposedAction(kind: .createReminder, title: "Send Priya the deck", sourceText: "remind me to send priya the deck")
        let event = ProposedAction(kind: .createEvent, title: "Dentist", sourceText: "dentist tomorrow at three")
        return [
            Row(name: "loading the model") { .error(SpeechModelStatus.loadingLine) },
            Row(name: "downloading the model") { .error("Downloading speech model") },
            Row(name: "microphone notice") { .error(PillModel.microphoneFailedMessage) },
            Row(name: "failure: no words") { .failed(.noWords) },
            Row(name: "failure: nothing to write") { .failed(.nothingToWrite) },
            Row(name: "failure: heard nothing") { .failed(.heardNothing) },
            Row(name: "failure: mic silent") { .failed(.micSilent) },
            Row(name: "failure: headset connecting") { .failed(.headsetConnecting) },
            Row(name: "failure: transcription, audio kept") { .failed(.transcription(recordingKept: true)) },
            Row(name: "failure: transcription, audio gone") { .failed(.transcription(recordingKept: false)) },
            Row(name: "failure: did not start") { .failed(.didNotStart("Microphone access needed")) },
            Row(name: "listening") { .listening },
            Row(name: "hands-free") { .handsFree(startedAt: Date()) },
            Row(name: "writing") { .processing() },
            Row(name: "done") { .done(words: 9) },
            Row(name: "done, as heard") { .done(words: 142, asHeard: true) },
            Row(name: "done, Return not pressed") { .done(words: 9, notSent: true) },
            Row(name: "pasted, not checked", state: { .pastedUnchecked }, text: words),
            Row(name: "copied: paste failed") { .copied(reason: .pasteFailed) },
            Row(name: "copied: switched apps") { .copied(reason: .targetChanged(.app)) },
            Row(name: "copied: another field") { .copied(reason: .targetChanged(.field)) },
            Row(name: "held for a password field", state: { .held(copied: false) }, text: words),
            Row(name: "held, copied") { .held(copied: true) },
            Row(name: "not pasted card", state: { .noField(.notPasted(.targetChanged(.app))) }, text: words),
            Row(name: "no field card", state: { .noField(.offerCopy) }, text: words),
            Row(name: "unconfirmed card", state: { .noField(.copiedAutomaticallyUnconfirmed) }, text: words),
            Row(name: "name offer", state: { .nameOffer(.offered, words: 24) }, present: { model in
                model.present(nameOffer: name, words: 24, usedContext: false) { _ in }
            }),
            Row(name: "name offer: spelling open", state: { .nameOffer(.editing) }, present: { model in
                model.present(nameOffer: name, words: 0, usedContext: false) { _ in }
                model.openNameOffer()
                model.nameOffer?.spelling = name + "h"
            }),
            Row(name: "name offer: added", state: { .nameOffer(.added) }, present: { model in
                model.present(nameOffer: name, words: 0, usedContext: false) { _ in }
                model.acceptNameOffer()
            }),
            Row(name: "action: listening") { .actionListening },
            Row(name: "action: working") { .actionProcessing },
            Row(name: "action: done") { .actionDone(chip) },
            Row(name: "action: one to confirm") { .actionConfirm(ActionConfirmationCardState(actions: [reminder])) },
            Row(name: "action: two to confirm") { .actionConfirm(ActionConfirmationCardState(actions: [reminder, event])) },
        ]
    }

    // MARK: Harness

    /// A panel placed by its own `reposition()` at `anchor` on the fake display.
    private func makePanel(anchor: PillAnchor = .bottom) throws -> (PillPanel, PillModel) {
        _ = NSApplication.shared
        let model = PillModel()
        model.showWhenIdle = true
        let panel = PillPanel(model: model, environment: PillPanelInteractionTests.fakeEnvironment())
        if anchor != .bottom {
            panel.prefs.set(anchor, forScreen: try #require(Self.display.id))
            panel.reposition()
        }
        // On the window list, far off every screen: SwiftUI lays out only a window that is ordered in.
        panel.orderFrontRegardless()
        settle(panel)
        return (panel, model)
    }

    private func settle(_ panel: PillPanel, _ seconds: Double = 0.3) {
        panel.contentView?.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(seconds))
        panel.contentView?.layoutSubtreeIfNeeded()
    }

    /// Runs the run loop until the drawn shapes have stopped changing (and any waiting shrink has
    /// landed), for at most `limit` seconds: the same answer on a quiet Mac and a busy one.
    private func settleUntilStill(_ panel: PillPanel, _ model: PillModel, limit: Double = 4) {
        let end = Date().addingTimeInterval(limit)
        var last: [CGRect] = []
        var still = 0
        while Date() < end, still < 4 {
            settle(panel, 0.05)
            let now = shapes(panel, model)
            still = Self.isStill(now, last) && !panel.hasPendingResize ? still + 1 : 0
            last = now
        }
    }

    /// The same shapes to within a quarter of a point: a spring's last hair of travel is not
    /// waited for (the checks below allow half a point).
    private static func isStill(_ now: [CGRect], _ last: [CGRect]) -> Bool {
        guard !now.isEmpty, now.count == last.count else { return false }
        return zip(now, last).allSatisfy { a, b in
            [a.minX - b.minX, a.minY - b.minY, a.width - b.width, a.height - b.height].allSatisfy { abs($0) <= stillness }
        }
    }

    private static let stillness: CGFloat = 0.25

    /// What `PillCoordinator.apply` does for a change of state, in either order: the app's panel
    /// follows the model one turn of the run loop later, and nothing promises which of the panel
    /// and SwiftUI gets there first.
    private func show(_ row: Row, on panel: PillPanel, _ model: PillModel, panelFirst: Bool) {
        let state = row.state()
        func content() {
            if let present = row.present { return present(model) }
            if case .failed(let failure) = state { model.present(failure: failure) } else { model.present(state, text: row.text ?? "") }
        }
        func frame() {
            panel.setInteractive(state.isInteractive)
            panel.setState(state)
        }
        if panelFirst {
            frame()
            content()
        } else {
            content()
            settle(panel, 0.03)
            frame()
        }
    }

    /// Every drawn shape, in screen points.
    private func shapes(_ panel: PillPanel, _ model: PillModel) -> [CGRect] {
        model.hitRegions.map { PillHitTest.screenRect($0, inWindow: panel.frame) }
    }

    private func union(_ rects: [CGRect]) -> CGRect? {
        rects.dropFirst().reduce(rects.first) { $0?.union($1) }
    }

    private func describe(_ panel: PillPanel, _ model: PillModel) -> String {
        "panel \(panel.frame) content \(String(describing: panel.contentView?.frame)) shapes \(model.hitRegions)"
    }

    // MARK: Rows

    @Test("at rest the pill is centred on its display's bottom edge", arguments: [PillAnchor.bottom, .top])
    func restIsCentred(anchor: PillAnchor) throws {
        let (panel, model) = try makePanel(anchor: anchor)
        let rest = try #require(union(shapes(panel, model)), "\(describe(panel, model))")
        #expect(abs(rest.width - PillMetrics.idle.width) < 1 && abs(rest.height - PillMetrics.idle.height) < 1)
        #expect(abs(rest.midX - Self.display.visible.midX) <= 0.5, "\(describe(panel, model))")
        panel.close()
    }

    @Test("the same when the panel hears of the change before the content does", arguments: sample)
    func rowIsCentredPanelFirst(row: Row) throws {
        let (panel, model) = try makePanel()
        show(row, on: panel, model, panelFirst: true)
        settleUntilStill(panel, model)
        let drawn = try #require(union(shapes(panel, model)), "\(describe(panel, model))")
        #expect(abs(drawn.midX - Self.display.visible.midX) <= 0.5,
                "\(row.name): centre \(drawn.midX), wanted \(Self.display.visible.midX). \(describe(panel, model))")
        panel.close()
    }

    @Test("a row is centred where the resting pill was, at every width", arguments: rows)
    func rowIsCentred(row: Row) throws {
        let (panel, model) = try makePanel()
        show(row, on: panel, model, panelFirst: false)
        settleUntilStill(panel, model)
        let drawn = try #require(union(shapes(panel, model)), "\(describe(panel, model))")
        #expect(abs(drawn.midX - Self.display.visible.midX) <= 0.5,
                "\(row.name): centre \(drawn.midX), wanted \(Self.display.visible.midX). \(describe(panel, model))")
        #expect(panel.frame.minX <= drawn.minX && drawn.maxX <= panel.frame.maxX, "the whole row is inside its panel")
        #expect(abs(panel.frame.midX - Self.display.visible.midX) <= 0.5, "the panel itself is centred")
        panel.close()
    }

    @Test("the same at the top edge", arguments: sample)
    func rowIsCentredAtTheTop(row: Row) throws {
        let (panel, model) = try makePanel(anchor: .top)
        show(row, on: panel, model, panelFirst: false)
        settleUntilStill(panel, model)
        let drawn = try #require(union(shapes(panel, model)), "\(describe(panel, model))")
        #expect(abs(drawn.midX - Self.display.visible.midX) <= 0.5,
                "\(row.name): centre \(drawn.midX), wanted \(Self.display.visible.midX). \(describe(panel, model))")
        panel.close()
    }

    // MARK: The panel itself

    @Test("at the bottom and top edges the panel has one frame for every row: it never moves sideways",
          arguments: [PillAnchor.bottom, .top])
    func panelNeverMovesSideways(anchor: PillAnchor) throws {
        let (panel, model) = try makePanel(anchor: anchor)
        let rest = panel.frame
        #expect(rest.width == PillPanel.centredWidth)
        #expect(abs(rest.midX - Self.display.visible.midX) <= 0.5)
        for row in Self.rows {
            show(row, on: panel, model, panelFirst: true)
            #expect(panel.frame.minX == rest.minX && panel.frame.width == rest.width, "\(row.name): \(panel.frame)")
            // Every state fits the one width, or the panel would have to grow for it after all.
            #expect(PillPanel.size(for: row.state(), anchor: anchor).width <= PillPanel.centredWidth, "\(row.name)")
        }
        panel.setState(.idle)
        panel.finishPendingResize()
        #expect(panel.frame == rest)
        panel.close()
    }

    @Test("the one width is used only where the pill is centred: at a side edge the panel hugs the edge at the state's own width")
    func sideEdgesKeepTheirOwnWidths() {
        for anchor in [PillAnchor.left, .right] {
            for row in Self.rows {
                let state = row.state()
                #expect(PillPanel.frameSize(for: state, anchor: anchor) == PillPanel.size(for: state, anchor: anchor), "\(row.name)")
            }
        }
        #expect(PillPanel.frameSize(for: .idle, anchor: .bottom) == NSSize(width: PillPanel.centredWidth, height: PillPanel.size.height))
    }

    // MARK: Closing a row

    @Test("closing a row never moves the pill's centre: not while the row leaves, not when the panel settles",
          arguments: closing)
    func closingKeepsTheCentre(row: Row) throws {
        let (panel, model) = try makePanel()
        let rest = panel.frame
        show(row, on: panel, model, panelFirst: false)
        settleUntilStill(panel, model)

        model.state = .idle
        settle(panel, 0.03)
        panel.setInteractive(PillState.idle.isInteractive)
        panel.setState(.idle)

        // Watch through the row's exit; half-way, land any waiting resize as its timer would
        // (a card's height: the timer is a task this test's own run loop does not run).
        var worst: (offset: CGFloat, at: Double, detail: String) = (0, 0, "")
        let started = Date()
        var landed = false
        while Date().timeIntervalSince(started) < 1.0 {
            settle(panel, 0.02)
            if !landed, Date().timeIntervalSince(started) >= 0.5 {
                landed = true
                panel.finishPendingResize()
            }
            // The resting capsule is the 40×10 shape (a hair smaller while it lands); a leaving
            // row may still be drawn around it.
            for shape in shapes(panel, model) where abs(shape.width - PillMetrics.idle.width) < 1 {
                let offset = abs(shape.midX - Self.display.visible.midX)
                if offset > worst.offset { worst = (offset, Date().timeIntervalSince(started), describe(panel, model)) }
            }
            #expect(panel.frame.minX == rest.minX && panel.frame.width == rest.width, "the panel stays where it is")
        }
        #expect(worst.offset <= 0.5, "\(row.name): the resting pill was \(worst.offset) pt off centre \(worst.at) s after closing. \(worst.detail)")
        settleUntilStill(panel, model)
        #expect(panel.frame == rest, "and the panel is back to its resting frame")
        let pill = try #require(union(shapes(panel, model)))
        #expect(abs(pill.width - PillMetrics.idle.width) < 1)
        #expect(abs(pill.midX - Self.display.visible.midX) <= 0.5)
        panel.close()
    }

    @Test("the pill's root view is exactly its panel: shapes are reported in the panel's own coordinates",
          arguments: ["failure: nothing to write", "failure: no words", "not pasted card"])
    func shapesAreInPanelCoordinates(name: String) throws {
        let row = try #require(Self.rows.first { $0.name == name })
        let (panel, model) = try makePanel()
        // Content first, in the small resting panel: the row is wider than the panel for a moment.
        // A panel narrower than the row (as the resting panel once was): the row overflows it
        // evenly, and its shape is still reported about the panel's own centre.
        let narrow = NSRect(x: panel.frame.midX - 140, y: panel.frame.minY, width: 280, height: panel.frame.height)
        panel.setFrame(narrow, display: true)
        let state = row.state()
        if case .failed(let failure) = state { model.present(failure: failure) } else { model.present(state, text: row.text ?? "") }
        settle(panel, 0.4)
        let early = try #require(union(model.hitRegions), "\(describe(panel, model))")
        #expect(early.width > narrow.width, "the row really is wider than this panel")
        #expect(abs(early.midX - narrow.width / 2) <= 0.5,
                "a row wider than its panel still reports its true place: \(describe(panel, model))")
        panel.close()
    }
}
