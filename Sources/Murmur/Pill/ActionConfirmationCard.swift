import MurmurCore
import SwiftUI

/// The pill's Action-mode confirmation (ACTIONS-IA §4; UI round 2026-09-28 §1). One action is the
/// pill itself — a 44 pt capsule that *is* the row (`.inline`, drawn inside `PillView`'s capsule).
/// Two or three are rows stacked directly above the pill, sharing its left edge (`.stacked`); the
/// capsule underneath becomes `ActionCardFooter`. Purple proposes, lime confirms: the kind glyph
/// is the model's colour, the ✓ verb stays lime.
struct ActionConfirmationCard: View {
    enum Layout: Equatable {
        /// One row: capsule-shaped, no header, controls inline.
        case inline
        /// Two or three rows above a footer capsule.
        case stacked

        init(rowCount: Int) {
            self = rowCount > 1 ? .stacked : .inline
        }
    }

    /// The stacked card's width; the inline row fits inside the same panel width.
    static let width: CGFloat = 440

    static func title(count: Int) -> String {
        count == 1 ? "1 action" : "\(count) actions"
    }

    /// VoiceOver: "1 action to confirm" / "3 actions to confirm". A "Did you mean…" card offers
    /// alternatives, of which one opens: "3 close matches to choose from".
    static func accessibilityText(count: Int, isChoice: Bool = false) -> String {
        guard isChoice else { return "\(title(count: count)) to confirm" }
        return count == 1 ? "1 close match to confirm" : "\(count) close matches to choose from"
    }

    let card: ActionConfirmationCardState
    let onConfirm: (ActionConfirmationRow) -> Void
    let onCancel: (ActionConfirmationRow) -> Void
    let onEdit: (ActionConfirmationRow) -> Void
    /// "Use default" on a row refused for a list or calendar that isn't there.
    var onOffer: (ActionConfirmationRow) -> Void = { _ in }
    let onConfirmAll: () -> Void
    let onCancelAll: () -> Void
    @Environment(\.isSnapshot) private var isSnapshot
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    var body: some View {
        // ⏎ confirms all and esc dismisses all through the event tap while rows are pending
        // (`PillKeyScope`): the pill's panel never becomes key.
        switch Layout(rowCount: card.rows.count) {
        case .inline: inlineRow
        case .stacked: stackedRows
        }
    }

    @ViewBuilder
    private var inlineRow: some View {
        if let row = card.rows.first { rowView(row, isInline: true) }
    }

    private var stackedRows: some View {
        VStack(alignment: .leading, spacing: 8) {
            if card.isChoice {
                Text("Did you mean\u{2026}").font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
            }
            ForEach(card.rows) { rowView($0, isInline: false) }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .frame(width: Self.width)
        .background(
            // ImageRenderer can't draw NSVisualEffectView; snapshots and Reduce Transparency
            // take the solid instrument surface.
            ZStack {
                if !isSnapshot && !reduceTransparency { VisualEffectBlur() }
                Theme.pillSurface
            })
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(.white.opacity(0.08), lineWidth: 0.5))
        .shadow(color: .black.opacity(0.35), radius: 12, y: 4)
        .environment(\.colorScheme, .dark)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Self.accessibilityText(count: card.rows.count, isChoice: card.isChoice))
    }

    private func rowView(_ row: ActionConfirmationRow, isInline: Bool) -> some View {
        ActionConfirmationRowView(
            row: row,
            onConfirm: { onConfirm(row) },
            onEdit: { onEdit(row) },
            onOffer: { onOffer(row) },
            onCancel: { onCancel(row) },
            glyphTint: Theme.pillWorking,
            isInline: isInline)
    }
}

/// The capsule under a stacked confirm card, in the action pill's own grammar: ✕ (none) · bolt ·
/// "3 actions" · ✓ (all). It stays the pill (drag handle, context menu). ⏎ and esc do the same as
/// the two buttons while the card's key window is open. A pointer on either button swaps the title
/// for what the button does and its key ("Confirm all return"), in place: a hint above the capsule
/// would cover the card's last row. Once ⏎ stops working (`PillModel.cardKeyWindow`) the ✓'s words
/// no longer name it, so the pill never shows a key that won't work. Under a "Did you mean…" card
/// ✓ and ⏎ open the closest row only.
struct ActionCardFooter: View {
    let count: Int
    var isChoice = false
    var keysLive = true
    let onConfirmAll: () -> Void
    let onCancelAll: () -> Void
    @Environment(\.snapshotTooltipText) private var forcedText
    @PillReduceMotion private var reduceMotion
    @Environment(\.pillMotion) private var motion
    @State private var hovered: PillButtonRole?

    /// The footer's words: its title, and what the two buttons are called.
    struct Wording: Equatable {
        let title: String
        let confirmText: String
        let cancelText: String
    }

    static func wording(count: Int, isChoice: Bool) -> Wording {
        isChoice
            ? Wording(title: "Pick one", confirmText: "Open first", cancelText: "Dismiss all")
            : Wording(title: ActionConfirmationCard.title(count: count), confirmText: "Confirm all", cancelText: "Dismiss all")
    }

