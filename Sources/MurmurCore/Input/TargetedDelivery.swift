import Foundation

/// The side effects `TargetedDelivery` needs: the app's clipboard paster (real pasteboard +
/// synthesized keys) or a fake in tests. `hasFocus` is re-run by `BoundDelivery` before the
/// clipboard write, before ⌘V and before Return.
@MainActor
public protocol DeliveryPaster: AnyObject {
    /// Stages once and pastes. With `awaitLanding` (an uncertain target) the clipboard is held as
    /// staged until `finishLanding` is called with the same value.
    func paste(_ text: String, pressReturn: Bool, awaitLanding: PasteLanding?,
               hasFocus: @escaping () -> Bool) async -> BoundDelivery.Outcome
    /// Settles the clipboard of the paste that was started with `landing`, without writing the
    /// text again. A paste that is no longer the pending one (a newer paste or copy took the
    /// clipboard) is left alone: a late call never settles someone else's staging.
    func finishLanding(_ landing: PasteLanding, as settlement: LandingSettlement)
    /// Sends Return alone (a command-only "press enter"); never touches the clipboard.
    func sendReturn(hasFocus: @escaping () -> Bool) async -> BoundDelivery.Outcome
    /// Leaves `text` on the clipboard for the user to paste themselves (⌘V). Cancels any pending
    /// restore, so an earlier paste's restore can't overwrite it.
    func copyForManualPaste(_ text: String)
}

/// Names one paste whose clipboard is held until its landing check ends. Made by the caller, so
/// the settle call can only ever reach the paste it belongs to.
public struct PasteLanding: Hashable, Sendable {
    private let id = UUID()
    public init() {}
}

/// How a held clipboard ends once the landing check is over.
public enum LandingSettlement: Sendable, Equatable {
    /// The paste landed: the earlier clipboard comes back, unless "keep dictations on the
    /// clipboard" is on.
    case confirmed
    /// The landing could not be confirmed: the staged dictation stays on the clipboard.
    case unconfirmed
    /// The dictation is not the person's to paste again (they cancelled it, or a password field
    /// has focus): the earlier clipboard comes back, whatever the setting.
    case withdrawn
}

/// Where a finished dictation's text went. `DictationController` maps it to the History status,
/// the pill and the `delivery=` part of the dictation log line.
public enum DeliveryResult: Sendable, Equatable {
    /// Pasted into the key-down field (and Return sent, if asked).
    case pasted
    /// Pasted into the key-down field, but Return was withheld: focus moved during the short
    /// pre-Return wait (`change`), or (nil) the dictation was cancelled, superseded, or the
    /// clipboard changed under it then.
    case pastedReturnSkipped(TargetChange?)
    /// Command-only ("press enter"): Return reached the key-down field.
    case returnSent
    /// Command-only and the target moved or is a password field: nothing was sent anywhere.
    case returnWithheld(TargetChange?)
    /// The target moved: nothing was pasted; the text is on the clipboard for ⌘V and in History.
    case copied(TargetChange)
    /// A password field has focus: nothing was pasted and the clipboard was left alone.
    case heldForSecureField(TargetChange?)
    /// Nothing editable had focus at key-down: nothing was pasted. `copied` when the text was
    /// left on the clipboard for ⌘V (`NoFieldClipboardPolicy.copyAutomatically`); false when the
    /// clipboard was left alone, or there was no text at all (a lone "press enter").
    case noField(copied: Bool)
    /// The target was uncertain at key-down; ⌘V was dispatched and a read of the field showed the
    /// paste: the count changed, or the caret advanced by the pasted length (`LandingEvidence`).
    case unknownConfirmed
    case unknownConfirmedReturnSkipped(TargetChange?)
    /// The field could not be read well enough to tell: no count and no usable caret, a different
    /// field by the second read, or a caret that moved some other way. The staged dictation
    /// remains on the clipboard.
    case unknownUnreadable
    case unknownUnreadableReturnSkipped(TargetChange?)
    /// A readable count stayed unchanged after ⌘V for the landing window, and no selection could
    /// explain it. The staged dictation remains on the clipboard.
    case unknownNotLanded
    /// ⌘V went to an uncertain target and the person cancelled before the landing was known.
    /// The paste stands as sent; the earlier clipboard is restored.
    case unknownCancelled
    /// Keyboard events couldn't be created or the clipboard couldn't be written: nothing reached
    /// the field. `copied` when the text was then left on the clipboard for ⌘V.
    case dispatchFailed(copied: Bool)
    /// Cancelled (Esc) or superseded by a newer insertion before anything was dispatched.
    case cancelled

