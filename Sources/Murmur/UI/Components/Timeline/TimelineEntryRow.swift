import MurmurCore
import SwiftUI

/// One row of the shared timeline, laid out by `TimelineRowScaffold` (the same scaffold History's
/// rows use): a branch off the group's spine, the entry's text (up to 2 lines) with its time
/// right-aligned on the first line, honest chips underneath for a dictation, and a fixed status
/// column for the needs-attention dot. Voice actions get a kind icon instead of chips and, while
/// still undoable, an "Undo" link — they aren't selectable, so they get no hover surface.
struct TimelineEntryRow: View {
    let entry: TimelineEntry
    /// The group's last row ends the spine with a "└" elbow instead of a "├" joint.
    var isLast = false
    var isSelected = false
    var needsAttentionOverride = false
    /// False while History is selecting many (see `TimelineRowScaffold.showsBranch`).
    var showsBranch = true
    var onUndo: (() -> Void)?
    var onTap: (() -> Void)?
    @State private var isHovered = false

    private var isSelectable: Bool {
        if case .action = entry { return false }
        return onTap != nil
    }

    var body: some View {
        let row = TimelineRowScaffold(isLast: isLast, highlight: highlight, showsBranch: showsBranch) {
            content
        } status: {
            if entry.needsAttention || needsAttentionOverride {
                TimelineStatusDot(color: Theme.warning)
            }
        }
        if isSelectable {
            Button(action: { onTap?() }) { row.contentShape(Rectangle()) }
                .buttonStyle(.plain)
                .onHover { isHovered = $0 }
                .accessibilityAddTraits(isSelected ? .isSelected : [])
        } else {
            row
        }
    }

    private var highlight: TimelineRowHighlight {
        if isSelected { return .selected }
        return isHovered ? .hover : .none
    }

    @ViewBuilder
    private var content: some View {
        switch entry {
        case .dictation(let dictation): dictationContent(dictation)
        case .note(let note): noteContent(note)
        case .action(let action): actionContent(action)
        }
    }

    private func dictationContent(_ dictation: Dictation) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            titleLine(text: dictationLine(dictation), color: dictationColor(dictation))
            let chips = TimelineChips.chips(rawText: dictation.rawText, cleanedText: dictation.text)
            if !chips.isEmpty {
                chipRow(chips)
            }
        }
    }

    private func noteContent(_ note: Note) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            titleLine(text: note.title, color: Theme.textPrimary)
            let chips = noteChips(note)
            if !chips.isEmpty { chipRow(chips) }
        }
    }

    private func noteChips(_ note: Note) -> [String] {
        var chips: [String] = []
        if !note.actionItems.isEmpty { chips.append("\(note.actionItems.count) action item\(note.actionItems.count == 1 ? "" : "s")") }
        if !note.summary.isEmpty { chips.append("Summary ready") }
        return chips
    }

    private func actionContent(_ action: ActionRecord) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .top, spacing: 6) {
                Image(systemName: actionSymbol(action))
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(actionTint(action))
                    .padding(.top, 2)
                titleLine(text: ActionRecordLine.text(for: action), color: actionColor(action))
            }
            if let note = ActionRecordLine.undoNote(for: action) {
                Text(note)
                    .font(Theme.Font.caption)
                    .foregroundStyle(Theme.warning)
                    .padding(.leading, 18)
            }
            if isUndoable(action), let onUndo {
                Button("Undo", action: onUndo)
                    .buttonStyle(.plain)
                    .font(Theme.Font.caption.weight(.semibold))
                    .foregroundStyle(Theme.phosphor)
                    .padding(.leading, 18)
            }
        }
    }

    private func titleLine(text: String, color: Color) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(text)
                .font(TimelineMetrics.titleFont)
                .foregroundStyle(color)
                .lineLimit(2)
                .frame(maxWidth: .infinity, alignment: .leading)
            Text(entry.createdAt.formatted(date: .omitted, time: .shortened))
                .font(Theme.Font.caption.monospacedDigit())
                .foregroundStyle(Theme.textTertiary)
                .fixedSize()
        }
    }

    private func chipRow(_ chips: [String]) -> some View {
        HStack(spacing: 4) {
            ForEach(chips, id: \.self) { chip in
                Text(chip)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(Theme.textSecondary)
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(Capsule().fill(Theme.bgSunken))
            }
        }
    }

    private func dictationLine(_ item: Dictation) -> String {
        if item.status == .cancelled { return item.rawText.isEmpty ? "Cancelled recording" : item.rawText }
        if item.status == .failed && item.text.isEmpty {
            return item.audioPath == nil ? "Transcription failed. No audio was retained." : "Transcription failed. The audio was saved."
        }
        if item.status == .inserted && item.text.isEmpty { return "Pressed Return (no text to type)" }
        return item.text
    }

    private func dictationColor(_ item: Dictation) -> Color {
        (item.status == .cancelled || (item.status == .failed && item.text.isEmpty)) ? Theme.textTertiary : Theme.textPrimary
    }

    /// A failed or uncertain action reads as a warning, an undone one as quiet; a done one as before.
    private func actionTint(_ action: ActionRecord) -> Color {
        switch action.status {
        case .failed, .uncertain: Theme.warning
        case .undone: Theme.textTertiary
        case .completed: Theme.phosphor
        }
    }

    private func actionColor(_ action: ActionRecord) -> Color {
        action.status == .undone ? Theme.textTertiary : Theme.textPrimary
    }

    private func actionSymbol(_ action: ActionRecord) -> String {
        switch action.status {
        case .failed: return "exclamationmark.triangle"
        case .uncertain: return "questionmark.circle"
        case .completed, .undone:
            switch action.kind {
            case .createEvent: return "calendar"
            case .createReminder: return "checklist"
            case .runShortcut: return "bolt.fill"
            case .openLink: return "arrow.up.right.square"
            }
        }
    }

    private func isUndoable(_ action: ActionRecord) -> Bool {
        action.status == .completed && action.undoBackendID != nil
    }
}