    /// What a pointer on ✕ or ✓ says: esc always dismisses; return is named only while it still confirms.
    static func hints(count: Int, isChoice: Bool, keysLive: Bool) -> (cancel: PillHint, confirm: PillHint) {
        let wording = wording(count: count, isChoice: isChoice)
        return (PillHint(title: wording.cancelText, key: "esc"),
                PillHint(title: wording.confirmText, key: keysLive ? "return" : nil))
    }

    var body: some View {
        let wording = Self.wording(count: count, isChoice: isChoice)
        let hints = Self.hints(count: count, isChoice: isChoice, keysLive: keysLive)
        let shown: PillButtonRole? = forcedText == hints.cancel.title ? .cancel
            : (forcedText == hints.confirm.title ? .confirm : hovered)
        HStack(spacing: ActionPillLayout.spacing) {
            PillCircleButton(glyph: "xmark", tint: .muted, tooltip: hints.cancel, action: onCancelAll)
                .onHover { hover(.cancel, $0) }
                .accessibilityLabel(wording.cancelText)
            ActionBolt(tint: Theme.pillWorking)
            // One slot as wide as its widest line, so the ✓ never moves under the pointer.
            ZStack(alignment: .leading) {
                Text(wording.title)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.white.opacity(0.75))
                    .opacity(shown == nil ? 1 : 0)
                PillHintWords(text: hints.cancel.compact).opacity(shown == .cancel ? 1 : 0)
                PillHintWords(text: hints.confirm.compact).opacity(shown == .confirm ? 1 : 0)
            }
            .accessibilityHidden(true)
            PillCircleButton(glyph: "checkmark", tint: .phosphor, tooltip: hints.confirm, action: onConfirmAll)
                .onHover { hover(.confirm, $0) }
                .accessibilityLabel(wording.confirmText)
        }
        .fixedSize()
    }

    private func hover(_ role: PillButtonRole, _ inside: Bool) {
        let next: PillButtonRole? = inside ? role : (hovered == role ? nil : hovered)
        if reduceMotion { hovered = next } else { withAnimation(motion.animation(.hover)) { hovered = next } }
    }
}