    /// True when the text reached the key-down field.
    public var reachedTarget: Bool {
        switch self {
        case .pasted, .pastedReturnSkipped, .returnSent, .unknownConfirmed,
             .unknownConfirmedReturnSkipped: true
        default: false
        }
    }

    /// `delivery=… reason=…` for the dictation log line. Carries no text.
    public var logSummary: String {
        switch self {
        case .pasted: "delivery=pasted"
        case .pastedReturnSkipped(let change): "delivery=pasted-no-return reason=\(Self.reason(change, fallback: "not-current"))"
        case .returnSent: "delivery=return-sent"
        case .returnWithheld(let change): "delivery=return-withheld reason=\(Self.reason(change, fallback: "secure-field"))"
        case .copied(let change): "delivery=copied reason=target-changed:\(change.rawValue)"
        case .heldForSecureField(let change):
            "delivery=held reason=secure-field" + (change.map { " target-changed:\($0.rawValue)" } ?? "")
        case .noField(let copied): "delivery=\(copied ? "copied" : "not-pasted") reason=no-field"
        case .unknownConfirmed: "delivery=pasted landing=confirmed"
        case .unknownConfirmedReturnSkipped(let change):
            "delivery=pasted-no-return reason=\(Self.reason(change, fallback: "not-current")) landing=confirmed"
        case .unknownUnreadable: "delivery=pasted landing=unreadable clipboard=kept reason=unconfirmed"
        case .unknownUnreadableReturnSkipped(let change):
            "delivery=pasted-no-return reason=\(Self.reason(change, fallback: "not-current")) landing=unreadable clipboard=kept"
        case .unknownNotLanded: "delivery=copied reason=paste-unconfirmed landing=not-landed clipboard=kept"
        case .unknownCancelled: "delivery=pasted landing=cancelled clipboard=restored"
        case .dispatchFailed(let copied): "delivery=\(copied ? "copied" : "not-pasted") reason=dispatch-failed"
        case .cancelled: "delivery=not-pasted reason=cancelled"
        }
    }

    /// Fixed log token for unknown paths that exit before a landing check.
    public var hasUnknownLandingCheck: Bool {
        switch self {
        case .unknownConfirmed, .unknownConfirmedReturnSkipped, .unknownUnreadable,
             .unknownUnreadableReturnSkipped, .unknownNotLanded, .unknownCancelled: true
        default: false
        }
    }

    private static func reason(_ change: TargetChange?, fallback: String) -> String {
        change.map { "target-changed:\($0.rawValue)" } ?? fallback
    }
}

/// A paste into a field Hushy was sure of, with the read of the field made at key-down.
public struct FieldPasteWatch: Sendable, Equatable {
    public let before: LandingProbe
    public let pasted: PastedText

    public init(before: LandingProbe, pasted: PastedText) {
        self.before = before
        self.pasted = pasted
    }
}

/// What the late look at a known field found.
public enum LateLanding: Sendable, Equatable {
    /// The count changed or the caret moved the way a paste moves it.
    case confirmed
    /// The field could not be read well enough to say, or the look was cancelled. Nothing changes.
    case unreadable
    /// The field was read before and after, never changed, and no selection explains it.
    case notLanded
}

