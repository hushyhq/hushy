import AppKit
import CoreText
import MurmurCore
import SwiftUI

/// The voice-action pill (founder, 2026-10-10: "too big of a bar. I need it as small as a pill. It
/// should just have a tick and a cancel button, same as the pill"). One grammar for every capsule
/// an action draws: ✕ at the left end to get rid of it, a bolt so it never reads as dictation, the
/// thing itself, and at the right end the one way forward (✓, Undo, Retry). The keys are not
/// written on the pill; a hover on ✕ or ✓ names them (`pillKeyHint`).

/// How a voice action is being heard, which decides what the listening pill draws.
enum ActionListeningMode: Equatable {
    /// fn + control is held: letting go sends, as with dictation's key. No buttons.
    case held
    /// Nothing is held (the action key pressed twice, or the pill's ⚡ button): ✕ and ✓, like
    /// hands-free dictation. `cancelKey` is the key whose single tap also cancels (double tap only).
    case latched(cancelKey: String?)
}

/// What the capsule holds while an action is heard or worked on, as a list of parts. Pure, so the
/// tests can pin its size against dictation's pill and check that no state loses its way out.
struct ActionPillLayout: Equatable {
    enum Part: Equatable {
        /// The round ✕ (esc does the same).
        case cancel
        /// The bolt: this is an action, not dictation.
        case bolt
        /// The level meter, dictation's own bars.
        case meter
        /// The round lime ✓ (return does the same).
        case send
        /// Three purple dots: the command is being worked on.
        case dots
    }

    let parts: [Part]
    /// The capsule's size when it is fixed rather than fitted, as dictation's Listening is.
    var fixedSize: CGSize?

    static func listening(_ mode: ActionListeningMode) -> ActionPillLayout {
        switch mode {
        case .held: ActionPillLayout(parts: [.bolt, .meter], fixedSize: PillMetrics.listening)
        case .latched: ActionPillLayout(parts: [.cancel, .bolt, .meter, .send])
        }
    }

    /// "Working": ✕ stays where it was, the bolt turns purple, the bars become dots.
    static let working = ActionPillLayout(parts: [.cancel, .bolt, .dots])

    /// The same numbers as dictation's hands-free capsule (`PillView`).
    static let spacing: CGFloat = 8
    static let endPadding: CGFloat = 10
    static let height: CGFloat = 30
    static let buttonDiameter: CGFloat = 20
    static let boltWidth: CGFloat = 8
    static let meterWidth = CGFloat(PillModel.barCount) * WaveformMetrics.dictation.barWidth
        + CGFloat(PillModel.barCount - 1) * WaveformMetrics.dictation.spacing
    static let dotsWidth: CGFloat = 23

    static func width(of part: Part) -> CGFloat {
        switch part {
        case .cancel, .send: buttonDiameter
        case .bolt: boltWidth
        case .meter: meterWidth
        case .dots: dotsWidth
        }
    }

    /// The horizontal capsule's width in points.
    var width: CGFloat {
        if let fixedSize { return fixedSize.width }
        let content = parts.reduce(CGFloat(0)) { $0 + Self.width(of: $1) }
        return content + Self.spacing * CGFloat(max(parts.count - 1, 0)) + 2 * Self.endPadding
    }

    /// Dictation's hands-free capsule without its timer (✕, bars, ✓): the action pill is this plus
    /// a bolt, and has no timer, so it is never the wider of the two.
    static let dictationHandsFreeWidthWithoutTimer =
        2 * endPadding + 2 * buttonDiameter + meterWidth + 2 * spacing

    /// Whether the mouse alone can leave this state (the keyboard always can: esc).
    var hasCancelControl: Bool { parts.contains(.cancel) }
}

extension PillHint {
    /// ✕ while an action is heard or worked on: esc, and the action key too when one tap of it cancels.
    static func cancelAction(alsoKey: String? = nil) -> PillHint {
        PillHint(title: "Cancel", key: "esc", alternateKey: alsoKey)
    }
}

/// What VoiceOver says the keys are, on the buttons themselves now that no row spells them out.
enum ActionPillAccessibility {
    static let cancelLabel = "Cancel action"
    static let sendLabel = "Stop and run the action"
    static let sendHint = "Return sends."

    static func cancelHint(alsoKey: String?) -> String {
        alsoKey.map { "Escape or one tap of \($0) cancels." } ?? "Escape cancels."
    }
}

/// The bolt that marks every action capsule: lime while the microphone is open, purple while the
/// model works.
struct ActionBolt: View {
    var tint: Color = Theme.phosphorFill

    var body: some View {
        Image(systemName: "bolt.fill")
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(tint)
            .frame(width: ActionPillLayout.boltWidth)
            .accessibilityHidden(true)
    }
}

