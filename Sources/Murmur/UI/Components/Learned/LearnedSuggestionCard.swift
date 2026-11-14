import MurmurCore
import SwiftUI

/// History's "add it to your dictionary?" card for one dictation, in the shared confirm-card
/// style (`ChatActionCard`'s surface, `ConfirmVerbButton`'s ✓ Add). Renders nothing when the
/// dictation has no ready suggestion. A decided row stays and reads "Added … · Undo".
struct LearnedSuggestionCard: View {
    @Environment(AppModel.self) private var model
    let dictationID: Int64

    var body: some View {
        let rows = model.learned.historyRows(forDictation: dictationID, items: model.library.learnedItems)
        if !rows.isEmpty {
            LearnedSuggestionCardContent(
                rows: rows,
                onAdd: { model.learned.add($0, from: .history) },
                onDismiss: { model.learned.dismiss($0, from: .history) },
                onUndo: { model.learned.undo($0) })
        }
    }
}

/// The card itself, driven by rows so it can be previewed and snapshotted in every state.
struct LearnedSuggestionCardContent: View {
    let rows: [LearnedReview.Row]
    let onAdd: (LearnedItem) -> Void
    let onDismiss: (LearnedItem) -> Void
    let onUndo: (Int64) -> Void

    /// Lime only while something waits for the user's ✓; the border cools once all is decided.
    private var isWaiting: Bool { rows.contains(where: \.isPending) }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.s + 2) {
            HStack(spacing: 6) {
                Image(systemName: "character.book.closed")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(isWaiting ? Theme.phosphor : Theme.textTertiary)
                Text("From your edits")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Theme.textSecondary)
            }
            .accessibilityHidden(true)
            ForEach(rows) { row in
                LearnedSuggestionRow(
                    row: row,
                    onAdd: { onAdd(row.item) },
                    onDismiss: { onDismiss(row.item) },
                    onUndo: { onUndo(row.id) })
            }
        }
        .padding(.horizontal, Theme.Space.m + 2)
        .padding(.top, Theme.Space.m)
        .padding(.bottom, Theme.Space.m + 2)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: Theme.Radius.control + 2).fill(Theme.bgSunken))
        .overlay(
            RoundedRectangle(cornerRadius: Theme.Radius.control + 2)
                .strokeBorder(isWaiting ? Theme.phosphor.opacity(0.35) : Theme.hairline, lineWidth: 0.75))
        .animation(Theme.Motion.cool, value: isWaiting)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Suggestion from your edits")
    }
}

/// One suggestion: the correction in two inks (what was heard, struck, in wet ink; the fix in
/// dry ink), the question, then ✕ and ✓ Add. After a decision the row cools to one line with
/// Undo, in place, so nothing below it moves.
struct LearnedSuggestionRow: View {
    let row: LearnedReview.Row
    let onAdd: () -> Void
    let onDismiss: () -> Void
    let onUndo: () -> Void

    var body: some View {
        ZStack(alignment: .leading) {
            switch row.outcome {
            case nil: pending.transition(.opacity)
            case .added?: resolved(LearnedPresentation.addedLine(row.item), checked: true)
            case .dismissed?, .forgotten?: resolved(LearnedPresentation.dismissedLine(row.item), checked: false)
            }
        }
        .animation(Theme.Motion.pop, value: row.outcome)
    }

    private var pending: some View {
        HStack(alignment: .center, spacing: Theme.Space.m) {
            VStack(alignment: .leading, spacing: 3) {
                correctionText
                    .font(.system(size: 13.5))
                    .foregroundStyle(Theme.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
                Text(LearnedPresentation.suggestionQuestion(row.item))
                    .font(.system(size: 12.5))
                    .foregroundStyle(Theme.textSecondary)
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(LearnedPresentation.suggestionSentence(row.item))
            Spacer(minLength: Theme.Space.s)
            HStack(spacing: 6) {
                ConfirmGlyphButton(
                    symbol: "xmark", accessibilityText: "Don't suggest \(row.item.value) again",
                    help: "Don't suggest this again", action: onDismiss)
                ConfirmVerbButton(
                    verb: "Add", accessibilityText: "Add \(row.item.value) to your dictionary",
                    help: "Add \(row.item.value) to your dictionary", action: onAdd)
            }
            .fixedSize()
        }
    }

    /// "You corrected ~~Pria~~ → **Priya** twice."
    private var correctionText: Text {
        let count = LearnedPresentation.times(max(row.item.observations, 1))
        let fixed = Text(row.item.value).fontWeight(.semibold)
        guard let heard = LearnedPresentation.heardAs(row.item) else {
            return Text("You corrected \(fixed) \(count).")
        }
        let wet = Text(heard).foregroundStyle(Theme.textTertiary).strikethrough(color: Theme.textTertiary)
        return Text("You corrected \(wet) → \(fixed) \(count).")
    }

    private func resolved(_ line: String, checked: Bool) -> some View {
        HStack(spacing: 6) {
            if checked { CoolingCheckmark() }
            Text(line)
                .font(.system(size: 13.5))
                .foregroundStyle(checked ? Theme.textPrimary : Theme.textSecondary)
            Text("·").foregroundStyle(Theme.textTertiary).accessibilityHidden(true)
            UndoLink(accessibilityText: checked ? "Undo adding \(row.item.value)" : "Undo, keep suggesting \(row.item.value)", action: onUndo)
            Spacer(minLength: 0)
        }
        // Same height as the pending row, so the card never jumps when it cools.
        .frame(minHeight: 36, alignment: .leading)
        .transition(.asymmetric(insertion: .scale(scale: 0.98, anchor: .leading).combined(with: .opacity), removal: .opacity))
    }
}

/// The quiet marker on a History list row: "Priya?" while the suggestion waits for ✓ (lime,
/// because it is waiting for the user), "Priya added" in plain ink once decided.
struct LearnedRowMarker: View {
    let marker: LearnedReview.RowMarker

    var body: some View {
        switch marker {
        case .suggestion(let term):
            HStack(spacing: 3) {
                Image(systemName: "character.book.closed").font(.system(size: 8.5, weight: .semibold))
                Text("Add \(term)?")
            }
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(Theme.phosphor)
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(Capsule().fill(Theme.phosphorTint))
            // The ring keeps it legible on the selected row, whose plate is the same tint.
            .overlay(Capsule().strokeBorder(Theme.phosphor.opacity(0.3), lineWidth: 0.5))
            .accessibilityLabel("Suggestion: add \(term) to your dictionary")
        case .added(let term):
            HStack(spacing: 3) {
                Image(systemName: "checkmark").font(.system(size: 8, weight: .bold))
                Text("\(term) added")
            }
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(Theme.textSecondary)
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(Capsule().fill(Theme.bgSunken))
            .accessibilityLabel("\(term) added to your dictionary")
        }
    }
}