/// The paste policy when focus may have moved between key-down and paste (2026-09-25 review P1;
/// DECISIONS 2026-09-27 "Focus moved before the paste"):
///
/// - Same field as key-down → paste, re-checking before ⌘V and before Return (`BoundDelivery`).
/// - Target moved (another app, window or field, or the field closed) → never paste. Leave the
///   text on the clipboard for ⌘V and in History; the pill says so. Never re-activate the old app.
/// - A password field has focus → never paste and don't stage the text on the clipboard either.
/// - No field at key-down → nothing is pasted or sent. Whether the text is also copied for ⌘V is
///   `NoFieldClipboardPolicy` (default: copied for ⌘V and the pill shows the text). A password
///   field focused by then still wins and holds.
/// - ⌘V couldn't be sent → nothing reached a field; copy for ⌘V like a moved target (UI round
///   2026-09-28 §1), unless a password field has focus by then.
/// - Command-only "press enter" with a moved target → send nothing.
///
/// `check` reads live focus (`TargetGuard.check` in the app). Hands-free and streamed long
/// dictations go through the same single check at the end: nothing is pasted before it.
@MainActor
public enum TargetedDelivery {
    /// Three-way path used by dictation. The bool overload remains for existing callers.
    public static func deliver(
        text: String, pressReturn: Bool, answer: FocusAnswer,
        check: @escaping () -> TargetVerdict, landing: @escaping () -> LandingProbe?,
        noFieldClipboard: NoFieldClipboardPolicy = .current, paster: some DeliveryPaster,
        fieldBaseline: LandingProbe? = nil, onFieldPaste: ((FieldPasteWatch) -> Void)? = nil
    ) async -> DeliveryResult {
        guard answer == .unknown, !text.isEmpty else {
            // A field Hushy is sure of is pasted as before and reported at once, and nothing is read
            // on the way: not before ⌘V and not after it. With a watcher asked for and a read of the
            // field from key-down (`fieldBaseline`), the caller can look again after the pill has
            // answered (`FieldPasteWatch`). No watch follows a Return: a composer that sends and
            // clears itself reads as unchanged whether or not the paste landed.
            let result = await deliver(text: text, pressReturn: pressReturn, hasTextInput: answer != .noField,
                                       check: check, noFieldClipboard: noFieldClipboard, paster: paster)
            if result == .pasted, answer == .field, !pressReturn, let fieldBaseline, let onFieldPaste {
                onFieldPaste(FieldPasteWatch(before: fieldBaseline, pasted: PastedText(text)))
            }
            return result
        }
        // Read only numbers (a character count, a selection length, a caret position), before and
        // after ⌘V. Hold this paste's restore until the landing result is known; the staged item
        // itself becomes the manual copy.
        let before = landing()
        let held = PasteLanding()
        let result = await deliver(text: text, pressReturn: false, hasTextInput: true,
                                   check: check, noFieldClipboard: noFieldClipboard, paster: paster,
                                   awaitLanding: held)
        guard result == .pasted else { return result }
        let landingCheck = await landingStatus(before: before, pasted: PastedText(text), read: landing)
        guard case .landed(let status) = landingCheck else {
            if case .secureField(let change) = check() {
                paster.finishLanding(held, as: .withdrawn)
                return .heldForSecureField(change)
            }
            return settleUnconfirmed(held, paster: paster, otherwise: .unknownNotLanded)
        }
        // A confirmed paste settles at once. An unreadable one stays held through the Return step,
        // so a cancel during that wait still takes the dictation off the clipboard.
        if status == .confirmed { paster.finishLanding(held, as: .confirmed) }
        // A command-only Return is sent only after a paste that may have landed. The same
        // live guard still runs before Return; a failed/changed target withholds it.
        var returnSkipped = false
        var returnChange: TargetChange?
        if pressReturn {
            let sent = await deliverReturnOnly(check: check, hasFocus: { check() == .unchanged }, paster: paster)
            if sent != .returnSent {
                returnSkipped = true
                if case .returnWithheld(let change) = sent { returnChange = change }
                else { returnChange = change(in: check()) }
            }
        }
        if status == .confirmed {
            if returnSkipped { return .unknownConfirmedReturnSkipped(returnChange) }
            return .unknownConfirmed
        }
        return settleUnconfirmed(
            held, paster: paster,
            otherwise: returnSkipped ? .unknownUnreadableReturnSkipped(returnChange) : .unknownUnreadable)
    }