/// The pill while a voice action is heard. Held: bolt and bars in dictation's Listening capsule.
/// Latched: ✕ · bolt · bars · ✓, dictation's hands-free capsule with a bolt where its timer is.
struct ActionListeningRow: View {
    let mode: ActionListeningMode
    let levels: [Double]
    let peaks: [Double]
    var vertical = false
    let onCancel: () -> Void
    let onSend: () -> Void

    var body: some View {
        let stack = vertical
            ? AnyLayout(VStackLayout(spacing: ActionPillLayout.spacing))
            : AnyLayout(HStackLayout(spacing: ActionPillLayout.spacing))
        stack {
            ForEach(Array(ActionPillLayout.listening(mode).parts.enumerated()), id: \.offset) { _, part in
                view(for: part)
            }
        }
        .fixedSize(horizontal: !vertical, vertical: false)
    }

    private var cancelKey: String? {
        if case .latched(let key) = mode { return key }
        return nil
    }

    @ViewBuilder
    private func view(for part: ActionPillLayout.Part) -> some View {
        switch part {
        case .cancel:
            PillCircleButton(glyph: "xmark", tint: .muted, tooltip: .cancelAction(alsoKey: cancelKey), namesKey: true, action: onCancel)
                .accessibilityLabel(ActionPillAccessibility.cancelLabel)
                .accessibilityHint(ActionPillAccessibility.cancelHint(alsoKey: cancelKey))
        case .bolt:
            ActionBolt()
        case .meter:
            Waveform(levels: levels, peaks: peaks, metrics: vertical ? .standard : .dictation, vertical: vertical)
        case .send:
            PillCircleButton(glyph: "checkmark", tint: .phosphor, tooltip: .runAction, namesKey: true, action: onSend)
                .accessibilityLabel(ActionPillAccessibility.sendLabel)
                .accessibilityHint(ActionPillAccessibility.sendHint)
        case .dots:
            EmptyView()
        }
    }
}

/// When the working pill adds its words. The dots and the purple bolt say "working" for an ordinary
/// wait; the label arrives only when the wait is long, at the same 5 s mark as dictation's slow-wait sentence.
enum ActionWorkingPhase {
    static let labelDelay: TimeInterval = WritingPhase.stillDelay

    static func label(after elapsed: TimeInterval) -> String? {
        elapsed >= labelDelay ? PillModel.actionProcessingLabel : nil
    }
}

/// The pill while the command is worked on: ✕ where it was, a purple bolt, dictation's three dots.
struct ActionWorkingRow: View {
    let since: Date
    var vertical = false
    let onCancel: () -> Void

    var body: some View {
        let stack = vertical
            ? AnyLayout(VStackLayout(spacing: ActionPillLayout.spacing))
            : AnyLayout(HStackLayout(spacing: ActionPillLayout.spacing))
        stack {
            PillCircleButton(glyph: "xmark", tint: .muted, tooltip: .cancelAction(), namesKey: true, action: onCancel)
                .accessibilityLabel(ActionPillAccessibility.cancelLabel)
                .accessibilityHint(ActionPillAccessibility.cancelHint(alsoKey: nil))
            ActionBolt(tint: Theme.pillWorking)
            PillWritingView(since: since, vertical: vertical, label: ActionWorkingPhase.label(after:))
        }
        .fixedSize()
    }
}

/// An action that did not go through, as one pill row: ✕ · what went wrong · Retry (only when
/// trying again is safe). The action's own title waits behind a hover and in History; the person
/// said it two seconds ago. A row refused for a list or calendar that isn't there asks instead
/// (`ActionConfirmationRow.offer`): ✕ · the question · ✓, the tick adding it to the default.
struct ActionProblemRow: View {
    let row: ActionConfirmationRow
    /// ⏎ and esc still answer the pill (`PillModel.showsCardKeys`), so a button's hover may name
    /// its key. A question takes keys in its first key window only.
    var keysLive = true
    let onRetry: () -> Void
    var onAcceptOffer: () -> Void = {}
    let onDismiss: () -> Void

    /// The longest problem line the capsule shows in full; longer ones end in an ellipsis and are
    /// whole in the row's hover help.
    static let lineLimit: CGFloat = 280
    /// A question has to be read to its end, so it gets all the room the capsule has inside the
    /// confirm card's width (`ActionConfirmationCard.width`, with the two buttons and the padding).
    nonisolated static let offerLineLimit: CGFloat = 340
    /// The text is measured a little short of the limit, so rounding never costs the last word.
    nonisolated static let offerLineSlack: CGFloat = 4
    nonisolated static var lineFont: NSFont { .systemFont(ofSize: 11, weight: .medium) }

    /// What the row says: the offer's question when there is one, else what went wrong.
    nonisolated static func line(for row: ActionConfirmationRow) -> String {
        row.offer.map(question) ?? row.status.problemLine ?? ""
    }