/// One proposed action with its ✓ / Edit / ✕ (or progress/result). Shared by the pill's card
/// (on its dark surface) and the Assistant chat's inline cards (on the column's own surface),
/// so colours are semantic: `.primary`/`.secondary` follow whichever scheme the host sets.
struct ActionConfirmationRowView: View {
    let row: ActionConfirmationRow
    let onConfirm: () -> Void
    /// nil hides Edit (the chat has no editor).
    var onEdit: (() -> Void)?
    /// nil hides "Use default" (only the pill's card can take a row's offer).
    var onOffer: (() -> Void)?
    let onCancel: () -> Void
    /// The kind glyph's colour. The pill passes the model's purple ("purple proposes, lime
    /// confirms"); the chat host keeps the default until the theme's `working` token lands.
    var glyphTint: Color = Theme.phosphorFill
    /// The pill's single-action row: title and detail on one truncating line, so the row fits a
    /// 44 pt capsule.
    var isInline = false
    @PillReduceMotion private var reduceMotion

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Image(systemName: icon)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(glyphTint)
                    .frame(width: 18)
                if isInline {
                    // Hugs its content (the capsule is only as wide as the row); the title and
                    // detail truncate once the panel runs out of width.
                    inlineText
                    Color.clear.frame(width: 6, height: 1)
                } else {
                    stackedText
                    Spacer(minLength: 4)
                }
                trailing
            }
        }
        .padding(.vertical, isInline ? 0 : 4)
        .opacity(row.status == .cancelled ? 0.5 : 1)
        .animation(reduceMotion ? Theme.Motion.fade : Theme.Motion.pop, value: isSucceeded)
        .animation(Theme.Motion.fade, value: row.status == .cancelled)
        .accessibilityElement(children: .contain)
    }

    private var stackedText: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.system(size: 13, weight: .medium)).foregroundStyle(.primary)
                .fixedSize(horizontal: false, vertical: true)
            if let detail {
                Text(detail).font(.system(size: 11)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// A Shortcut's warning sits on its own line under the title, so the capsule never truncates
    /// the one sentence that says Hushy can't undo it.
    private var warnsBelowTitle: Bool {
        guard row.action.kind == .runShortcut else { return false }
        switch row.status {
        case .pending, .confirming: return true
        default: return false
        }
    }

    @ViewBuilder
    private var inlineText: some View {
        if warnsBelowTitle, let detail {
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.system(size: 12, weight: .medium)).foregroundStyle(.primary)
                Text(detail).font(.system(size: 10.5)).foregroundStyle(.secondary)
            }
            .lineLimit(1)
            .truncationMode(.tail)
            .layoutPriority(1)
        } else {
            inlineLine
        }
    }

    private var inlineLine: some View {
        HStack(spacing: 4) {
            Text(title).font(.system(size: 12, weight: .medium)).foregroundStyle(.primary)
                .layoutPriority(1)
            if let detail {
                Text("· \(detail)").font(.system(size: 11)).foregroundStyle(.secondary)
            }
        }
        .lineLimit(1)
        .truncationMode(.tail)
    }

    private var icon: String {
        switch row.action.kind {
        case .createEvent: "calendar"
        case .createReminder: "checklist"
        case .runShortcut: "bolt.fill"
        case .openLink: "arrow.up.right.square"
        }
    }

    private var title: String { Self.title(for: row.action) }

    /// What the row proposes, in its own words: `Add "Oat milk"`, `Run "Send Standup"`, "Open Chrome".
    nonisolated static func title(for action: ProposedAction) -> String {
        switch action.kind {
        case .runShortcut: "Run \"\(action.shortcutName ?? action.title)\""
        case .openLink: action.title
        default: "Add \"\(action.title)\""
        }
    }

    private var detail: String? {
        Self.detail(for: row)
    }

    /// The line under the title. A problem (failed, may have run, refused) always wins. A Shortcut
    /// says before it runs that Hushy can't undo it. A time shows what Hushy filled in: an
    /// event's length, a day's 9 a.m., the calendar or list when one was named.
    static func detail(for row: ActionConfirmationRow) -> String? {
        if let problem = row.status.problemLine { return problem }
        if row.action.kind == .runShortcut { return ActionWording.shortcutWarning }
        if row.action.kind == .openLink { return row.hint ?? row.action.url.flatMap { URL(string: $0)?.host } }
        let when = ActionDisplay.whenText(for: row.action)
        // Where it landed, when Hushy chose the place: shown once it has happened.
        let placed = row.placedIn.flatMap { $0.isEmpty ? nil : $0 }
        if let phrase = row.action.dateSourcePhrase, let when {
            return ([ "\(phrase.capitalized) · \(when)" ] + [placed].compactMap { $0 }).joined(separator: " · ")
        }
        var parts: [String] = []
        if let when { parts.append(when) }
        if let calendarName = row.action.calendarName ?? row.action.listName ?? placed { parts.append(calendarName) }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    @ViewBuilder
    private var trailing: some View {
        switch row.status {
        case .pending:
            HStack(spacing: 6) {
                ConfirmGlyphButton(symbol: "xmark", accessibilityText: "Cancel", help: "Dismiss (Esc)", action: onCancel)
                if let onEdit {
                    ConfirmGlyphButton(symbol: "pencil", accessibilityText: "Edit", action: onEdit)
                }
                // The ✓ carries the consequence verb (ACTIONS-IA §4) and, while it waits for
                // the user, a slow breathing glow — the only thing on the card that is live
                // (DESIGN-LANGUAGE.md §5.8). Shared with the learned-term suggestion.
                ConfirmVerbButton(verb: verb, help: "\(verb) (Return)", action: onConfirm)
            }
        case .confirming:
            ProgressView().controlSize(.small)
        case .succeeded:
            // Flash, then cool: the result lands with the success overshoot and reads as a
            // finished record ("✓ Added"), not a lingering control.
            HStack(spacing: 4) {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(Theme.success)
                Text(doneVerb).font(.system(size: 11, weight: .semibold)).foregroundStyle(Theme.success)
            }
            .transition(reduceMotion ? .opacity : .scale(scale: 0.8).combined(with: .opacity))
        case .failed:
            // A failure is always closable: ✕ here, esc through the event tap (`PillKeyScope`),
            // and the toast clears itself after `PillState.failureToastDelay`.
            HStack(spacing: 6) {
                Button(action: onConfirm) {
                    Text("Retry").font(.system(size: 11, weight: .semibold)).foregroundStyle(Theme.phosphorFill)
                }
                .buttonStyle(.plain)
                ConfirmGlyphButton(symbol: "xmark", accessibilityText: "Dismiss", help: "Dismiss (Esc)", action: onCancel)
            }
        case .uncertain, .blocked:
            // No Retry: after a run that may have happened a second one could do it twice, and a
            // refusal for a missing detail fails the same way again. Closable like any failure.
            // A list or calendar that isn't there has one way forward: the default, on a tap.
            HStack(spacing: 6) {
                if let onOffer, let offer = row.offer {
                    Button(action: onOffer) {
                        Text(ActionWording.useDefaultButton).font(.system(size: 11, weight: .semibold)).foregroundStyle(Theme.phosphorFill)
                    }
                    .buttonStyle(.plain)
                    .help(ActionWording.useDefaultTitle(offer))
                    .accessibilityLabel(ActionWording.useDefaultTitle(offer))
                }
                ConfirmGlyphButton(symbol: "xmark", accessibilityText: "Dismiss", help: "Dismiss (Esc)", action: onCancel)
            }
        case .cancelled:
            Image(systemName: "xmark.circle").foregroundStyle(.tertiary)
        }
    }

    private var isSucceeded: Bool {
        if case .succeeded = row.status { return true }
        return false
    }

    /// The consequence verb on ✓: what will actually happen.
    private var verb: String {
        switch row.action.kind {
        case .runShortcut: "Run"
        case .openLink: "Open"
        default: "Add"
        }
    }

    private var doneVerb: String {
        switch row.action.kind {
        case .runShortcut: "Ran"
        case .openLink: "Opened"
        default: "Added"
        }
    }
}