    /// The end of a paste that could not be confirmed. Normally the staged dictation stays on the
    /// clipboard and the pill shows it. If the person cancelled (Esc) after ⌘V went out, nothing
    /// will show them the text, so it does not stay: the earlier clipboard comes back, as after a
    /// confirmed paste, and the paste is reported as sent, never as cancelled or as not landed.
    private static func settleUnconfirmed(
        _ held: PasteLanding, paster: some DeliveryPaster, otherwise result: DeliveryResult
    ) -> DeliveryResult {
        guard !Task.isCancelled else {
            paster.finishLanding(held, as: .withdrawn)
            return .unknownCancelled
        }
        paster.finishLanding(held, as: .unconfirmed)
        return result
    }

    /// The late look at a field that took a paste Hushy had no doubt about. Same reads, same evidence and
    /// the same polling as the check after an uncertain paste (`LandingEvidence`), run by the caller
    /// once the pill has shown the result. A read that cannot decide, and a cancelled look, say
    /// `.unreadable`: only a field that was read, did not change and had no selection to explain
    /// it says `.notLanded`.
    ///
    /// The look gives up, as `.unreadable`, once `limit` has passed since it began: no read starts after
    /// that, so slow reads of another app cannot keep the main actor for long.
    public static func lateLanding(
        _ watch: FieldPasteWatch, within limit: Duration = lateLookLimit, read: () -> LandingProbe?
    ) async -> LateLanding {
        let status = await landingStatus(before: watch.before, pasted: watch.pasted, within: limit, read: read)
        guard !Task.isCancelled else { return .unreadable }
        switch status {
        case .landed(.confirmed): return .confirmed
        case .landed(.unreadable): return .unreadable
        case .notLanded: return .notLanded
        }
    }

    /// Five 120 ms waits and their reads take about 600 ms when the reads are quick. A look that has
    /// run for more than three times that is reading a slow app, or the Mac is struggling.
    public static let lateLookLimit: Duration = .seconds(2)

    private static func landingStatus(
        before: LandingProbe?, pasted: PastedText, within limit: Duration? = nil, read: () -> LandingProbe?
    ) async -> LandingCheck {
        let deadline = limit.map { ContinuousClock.now + $0 }
        // Five 120 ms intervals cover late AX updates (~600 ms). Return follows the first
        // positive read; a field that cannot be read waits for only the first interval.
        //
        // The reads are polled. A value-changed notification from the focused text element would
        // confirm sooner, and where nothing can be read before ⌘V; it would be one more
        // `LandingSignal`, registered before the paste and raced with this loop. Not built yet:
        // no test here can exercise an observer on another app.
        var last: LandingProbe?
        for _ in 0..<5 {
            // Cancelled (Esc) after ⌘V went out: stop reading at once. The caller sees the
            // cancellation and reports the paste as sent, never as not landed.
            do { try await Task.sleep(for: .milliseconds(120)) } catch { return .landed(.unreadable) }
            if let deadline, ContinuousClock.now >= deadline { return .landed(.unreadable) }
            let after = read()
            guard let before, let after else { return .landed(.unreadable) }
            if LandingEvidence.signal(before: before, after: after, pasted: pasted) != nil { return .landed(.confirmed) }
            last = after
        }
        guard let before, let last,
              LandingEvidence.wasReadAndUnchanged(before: before, last: last, pasted: pasted) else {
            return .landed(.unreadable)
        }
        return .notLanded
    }

    private enum LandedStatus: Equatable { case confirmed, unreadable }
    private enum LandingCheck: Equatable { case landed(LandedStatus), notLanded }

