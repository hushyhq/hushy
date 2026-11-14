import SwiftUI

/// The quiet row for a paste Hushy sent but could not read back (`PillState.pastedUnchecked`):
/// a muted tick, "Pasted", and one small control that opens the card with the words.
///
/// It follows every dictation in an app whose field Hushy cannot read, and in nearly all of them
/// the person has just watched their text appear. So it costs about what Done costs: one line,
/// no card, gone after `DeliveryPresentation.noticeHold`. It differs from the confirmed Done row
/// in two ways a glance can tell: the tick is grey, not lime, and there is a control to open it.
/// The dictation is still on the clipboard (an unconfirmed paste never restores the earlier
/// one), so if the text is not in the field, an ordinary ⌘V puts it there; the card says so.
struct PastedUncheckedRow: View {
    /// The whole visible line.
    static let line = "Pasted"
    /// What VoiceOver reads on the row: a listener cannot see that the tick is muted.
    static let accessibilityText = "Pasted. Hushy could not check the field, so the text is also on your clipboard."
    /// What VoiceOver says as the row appears: the same three facts, short, because it is said
    /// after every dictation in an app whose field Hushy cannot read.
    static let announcement = "Pasted, not checked. Also on your clipboard."
    /// Grey, so it is never mistaken for the lime tick of a confirmed paste.
    static let tickTint = Color.white.opacity(0.5)
    static let showHelp = "Show what you said. It is also on your clipboard."

    /// The card opens toward the screen centre; the control points the same way.
    let opensDownward: Bool
    let onShow: () -> Void

    var body: some View {
        HStack(spacing: 6) {
            CheckmarkDraw(tint: Self.tickTint)
            Text(Self.line)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.white.opacity(0.75))
            Button(action: onShow) {
                Image(systemName: opensDownward ? "chevron.down" : "chevron.up")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(.white.opacity(0.8))
                    .frame(width: 18, height: 18)
                    .background(Circle().fill(.white.opacity(0.14)))
            }
            .buttonStyle(.plain)
            .accessibilityLabel(RecoveryAction.showWords.title)
        }
        .fixedSize()
        // The whole row opens the card, not only the small control.
        .contentShape(Rectangle())
        .onTapGesture(perform: onShow)
        .help(Self.showHelp)
    }
}

extension PillState {
    /// States with the dictated text behind them, outside the state: the not-pasted card, and the
    /// quiet "Pasted" row whose click opens that card.
    var keepsUnpastedText: Bool {
        switch self {
        case .noField, .pastedUnchecked: true
        default: false
        }
    }
}

extension PillModel {
    /// The quiet row's one click: the unconfirmed card, with every word and Copy again. Nothing is
    /// written to the clipboard; the dictation staged for the paste is still there.
    func showUncheckedWords() {
        guard state == .pastedUnchecked, noFieldText != nil else { return }
        state = .noField(.copiedAutomaticallyUnconfirmed)
    }
}
