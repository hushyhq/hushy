import AppKit
import MurmurCore
import SwiftUI

/// Settings → Privacy & data → "Open Memory…" (behind `FeatureFlags.personMemory`). The live
/// store in a sheet; what it draws is `MemoryPaneContent`. The store is the folder's one shared
/// store, the same one a dictation reads.
struct MemoryPane: View {
    let store: Store
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var entries: [MemoryEntry] = []
    @State private var paused = false
    @State private var editing: MemoryEntry?
    @State private var eraseConfirmation = false
    @State private var message: String?
    private let memory = MemoryStore.shared()

    var body: some View {
        MemoryPaneContent(
            entries: entries, isPaused: paused, message: message,
            appName: { LearnedAppName.name(for: $0, dictations: model.library.dictations) },
            actions: MemoryPaneActions(
                setPaused: { value in
                    paused = value
                    change { try await memory.setPaused(value); return nil }
                },
                edit: { editing = $0 },
                remove: { entry in change { try await memory.forget(id: entry.id); return nil } },
                restore: { entry in change { try await MemoryPaneCopy.message(for: memory.restore(id: entry.id), value: entry.value) } },
                showFolder: { NSWorkspace.shared.open(AppPaths.memoryDirectory) },
                eraseAll: { eraseConfirmation = true },
                done: { dismiss() }))
        .task {
            // Opening Memory is the person's own act, so what Hushy already learned is copied in
            // here whatever "Learn from my edits" says.
            do { try await memory.importLegacy(from: store) } catch { message = "Memory could not be set up." }
            await refresh(keeping: message)
        }
        .sheet(item: $editing) { entry in
            LockGate {
                MemoryEntryEditor(entry: entry) { updated in
                    change { try await MemoryPaneCopy.message(for: memory.update(updated), value: updated.value) }
                }
            }
        }
        .confirmationDialog("Erase all memory?", isPresented: $eraseConfirmation) {
            Button("Erase all", role: .destructive) { change { try await memory.eraseAll(); return nil } }
        } message: { Text("This deletes everything in the memory folder and cannot be undone.") }
    }

    /// Runs one change, then shows the files as they now are. What the change has to say (a word
    /// under Forgotten, a full profile) or a failure is shown, not dropped.
    private func change(_ work: @escaping () async throws -> String?) {
        Task {
            do {
                await refresh(keeping: try await work())
            } catch {
                await refresh(keeping: "Memory could not be changed.")
            }
        }
    }

    private func refresh(keeping note: String?) async {
        do {
            entries = try await memory.index().entries
            paused = try await memory.isPaused()
            message = note
        } catch {
            message = "Memory could not be read."
        }
    }
}