    public static func deliver(
        text: String, pressReturn: Bool, hasTextInput: Bool,
        check: @escaping () -> TargetVerdict,
        noFieldClipboard: NoFieldClipboardPolicy = .current, paster: some DeliveryPaster,
        awaitLanding: PasteLanding? = nil
    ) async -> DeliveryResult {
        // Cancellation first: a superseded dictation must not copy over a newer one.
        guard !Task.isCancelled else { return .cancelled }
        guard hasTextInput else {
            return deliverWithoutField(text, check: check, policy: noFieldClipboard, paster: paster)
        }
        let hasFocus = { check() == .unchanged }
        if text.isEmpty {
            guard pressReturn else { return .dispatchFailed(copied: false) }
            return await deliverReturnOnly(check: check, hasFocus: hasFocus, paster: paster)
        }
        switch check() {
        case .unchanged: break
        case .secureField(let change): return .heldForSecureField(change)
        case .changed(let change):
            paster.copyForManualPaste(text)
            return .copied(change)
        }
        switch await paster.paste(text, pressReturn: pressReturn, awaitLanding: awaitLanding, hasFocus: hasFocus) {
        case .pasted: return .pasted
        case .dispatchFailed: return copyAfterFailedPaste(text, check: check, paster: paster)
        case .pastedReturnSkipped:
            guard !Task.isCancelled else { return .pastedReturnSkipped(nil) }
            return .pastedReturnSkipped(change(in: check()))
        case .focusChanged:
            // Focus moved between the first check and ⌘V (the paster may already have staged the
            // text; its scheduled restore still owns the clipboard until we copy over it).
            guard !Task.isCancelled else { return .cancelled }
            switch check() {
            case .unchanged: return .cancelled // superseded by a newer insertion
            case .secureField(let change): return .heldForSecureField(change)
            case .changed(let change):
                paster.copyForManualPaste(text)
                return .copied(change)
            }
        }
    }

    private static func deliverReturnOnly(
        check: () -> TargetVerdict, hasFocus: @escaping () -> Bool, paster: some DeliveryPaster
    ) async -> DeliveryResult {
        let before = check()
        guard before == .unchanged else { return .returnWithheld(change(in: before)) }
        switch await paster.sendReturn(hasFocus: hasFocus) {
        case .pasted, .pastedReturnSkipped: return .returnSent
        case .dispatchFailed: return .dispatchFailed(copied: false)
        case .focusChanged:
            guard !Task.isCancelled else { return .cancelled }
            let after = check()
            return after == .unchanged ? .cancelled : .returnWithheld(change(in: after))
        }
    }

    /// Nothing editable had focus at key-down. Never paste (a field found later doesn't rescue it)
    /// and never send Return. The text goes to the clipboard only when the policy says so, and
    /// never beside a password field.
    private static func deliverWithoutField(
        _ text: String, check: () -> TargetVerdict, policy: NoFieldClipboardPolicy, paster: some DeliveryPaster
    ) -> DeliveryResult {
        guard !text.isEmpty else { return .noField(copied: false) }
        if case .secureField(let change) = check() { return .heldForSecureField(change) }
        guard policy.copiesAutomatically else { return .noField(copied: false) }
        paster.copyForManualPaste(text)
        return .noField(copied: true)
    }

    /// ⌘V couldn't be sent (or the clipboard couldn't be staged), so nothing reached the field.
    /// Copy for ⌘V — this also cancels the staged paste's pending restore — unless the dictation
    /// was superseded meanwhile or a password field has focus now.
    private static func copyAfterFailedPaste(
        _ text: String, check: () -> TargetVerdict, paster: some DeliveryPaster
    ) -> DeliveryResult {
        guard !Task.isCancelled else { return .cancelled }
        if case .secureField(let change) = check() { return .heldForSecureField(change) }
        paster.copyForManualPaste(text)
        return .dispatchFailed(copied: true)
    }

    private static func change(in verdict: TargetVerdict) -> TargetChange? {
        switch verdict {
        case .unchanged: nil
        case .changed(let change): change
        case .secureField(let change): change
        }
    }
}
