import MurmurCore
import SwiftUI

/// The pill after a voice edit (`PillState.voiceEdit`): the dictation pill's footprint, one line,
/// ✕ and ✓ only. ✕ (or esc) puts the selection back; ✓ keeps the edit and closes the row.
enum VoiceEditChip: Equatable {
    /// The selection was replaced. `canUndo` while Undo is offered (`VoiceEditUndo.window`).
    case edited(canUndo: Bool)
    case undoing
    case undone
    /// Undo did not run: the line says why and what still works.
    case undoFailed(String)
    /// No edit was made and the selection is as it was.
    case declined(VoiceEditDecline)
    /// The selection changed while the edit was written, so nothing was pasted: the edit is on the clipboard.
    case copiedInstead
    /// A restyle (`RestyleController`) was asked to copy, or the text could not be replaced: the result is on the clipboard.
    case restyleCopied
    /// A restyle that could not start, in one line (nothing selected, too much, not in this app). Nothing was changed.
    case restyleNote(String)

    var canUndo: Bool {
        if case .edited(let canUndo) = self { return canUndo }
        return false
    }

    var line: String {
        switch self {
        case .edited: "Edited"
        case .undoing: "Putting it back…"
        case .undone: "Put back"
        case .undoFailed(let line): line
        case .declined(let why): why.line
        case .copiedInstead: "Selection changed · edit copied"
        case .restyleCopied: RestyleCopy.copied
        case .restyleNote(let line): line
        }
    }

    var accessibilityText: String {
        switch self {
        case .edited(let canUndo): canUndo ? "Edited. Press Escape to put the original text back." : "Edited."
        case .undoing: "Putting the original text back."
        case .undone: "The original text is back."
        case .undoFailed(let line): line
        case .declined(let why): why.line
        case .copiedInstead: "The selection changed, so nothing was replaced. The edit is on the clipboard."
        case .restyleCopied: "The rewritten text is on the clipboard."
        case .restyleNote(let line): line
        }
    }

    /// How long the row stays without a hand on it.
    var dismissDelay: Duration {
        switch self {
        case .edited(let canUndo): canUndo ? VoiceEditUndo.window : .seconds(2)
        case .undoing: .seconds(10)
        case .undone: .milliseconds(1_400)
        case .undoFailed, .declined, .copiedInstead, .restyleNote: .seconds(5)
        case .restyleCopied: .seconds(2)
        }
    }

    /// The pill-sized row is enough for every line here.
    static let lineLimit: CGFloat = 230
}

struct VoiceEditRow: View {
    let chip: VoiceEditChip
    let onUndo: () -> Void
    let onKeep: () -> Void

    var body: some View {
        HStack(spacing: ActionPillLayout.spacing) {
            if chip.canUndo {
                PillCircleButton(glyph: "xmark", tint: .muted, tooltip: PillHint(title: "Put it back", key: "esc"),
                                 namesKey: true, action: onUndo)
                    .accessibilityLabel("Put the original text back")
            }
            HStack(spacing: 6) {
                mark
                Text(chip.line)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.white.opacity(0.85))
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(maxWidth: VoiceEditChip.lineLimit)
            }
            if chip.canUndo {
                PillCircleButton(glyph: "checkmark", tint: .phosphor, tooltip: PillHint(title: "Keep"), namesKey: true, action: onKeep)
                    .accessibilityLabel("Keep the edit")
            }
        }
        .fixedSize()
        .accessibilityElement(children: .contain)
        .accessibilityLabel(chip.accessibilityText)
    }

    @ViewBuilder private var mark: some View {
        switch chip {
        // With ✓ on the row a second tick would repeat it; it shows once the buttons are gone.
        case .edited(let canUndo):
            if !canUndo { CheckmarkDraw() }
        case .restyleCopied:
            CheckmarkDraw()
        case .undoing:
            ProgressView().controlSize(.mini)
        case .undone:
            Image(systemName: "arrow.uturn.backward")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.white.opacity(0.75))
        case .undoFailed, .declined, .copiedInstead, .restyleNote:
            Circle().fill(Theme.warning).frame(width: 6, height: 6)
        }
    }
}
