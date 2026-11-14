import MurmurCore
import SwiftUI

/// Settings → Privacy → "Erase…": one sheet in place of four separate Clear and Delete buttons.
/// Each kind of data is a checkbox, none ticked to begin with; nothing is removed until the person
/// ticks something and presses the button. Assistant chats and background tasks are listed only
/// when this Mac has some.
struct EraseDataSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @Environment(\.isSnapshot) private var isSnapshot
    @State private var erase = Set<Kind>()
    @State private var hasChats = false
    @State private var offersClearTasks = false

    enum Kind: Hashable { case history, learning, chats, tasks }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.l) {
            VStack(alignment: .leading, spacing: Theme.Space.xs) {
                Text("Erase data").font(Theme.Font.section)
                Text("Pick what to remove from this Mac. This can't be undone.")
                    .font(Theme.Font.caption).foregroundStyle(Theme.textSecondary)
            }
            SettingsGroup {
                row(.history, title: "Dictation history", detail: "Every dictation and its audio. Notes are kept.")
                row(.learning, title: "Learning data", detail: LearningCopy.deleteDetail(keepsChanges: FeatureFlags.personMemory))
                if hasChats || isSnapshot {
                    row(.chats, title: "Assistant chats", detail: "Every saved Assistant chat.")
                }
                if offersClearTasks {
                    row(.tasks, title: "Background tasks", detail: "Every Codex task that is not running, with its request and result.")
                }
            }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.buttonStyle(SecondaryButtonStyle()).keyboardShortcut(.cancelAction)
                Button("Erase", role: .destructive, action: eraseSelected)
                    .buttonStyle(PrimaryButtonStyle())
                    .disabled(erase.isEmpty)
            }
        }
        .padding(Theme.Space.xxl)
        .frame(width: 520)
        .background(Theme.bgBase)
        .task {
            guard !isSnapshot else { return }
            hasChats = ((try? model.store.assistantChats(limit: 1))?.isEmpty == false)
            offersClearTasks = model.handoff.offersClear()
        }
    }

    /// A drawn checkbox rather than AppKit's, which `ImageRenderer` cannot draw in a still.
    private func row(_ kind: Kind, title: String, detail: String) -> some View {
        let isOn = erase.contains(kind)
        return SettingsRow(title: title, detail: detail, showsDivider: kind != lastKind) {
            Button {
                if isOn { erase.remove(kind) } else { erase.insert(kind) }
            } label: {
                Image(systemName: isOn ? "checkmark.square.fill" : "square")
                    .font(.system(size: 18))
                    .foregroundStyle(isOn ? Theme.phosphor : Theme.textTertiary)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(title)
            .accessibilityValue(isOn ? "On" : "Off")
            .accessibilityAddTraits(.isToggle)
        }
    }

    private var lastKind: Kind {
        if offersClearTasks { return .tasks }
        return hasChats || isSnapshot ? .chats : .learning
    }

    private func eraseSelected() {
        if erase.contains(.history) { clearHistory() }
        if erase.contains(.learning) { model.learned.deleteAllLearningData() }
        if erase.contains(.chats) { model.assistant.clearAllChats() }
        if erase.contains(.tasks) { Task { await model.handoff.clearTasks() } }
        dismiss()
    }

    private func clearHistory() {
        model.library.eraseDictationHistory()
    }
}