    /// The question, whole. When the line is too long for the row it is the name that gives way,
    /// a character at a time, never "Add to your default list?". The full name is in the hover help.
    nonisolated static func question(_ offer: ActionRecovery) -> String {
        var limit = ActionWording.questionNameLimit
        var line = ActionWording.useDefaultQuestion(offer, nameLimit: limit)
        while limit > ActionWording.questionNameFloor, width(of: line) > offerLineLimit - offerLineSlack {
            limit -= 1
            line = ActionWording.useDefaultQuestion(offer, nameLimit: limit)
        }
        return line
    }

    /// The width a line takes in the row's font.
    nonisolated static func width(of line: String) -> CGFloat {
        let text = NSAttributedString(string: line, attributes: [.font: lineFont])
        return CGFloat(CTLineGetTypographicBounds(CTLineCreateWithAttributedString(text), nil, nil, nil))
    }

    /// What a pointer on the tick says, or nil when the row has no tick. Return is named only
    /// while it still answers the pill.
    nonisolated static func acceptHint(for row: ActionConfirmationRow, keysLive: Bool) -> PillHint? {
        row.offer.map { PillHint(title: ActionWording.useDefaultTitle($0), key: keysLive ? "return" : nil) }
    }

    /// What a pointer on the cross says. A question stops taking esc when its key window closes,
    /// so the key is named only until then; every other problem row takes esc for as long as it shows.
    nonisolated static func dismissHint(for row: ActionConfirmationRow, keysLive: Bool) -> PillHint {
        PillHint(title: "Dismiss", key: row.offer == nil || keysLive ? "esc" : nil)
    }

    /// Amber when Hushy cannot tell whether it ran; red when it did not.
    static func isUncertain(_ status: ActionConfirmationRow.RowStatus) -> Bool {
        if case .uncertain = status { return true }
        return false
    }

    var body: some View {
        let line = Self.line(for: row)
        HStack(spacing: ActionPillLayout.spacing) {
            PillCircleButton(
                glyph: "xmark", tint: .muted, tooltip: Self.dismissHint(for: row, keysLive: keysLive), namesKey: true, action: onDismiss)
                .accessibilityLabel("Dismiss")
            HStack(spacing: 6) {
                Circle().fill(Self.isUncertain(row.status) ? Theme.warning : Theme.error).frame(width: 6, height: 6)
                Text(line)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.white.opacity(0.85))
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(maxWidth: row.offer == nil ? Self.lineLimit : Self.offerLineLimit)
                    .help(row.offer.map { ActionWording.useDefaultQuestion($0, nameLimit: .max) } ?? line)
            }
            if let hint = Self.acceptHint(for: row, keysLive: keysLive) {
                // The one way forward: the same item, on the default list or calendar.
                PillCircleButton(glyph: "checkmark", tint: .phosphor, tooltip: hint, namesKey: true, action: onAcceptOffer)
                    .accessibilityLabel(hint.title)
                    .accessibilityHint(keysLive ? "Return does the same." : "")
            } else if row.status.canRunAgain {
                // Only after a plain failure (`RowStatus.canRunAgain`): never after a run that may have
                // happened, and never after a refusal that would fail the same way.
                Button("Retry", action: onRetry)
                    .buttonStyle(PillButtonStyle())
            }
        }
        .fixedSize()
        .accessibilityElement(children: .contain)
    }
}

extension ActionProblemRow {
    /// Above the capsule while the pointer rests on it: which action this is. Under a question the
    /// time is there too, so the person sees what the tick will add before they tap it.
    nonisolated static func hoverDetail(for row: ActionConfirmationRow) -> String {
        let title = ActionConfirmationRowView.title(for: row.action)
        guard row.offer != nil, let when = ActionDisplay.whenText(for: row.action) else { return title }
        return "\(title) \u{00B7} \(when)"
    }
}

extension ActionConfirmationCardState {
    /// The one row of a card that is only a report of what went wrong: drawn as `ActionProblemRow`.
    var soleProblemRow: ActionConfirmationRow? {
        guard rows.count == 1, let row = rows.first, row.status.problemLine != nil else { return nil }
        return row
    }
}

extension DoneChipState {
    /// The time and place, shown above the chip while the pointer is on it. Nothing while the chip
    /// is saying something else (undoing, undone, an undo that failed).
    var hoverDetail: String? {
        guard !undone, !isUndoing, undoFailure == nil, let detail, !detail.isEmpty else { return nil }
        return detail
    }
}

extension PillState {
    /// What a compact action row leaves out, shown above the capsule while the pointer rests on it:
    /// a done chip's time and place, or the action that failed.
    var hoverDetail: String? {
        switch self {
        case .actionDone(let chip): chip.hoverDetail
        case .actionConfirm(let card): card.soleProblemRow.map(ActionProblemRow.hoverDetail)
        default: nil
        }
    }
}
