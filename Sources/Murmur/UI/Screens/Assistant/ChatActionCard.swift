import MurmurCore
import SwiftUI

/// The confirmation card for actions an agent proposed in a reply: the pill's row view, on the
/// column's own surface. Nothing runs until Add.
struct ChatActionCard: View {
    let message: AssistantModel.Message
    @Environment(AppModel.self) private var model

    var body: some View {
        let assistant = model.assistant
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            HStack(spacing: 6) {
                Image(systemName: "bolt.fill")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(Theme.phosphor)
                Text(message.actions.count > 1 ? "\(message.actions.count) proposed actions" : "Proposed action")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Theme.textSecondary)
                Spacer(minLength: 0)
                Text("Needs your OK")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(Theme.textTertiary)
                    .opacity(message.actions.contains { $0.status == .pending } ? 1 : 0)
            }
            ForEach(message.actions) { entry in
                VStack(alignment: .leading, spacing: 2) {
                    ActionConfirmationRowView(
                        row: assistant.confirmationRow(for: entry),
                        onConfirm: { assistant.confirmAction(entry.id, in: message.id) },
                        onCancel: { assistant.cancelAction(entry.id, in: message.id) })
                    if assistant.canUndo(entry) {
                        Button { assistant.undoAction(entry.id, in: message.id) } label: {
                            Text("Undo").font(.system(size: 11, weight: .semibold)).foregroundStyle(Theme.phosphor)
                        }
                        .buttonStyle(.plain)
                        .padding(.leading, 26)
                        .accessibilityLabel("Undo \(entry.action.title)")
                    }
                    // This session's line under a finished card: an Undo that didn't work, a run
                    // History couldn't record, a removal History couldn't note. Never saved.
                    if entry.status == .added, let note = assistant.actionNotes[entry.id] {
                        Text(note).font(.system(size: 11)).foregroundStyle(Theme.warning).padding(.leading, 26)
                    } else if entry.status == .undone {
                        Text(assistant.actionNotes[entry.id] ?? ActionWording.undone)
                            .font(.system(size: 11)).foregroundStyle(Theme.textTertiary).padding(.leading, 26)
                    }
                }
            }
        }
        .padding(Theme.Space.m)
        .background(RoundedRectangle(cornerRadius: Theme.Radius.control + 2).fill(Theme.bgSunken))
        .overlay(
            RoundedRectangle(cornerRadius: Theme.Radius.control + 2)
                .strokeBorder(Theme.phosphor.opacity(0.35), lineWidth: 0.75))
        .foregroundStyle(Theme.textPrimary)
    }
}
