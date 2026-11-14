import MurmurCore
import SwiftUI

/// Voice signatures management: rename, forget one, forget all. Free for everyone (see
/// `ProFeature.isFree`). A self-contained view struct (reads/writes through `AppModel.library` only), so
/// it can be embedded as a Settings pane (see `SettingsView`) or presented from elsewhere (e.g. a
/// future "Manage voices…" link from the transcript's voice-suggestion banner) without any
/// additional wiring.
struct VoicesListView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.isSnapshot) private var isSnapshot
    /// Opens the Tune sheet, owned by `SettingsView` (shared across panes). Defaults to a no-op
    /// binding so existing call sites (and snapshot rendering) don't need to pass one.
    var showTune: Binding<Bool>
    @State private var voices: [Voice]
    @State private var renamingVoiceId: Int64?
    @State private var renameText = ""
    @State private var confirmDeleteAll = false
    @State private var confirmDeleteVoiceId: Int64?

    /// The empty state, short enough to show whole above its "Tune now" button (which is the
    /// first of the two ways it names).
    static let emptyMessage =
        "Tune Hushy to your own voice with the button below. To remember someone else, name them in a note's transcript and choose \"Remember …'s voice\" from their name's menu. Nothing is remembered until you choose it."

    /// `voices` is only what shows before the first load; snapshots, which never run `onAppear`, pass fixtures.
    init(showTune: Binding<Bool> = .constant(false), voices: [Voice] = []) {
        self.showTune = showTune
        _voices = State(initialValue: voices)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.l) {
            if voices.isEmpty {
                EmptyState(
                    symbol: "person.wave.2",
                    title: "No voices remembered yet",
                    message: Self.emptyMessage,
                    actionTitle: "Tune now",
                    action: { showTune.wrappedValue = true })
            } else {
                SettingsGroup(title: "Remembered voices") {
                    ForEach(voices) { voice in
                        voiceRow(voice)
                    }
                }
                HStack {
                    Spacer()
                    Button("Forget all voices…", role: .destructive) { confirmDeleteAll = true }
                        .buttonStyle(SecondaryButtonStyle())
                }
            }
        }
        .onAppear(perform: reload)
        .confirmationDialog(
            "Forget all remembered voices?", isPresented: $confirmDeleteAll, titleVisibility: .visible
        ) {
            Button("Forget All", role: .destructive) {
                model.library.deleteAllVoices()
                reload()
            }
        } message: {
            Text("This permanently deletes every voice signature, including \"You.\" Past notes keep their transcripts and the names already given to speakers, but future notes will no longer suggest names.")
        }
        .confirmationDialog(
            "Forget this voice?",
            isPresented: Binding(get: { confirmDeleteVoiceId != nil }, set: { if !$0 { confirmDeleteVoiceId = nil } }),
            titleVisibility: .visible
        ) {
            Button("Forget", role: .destructive) {
                if let id = confirmDeleteVoiceId {
                    model.library.deleteVoice(id: id)
                    reload()
                }
                confirmDeleteVoiceId = nil
            }
        } message: {
            Text("This permanently deletes the voice signature. Past notes keep their transcripts and the names already given to speakers.")
        }
    }

    private func voiceRow(_ voice: Voice) -> some View {
        SettingsRow(title: rowTitle(voice), detail: rowDetail(voice)) {
            HStack(spacing: Theme.Space.s) {
                if renamingVoiceId == voice.id {
                    TextField("Name", text: $renameText)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 140)
                        .onSubmit { commitRename(voice) }
                    Button("Save") { commitRename(voice) }.buttonStyle(SecondaryButtonStyle())
                } else {
                    Button("Rename") {
                        renamingVoiceId = voice.id
                        renameText = voice.name
                    }.buttonStyle(SecondaryButtonStyle())
                    Button("Forget", role: .destructive) { confirmDeleteVoiceId = voice.id }
                        .buttonStyle(SecondaryButtonStyle())
                }
            }
        }
    }

    private func rowTitle(_ voice: Voice) -> String {
        voice.isYou ? "\(voice.name) (You)" : voice.name
    }

    private func rowDetail(_ voice: Voice) -> String {
        let sampleWord = voice.sampleCount == 1 ? "sample" : "samples"
        return "\(voice.sampleCount) \(sampleWord) · updated \(voice.updatedAt.formatted(date: .abbreviated, time: .omitted))"
    }

    private func commitRename(_ voice: Voice) {
        guard let id = voice.id else { renamingVoiceId = nil; return }
        let trimmed = renameText.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { model.library.renameVoice(id: id, to: trimmed) }
        renamingVoiceId = nil
        reload()
    }

    private func reload() {
        if isSnapshot { return }  // snapshots show their fixture voices, not the (empty) temp store
        voices = model.library.voices()
    }
}
