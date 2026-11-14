import AppKit
import Carbon.HIToolbox
import MurmurCore
import os

/// Inserts text into the focused app by pasting, then restores the user's clipboard.
/// The clipboard/key mechanics live in `ClipboardPaster`; the "did focus move?" policy in
/// `TargetedDelivery` + `TargetGuard` (MurmurCore), so both are testable without real apps.
@MainActor
enum TextInserter {
    typealias InsertOutcome = BoundDelivery.Outcome

    /// The one paster for the system clipboard, so every paste shares one restore ledger.
    static let shared = ClipboardPaster(pasteboard: .general, postKey: postSystemKey,
                                        pasteKey: { PasteKeyboard.shared.pasteKeyCode })

    /// What `deliver` hands back. `field` is the one the delivery was bound to: the key-down field, or the
    /// field a late look adopted when key-down saw none. The edit watcher looks at that one afterwards.
    ///
    /// `lateLanding` is set for a paste into a field Hushy was sure of, read at key-down, and sent without Return.
    /// Awaiting it looks at the field again, off the hot path, and says whether the text is there.
    struct Delivered {
        let result: DeliveryResult
        let answer: FocusAnswer
        let field: AXUIElement?
        let lateLanding: (@MainActor () async -> LateLanding)?
    }

    /// The guard and the reads of the bound field. Live, the Accessibility API; a test scripts both.
    struct FieldAccess {
        var verdict: @MainActor () -> TargetVerdict
        /// One read of the field's numbers. `afterPaste` bounds the guard check inside the read as well.
        var read: @MainActor (_ budget: AXReadBudget, _ afterPaste: Bool) -> (probe: LandingProbe?, status: PasteDiagnosis.Probe)

        @MainActor
        static func live(_ bound: FocusTarget) -> FieldAccess {
            var pin = LandingPin<AXUIElement>()
            return FieldAccess(
                verdict: { bound.verdict() },
                read: { budget, afterPaste in bound.landingRead(pin: &pin, budget: budget, boundedGuard: afterPaste) })
        }
    }

    /// A finished dictation: paste into the key-down field if it still has focus; otherwise copy
    /// (target moved), hold (password field) or withhold Return. See `TargetedDelivery`.
    /// `alsoRequire` is asked with the focus check, last, right before ⌘V; false is treated as a moved field (copied).
    /// `paster` and `access` (the guard and field reads) are the system clipboard and Accessibility; tests pass their own.
    static func deliver(
        _ text: String, to target: FocusTarget, pressReturn: Bool, alsoRequire: @escaping @MainActor () -> Bool = { true },
        paster: any DeliveryPaster = TextInserter.shared,
        access makeAccess: @MainActor (FocusTarget) -> FieldAccess = FieldAccess.live
    ) async -> Delivered {
        // One budget for everything Hushy reads for itself before ⌘V: the look for a late field
        // and, for an uncertain target, the read of the field before the paste. Each read after the paste gets its own.
        let beforePaste = AXReadBudget()
        let bound = target.refreshedForDelivery(budget: beforePaste)
        let access = makeAccess(bound)
        var reads = LandingReadLog()
        var isFirstRead = true
        var watch: FieldPasteWatch?
        let result = await TargetedDelivery.deliver(
            text: text, pressReturn: pressReturn, answer: bound.answer,
            check: {
                let verdict = access.verdict()
                guard verdict == .unchanged else { return verdict }
                return alsoRequire() ? .unchanged : .changed(.field)
            },
            landing: {
                let read = access.read(isFirstRead ? beforePaste : AXReadBudget(), false)
                isFirstRead = false
                reads.record(read.probe, read.status)
                return read.probe
            }, paster: paster, fieldBaseline: bound.fieldBaseline, onFieldPaste: { watch = $0 })
        // Record the key-down AX facts for uncertain pastes and for copy-only decisions. In
        // particular, a no-field decision has no landing reads, so this is the only evidence
        // of which role (or failed query) made us withhold ⌘V.
        if !text.isEmpty, shouldLogPasteDiagnosis(answer: target.answer, result: result) {
            let diagnosis = PasteDiagnosis(
                bundleID: target.bundleID, category: target.category.rawValue, answer: target.answer,
                focus: target.keyDownFocus,
                adopted: bound.adoptedLateField, before: reads.before, after: reads.after,
                signal: reads.signal(pasted: PastedText(text)))
            log.notice("\(diagnosis.line, privacy: .public)")
        }
        var lateLanding: (@MainActor () async -> LateLanding)?
        if let watch {
            lateLanding = { await TargetedDelivery.lateLanding(watch) { access.read(AXReadBudget(), true).probe } }
        }
        return Delivered(result: result, answer: bound.answer, field: bound.editObservationElement, lateLanding: lateLanding)
    }

    private static let log = Logger(subsystem: "app.hushy", category: "dictation")

    static func shouldLogPasteDiagnosis(answer: FocusAnswer, result: DeliveryResult) -> Bool {
        if answer == .unknown { return true }
        switch result {
        case .noField, .copied, .dispatchFailed(copied: true): return true
        default: return false
        }
    }

    /// Pastes into `target` only while it still owns focus (paste last, voice actions — they
    /// capture the target immediately before calling this).
    static func insert(_ text: String, into target: FocusTarget, pressEnter: Bool = false) async -> InsertOutcome {
        await shared.paste(text, pressReturn: pressEnter, awaitLanding: nil,
                           hasFocus: { target.stillOwnsFocus() })
    }

    /// Dictation is starting: have the paste key for this keyboard layout ready, so the first
    /// paste after launch (or after a layout change) does not stop to work it out. The front app's
    /// accessibility tree is asked for off the main thread (`FocusTarget.exposeAccessibility`).
    static func preparePasteKey() {
        _ = PasteKeyboard.shared.pasteKeyCode
    }

    /// A copy the user asked for. `markTransient` for text that shouldn't enter clipboard history
    /// (the password-field row's Copy).
    static func copy(_ text: String, markTransient: Bool = false) {
        shared.copy(text, markTransient: markTransient)
    }

    private static func postSystemKey(_ key: CGKeyCode, flags: CGEventFlags) -> Bool {
        let source = CGEventSource(stateID: .combinedSessionState)
        let down = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: true)
        let up = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: false)
        // Explicit flags keep physically held modifiers (e.g. fn) out of the shortcut.
        down?.flags = flags
        up?.flags = flags
        guard let down, let up else { return false }
        down.post(tap: .cgAnnotatedSessionEventTap)
        up.post(tap: .cgAnnotatedSessionEventTap)
        return true
    }
}
