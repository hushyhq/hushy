import Foundation

/// What the not-pasted card is telling the user (founder, 2026-10-10: a dictation that was pasted
/// leaves no words on the pill; one that could not be pasted opens the pill to show the words,
/// with a clear way to copy them). Three reasons a dictation is not pasted get this card: no text
/// field, a paste that could not be confirmed, and a text field that could not be reached (focus
/// moved, or ⌘V could not be sent). A password field is the exception: its row never shows the words.
///
/// Whether the clipboard was written follows the delivery. The no-field policy may leave it
/// alone; an unconfirmed paste keeps its staged text, and a moved target copies it. Every card
/// has a Copy button: the person may have copied something else before noticing the card.
enum NoFieldMode: Equatable, Sendable {
    /// The clipboard is untouched. The card shows the text and a Copy button.
    case offerCopy
    /// Copy was just pressed: the same button reads "Copied" for a moment.
    case copied
    /// The text was copied for ⌘V when the dictation ended.
    case copiedAutomatically
    /// ⌘V went out but the paste could not be confirmed. The dictation staged for that paste is
    /// still on the clipboard; nothing was written a second time.
    case copiedAutomaticallyUnconfirmed
    /// "Copy again" was just pressed on that card.
    case copiedUnconfirmed
    /// There was a text field but the words did not go into it: focus moved before the paste, or
    /// ⌘V could not be sent. The text was copied for ⌘V when the dictation ended.
    case notPasted(CopyReason)
    /// "Copy again" was just pressed on that card.
    case notPastedCopiedAgain(CopyReason)
    /// There was a text field, the words did not go into it and the clipboard was left alone: the
    /// paste gave way to a newer one, or paste-last could not paste here. The card offers Copy.
    case plainNotPasted
    /// Copy was just pressed on that card.
    case plainNotPastedCopied

    /// The one plain reason, on every card.
    static let reason = "No text field to type into"
    static let unconfirmedReason = "Couldn't confirm the paste"
    static let plainReason = "Not pasted"
    var reasonLine: String {
        switch self {
        case .plainNotPasted, .plainNotPastedCopied: Self.plainReason
        case .copiedAutomaticallyUnconfirmed, .copiedUnconfirmed: Self.unconfirmedReason
        case .notPasted(let reason), .notPastedCopiedAgain(let reason): "Not pasted · \(reason.phrase)"
        case .offerCopy, .copied, .copiedAutomatically: Self.reason
        }
    }

    /// A second line under the reason, where the reason alone could mislead. An unconfirmed paste
    /// may in fact have landed, so pasting again without looking would put the text there twice.
    static let unconfirmedHint = "Check the field first. Your text may already be there."
    var hintLine: String? {
        switch self {
        case .copiedAutomaticallyUnconfirmed, .copiedUnconfirmed: Self.unconfirmedHint
        default: nil
        }
    }

    /// The text went to the clipboard when the dictation ended, before anyone pressed anything.
    var wasCopiedAutomatically: Bool {
        switch self {
        case .copiedAutomatically, .copiedAutomaticallyUnconfirmed, .notPasted: true
        default: false
        }
    }

    var copyButtonTitle: String {
        switch self {
        case .offerCopy, .plainNotPasted: "Copy"
        case .copiedAutomatically, .copiedAutomaticallyUnconfirmed, .notPasted: "Copy again"
        case .copied, .copiedUnconfirmed, .notPastedCopiedAgain, .plainNotPastedCopied: "Copied"
        }
    }

    /// What the card becomes when its button is pressed; nil once it has been.
    var afterCopy: NoFieldMode? {
        switch self {
        case .offerCopy, .copiedAutomatically: .copied
        case .copiedAutomaticallyUnconfirmed: .copiedUnconfirmed
        case .notPasted(let reason): .notPastedCopiedAgain(reason)
        case .plainNotPasted: .plainNotPastedCopied
        case .copied, .copiedUnconfirmed, .notPastedCopiedAgain, .plainNotPastedCopied: nil
        }
    }

    /// The line beside the button when the clipboard was already written: the smallest way to say so.
    var statusLine: String? {
        if self == .copiedAutomaticallyUnconfirmed { return "On clipboard · ⌘V" }
        return wasCopiedAutomatically ? "Copied to clipboard" : nil
    }

    /// The quiet line beside the card's button: how to get this dictation back later, when the
    /// card has gone or the clipboard has moved on. Words, not a row of key caps.
    var recoveryLine: String { ShortcutHelp.pasteLastLine }

    /// What the capsule under the card says when the text is not on the clipboard (it then names
    /// copy last beside it). Nil once the text is there: the capsule says that instead.
    var capsuleLabel: String? {
        switch self {
        case .offerCopy: "Not typed"
        case .plainNotPasted: "Not pasted"
        default: nil
        }
    }

    /// What VoiceOver reads for the card and the pill. Never the dictated words.
    var accessibilityText: String {
        switch self {
        case .offerCopy, .plainNotPasted: "\(reasonLine). Press Copy to copy what you said."
        case .copied, .copiedUnconfirmed, .notPastedCopiedAgain, .plainNotPastedCopied: "\(reasonLine). Copied."
        case .copiedAutomatically: "\(reasonLine). Copied to the clipboard."
        case .copiedAutomaticallyUnconfirmed: "\(reasonLine). \(Self.unconfirmedHint) Copied to the clipboard."
        case .notPasted(let reason): reason.accessibilityText
        }
    }

    /// The shortest the card stays when nobody touches it (the pointer resting on it holds it
    /// longer, `selfDismissDecision`; a long dictation gets reading time, `dismissDelay(words:)`).
    /// Long enough to read and reach the button; short once it was pressed.
    var dismissDelay: Duration {
        switch self {
        case .offerCopy, .copiedAutomatically, .notPasted, .plainNotPasted: .seconds(10)
        case .copiedAutomaticallyUnconfirmed: .seconds(8)
        case .copied, .copiedUnconfirmed, .notPastedCopiedAgain, .plainNotPastedCopied: .milliseconds(1_400)
        }
    }

    /// How long the card stays for a dictation of `words` words: never less than `dismissDelay`,
    /// and long enough to read all of it (`NoFieldReading`). Once Copy was pressed the card has
    /// done its job and closes on the short delay whatever its length.
    func dismissDelay(words: Int) -> Duration {
        afterCopy == nil ? dismissDelay : NoFieldReading.delay(atLeast: dismissDelay, words: words)
    }
}

/// How long an untouched not-pasted card waits before it closes, by the length of what it shows:
/// a moment to notice it, then the time a careful reader needs for every word, up to a limit so a
/// card nobody is looking at does not sit over their work for good.
enum NoFieldReading {
    /// Before reading starts: seeing that the pill opened.
    static let noticeSeconds = 4.0
    /// About 180 words a minute: slower than most people read, so nobody is hurried.
    static let wordsPerSecond = 3.0
    /// The longest an untouched card stays.
    static let longest: Duration = .seconds(60)

    static func delay(atLeast floor: Duration, words: Int) -> Duration {
        let reading = Duration.seconds(noticeSeconds + Double(max(0, words)) / wordsPerSecond)
        return min(max(floor, reading), max(floor, longest))
    }
}

/// The dictated text as the card shows it: every word, with whitespace collapsed to single
/// spaces so a short dictation stays three lines or fewer. Nothing is cut: a long dictation
/// scrolls inside the card (`NoFieldCard.textMaxHeight`), and Copy takes the text as it was saved.
enum NoFieldText {
    static func display(_ text: String) -> String {
        text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }
}

/// What the pill's own timer does when a self-dismissing row's time is up.
enum SelfDismissDecision: Equatable {
    case dismiss
    /// Not yet: look again after this long.
    case wait(Duration)
}

extension PillState {
    /// How long after the pointer leaves the card (at most) it goes.
    static let pointerGrace: Duration = .milliseconds(1_500)
    /// "Not pasted · password field [Copy]" stays long enough to reach a button.
    static let heldDelay: Duration = .seconds(6)

    /// Rows that hold a dictation that was not pasted: the card, and the password-field row.
    /// Someone may be reading one or reaching for its button when its time is up.
    var holdsUnpastedWords: Bool {
        switch self {
        case .noField, .held(copied: false): true
        default: false
        }
    }

    /// What to do when `selfDismissDelay` is up. A row holding words that were not pasted stays
    /// while the pointer is over it or its capsule (the user is reading it or reaching for a
    /// button); everything else goes on time. VoiceOver cannot point: while it is running, a row
    /// that still has its Copy waits until it is acted on or dismissed.
    func selfDismissDecision(pointerOverCard: Bool, voiceOverRunning: Bool = false) -> SelfDismissDecision {
        // The quiet "Pasted" row follows every dictation in an app Hushy cannot read, so for a
        // sighted person only the pointer keeps it up. VoiceOver cannot point and cannot reach an
        // action on a row that has gone: while it is running the row waits, as the cards do, until
        // it is opened, dismissed or the next dictation starts.
        if self == .pastedUnchecked {
            return pointerOverCard || voiceOverRunning ? .wait(Self.pointerGrace) : .dismiss
        }
        // An offer stays while the pointer is on the pill; once added, its line goes on time.
        if let phase = nameOfferPhase, phase != .added {
            return pointerOverCard ? .wait(Self.pointerGrace) : .dismiss
        }
        guard holdsUnpastedWords else { return .dismiss }
        let waitsForVoiceOver = voiceOverRunning && recoveryActions.contains(.copy)
        guard pointerOverCard || waitsForVoiceOver else { return .dismiss }
        return .wait(Self.pointerGrace)
    }
}

/// Copy last (⌃⌘C): what the shortcut does with the most recent dictation.
enum CopyLast {
    enum Outcome: Equatable {
        case copy(String)
        case nothingToCopy
    }

    static let nothingMessage = "Nothing to copy yet"

    /// The text exactly as saved, or nothing when there is none worth copying.
    static func resolve(lastText: String?) -> Outcome {
        guard let lastText, !lastText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return .nothingToCopy
        }
        return .copy(lastText)
    }
}

/// The shortcuts as the app words them, so Settings and the docs agree.
enum ShortcutHelp {
    static let pasteLast = "⌃⌘V"
    static let copyLast = "⌃⌘C"
    /// The same chord as separate key caps, for the pill.
    static let copyLastKeys = ["⌃", "⌘", "C"]
    /// Paste last, said in words where a dictation was just not pasted (the keys are fixed, so
    /// this is the person's own shortcut: `HotkeyMonitor.globalShortcut`).
    static let pasteLastLine = "\(pasteLast) pastes your last dictation"
    /// The same line as VoiceOver says it.
    static let pasteLastSpoken = "Control Command V pastes your last dictation."
    static func settingsLine(actionKey: ActionTriggerKey) -> String {
        "Hands-free: ↩ finish · Esc cancel. Voice action: press \(actionKey.phrase), or hold fn + control. "
            + "Paste last \(pasteLast) · Copy last \(copyLast) · Record note ⇧⌘N"
    }
}
