import MurmurCore
import SwiftUI
import UniformTypeIdentifiers

struct NotesView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.isSnapshot) private var isSnapshot
    @State private var query = ""
    /// `nil` = "All". Remembered only for this view's lifetime (not persisted), per the
    /// feature spec: "Remember the selected folder in @State only."
    @State private var selectedFolderID: Int64?
    @State private var isTargetedForDrop = false
    @State private var dropRejected = false
    @State private var compactShowsDetail = false

    var body: some View {
        @Bindable var model = model
        GeometryReader { geometry in
            let decision = DetailLayout.decide(
                available: geometry.size.width, preferredList: 300,
                minimumList: 300, minimumDetail: 420,
                hasSelection: selectedNote != nil, showSelectedDetail: compactShowsDetail,
                dividerWidth: 0.5)
            switch decision {
            case .split:
                HStack(spacing: 0) {
                    list.frame(width: 300)
                    Rectangle().fill(Theme.hairline).frame(width: 0.5)
                    detailPane
                }
            case .listOnly:
                if selectedNote != nil {
                    CompactList(onShowDetail: { compactShowsDetail = true }) { list }
                } else {
                    list.frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            case .detailOnly:
                CompactDetail(backTitle: "Back to notes", onBack: { compactShowsDetail = false }) {
                    detailPane
                }
            }
        }
        .background(Theme.bgBase)
        .onAppear {
            if model.selectedNoteID == nil { model.selectedNoteID = model.library.notes.first?.id }
            compactShowsDetail = selectedNote != nil
        }
        .onChange(of: model.selectedNoteID) { _, newValue in compactShowsDetail = newValue != nil }
        // Dropping audio/video files anywhere on the Notes page queues them for transcription
        // (see `ImportQueue`); dropping something unsupported (a PDF, a folder) is a no-op with
        // a brief inline message rather than a silent failure.
        .dropDestination(for: URL.self) { urls, _ in
            let accepted = model.importFiles(urls)
            dropRejected = accepted == 0
            return accepted > 0
        } isTargeted: { isTargetedForDrop = $0 }
        .overlay {
            if isTargetedForDrop {
                DropOverlay()
            }
        }
        .overlay(alignment: .bottom) {
            if dropRejected {
                DropRejectedToast(isPresented: $dropRejected)
            }
        }
    }

    private var detailPane: some View {
        Group {
            if let note = selectedNote {
                NoteDetail(note: note).id(note.id)
            } else {
                NotesEmpty()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// Only while searching: "3 of 12" tells the user whether to refine the query. A bare
    /// "12 notes" total asks nothing of them, so it's not shown (DECISIONS.md, "Sidebar badges:
    /// only actionable counts").
    private var searchCountLabel: String? {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }
        return "\(filtered.count) of \(folderScoped.count)"
    }

    /// Notes in the selected folder ("All" when `selectedFolderID` is `nil` and no folders
    /// exist yet — the strip itself only offers "Unfiled" once folders exist, but a stale
    /// `selectedFolderID` from a deleted folder should still fall back to "All" gracefully).
    private var folderScoped: [Note] {
        guard let selectedFolderID else { return model.library.notes }
        if selectedFolderID == Self.unfiledSentinel {
            return model.library.notes.filter { $0.folderId == nil }
        }
        return model.library.notes.filter { $0.folderId == selectedFolderID }
    }

    /// Search stays scoped to the selected folder: search first, then narrow to the folder,
    /// rather than searching the whole library and only visually filtering.
    private var filtered: [Note] {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return folderScoped }
        let results = (try? model.store.searchNotes(trimmed)) ?? []
        guard let selectedFolderID else { return results }
        if selectedFolderID == Self.unfiledSentinel {
            return results.filter { $0.folderId == nil }
        }
        return results.filter { $0.folderId == selectedFolderID }
    }

    /// Sentinel folder id for "Unfiled" in `selectedFolderID`, distinct from `nil` (which
    /// means "All"). No real folder can have this id since GRDB's autoincrement starts at 1.
    private static let unfiledSentinel: Int64 = -1

    private var selectedNote: Note? {
        guard let id = model.selectedNoteID else { return nil }
        if let active = model.recorder.activeNote, active.id == id { return active }
        return model.library.notes.first { $0.id == id }
    }

    private var list: some View {
        VStack(alignment: .leading, spacing: Theme.Space.m) {
            // Recording lives in the sidebar ("Record a note", ⇧⌘N); no second button here.
            HStack(alignment: .firstTextBaseline) {
                Text("Notes").font(Theme.Font.section)
                Spacer()
                if let searchCountLabel {
                    Text(searchCountLabel).font(Theme.Font.caption).foregroundStyle(Theme.textTertiary)
                        .accessibilityLabel("\(searchCountLabel) notes match")
                }
            }
            .padding(.top, 44)
            SearchField(text: $query, prompt: "Search notes")
            FolderStrip(selectedFolderID: $selectedFolderID)
            if !model.importQueue.items.isEmpty {
                ImportQueueList(queue: model.importQueue)
            }
            rows
            AppleNotesSyncRow()
        }
        .padding(.horizontal, Theme.Space.l)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(Theme.bgSunken.opacity(0.35))
    }

    /// `ImageRenderer` can't draw `ScrollView` contents, so in snapshot mode the rows are
    /// laid out flat instead (matching `ScreenLayout`'s approach elsewhere).
    @ViewBuilder
    private var rows: some View {
        let stack = LazyVStack(spacing: 4) {
            ForEach(filtered) { note in
                NoteRow(note: note, isSelected: note.id == model.selectedNoteID) {
                    model.selectedNoteID = note.id
                }
                .contextMenu { MoveToFolderMenu(note: note) }
            }
        }
        if isSnapshot {
            stack
        } else {
            ScrollView { stack }.scrollIndicators(.never)
        }
    }
}

private struct NoteRow: View {
    let note: Note
    let isSelected: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(note.title).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                        .foregroundStyle(Theme.textPrimary)
                    if note.status == .recording {
                        StatusBadge(text: "Recording", color: Theme.error, pulsing: true)
                    } else if note.status == .processing {
                        StatusBadge(text: "Transcribing", color: Theme.working)
                    } else if note.status == .failed {
                        StatusBadge(text: "Incomplete", color: Theme.error)
                    }
                }
                Text(preview).font(.system(size: 12)).foregroundStyle(Theme.textSecondary).lineLimit(2)
                HStack(spacing: 6) {
                    Text(note.createdAt.formatted(date: .abbreviated, time: .shortened))
                    Text("·")
                    Text(DurationLabelFormatter.label(seconds: note.durationSeconds))
                    if let language = note.language, let tag = LanguageTag.label(for: language) {
                        Text("·")
                        LanguageTag(text: tag)
                    }
                    if let meetingApp = note.meetingApp {
                        Text("·")
                        Text(meetingApp.displayName)
                    }
                }
                .font(Theme.Font.caption).foregroundStyle(Theme.textTertiary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(Theme.Space.m)
            .background(
                RoundedRectangle(cornerRadius: Theme.Radius.card)
                    .fill(isSelected ? Theme.bgRaised : (hovering ? Theme.selection.opacity(0.5) : .clear)))
            .overlay(
                RoundedRectangle(cornerRadius: Theme.Radius.card)
                    .strokeBorder(isSelected ? Theme.hairline : .clear, lineWidth: 0.5))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }

    private var preview: String {
        let source = note.summary.isEmpty ? note.transcript : note.summary
        let flattened = source.replacingOccurrences(of: "- ", with: "").replacingOccurrences(of: "\n", with: " ")
        guard flattened.isEmpty else { return flattened }
        return switch note.status {
        case .recording: "Recording…"
        case .processing: "Transcribing…"
        case .ready: "No transcript captured"
        case .failed: "Incomplete recording"
        }
    }
}

/// A small status pill next to a note's title, in the list and the detail header alike —
/// replaces repeating the status as if it were the note's title.
private struct StatusBadge: View {
    let text: String
    let color: Color
    var pulsing = false
    @State private var pulse = false

    var body: some View {
        HStack(spacing: 4) {
            Circle().fill(color).frame(width: 5, height: 5)
                .overlay(
                    Circle().stroke(color.opacity(0.5), lineWidth: 3)
                        .scaleEffect(pulse ? 2 : 1).opacity(pulse ? 0 : 0.8))
            Text(text)
        }
        .font(.system(size: 10, weight: .semibold))
        .foregroundStyle(color)
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .background(Capsule().fill(color.opacity(0.12)))
        .onAppear {
            guard pulsing else { return }
            withAnimation(.easeOut(duration: 1.4).repeatForever(autoreverses: false)) { pulse = true }
        }
    }
}

/// A compact row of folder chips below the search field: "All", each folder, "Unfiled" (only
/// once folders exist and at least one note is unfiled), and a "+" to create a folder. Selecting
/// a chip filters the notes list (and scopes search) to that folder.
private struct FolderStrip: View {
    @Environment(AppModel.self) private var model
    @Binding var selectedFolderID: Int64?
    @State private var creating = false
    @State private var newName = ""
    @State private var createError: String?
    @FocusState private var newNameFocused: Bool

    private static let unfiledSentinel: Int64 = -1

    private var folders: [NoteFolder] { model.library.folders }
    private var showUnfiled: Bool { !folders.isEmpty && model.library.unfiledNoteCount > 0 }
    @Environment(\.isSnapshot) private var isSnapshot

    private var chips: some View {
        HStack(spacing: 6) {
            FolderChip(title: "All", isSelected: selectedFolderID == nil) {
                selectedFolderID = nil
            }
            ForEach(folders) { folder in
                FolderChip(
                    title: folder.name,
                    isSelected: selectedFolderID == folder.id
                ) {
                    selectedFolderID = folder.id
                }
                .contextMenu { FolderContextMenu(folder: folder, selectedFolderID: $selectedFolderID) }
            }
            if showUnfiled {
                FolderChip(
                    title: "Unfiled",
                    isSelected: selectedFolderID == Self.unfiledSentinel
                ) {
                    selectedFolderID = Self.unfiledSentinel
                }
            }
            if creating {
                NewFolderField(text: $newName, isFocused: $newNameFocused, onSubmit: submit, onCancel: cancel)
            } else {
                IconButton(symbol: "plus", help: "New folder") {
                    creating = true
                    newName = ""
                    newNameFocused = true
                }
                .accessibilityLabel("New folder")
            }
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            // `ImageRenderer` can't draw `ScrollView` contents (see `NotesView.rows`), so
            // snapshot mode lays the chips out flat instead of in a horizontally scrolling strip.
            if isSnapshot {
                chips
            } else {
                ScrollView(.horizontal, showsIndicators: false) { chips }
                    .scrollIndicators(.never)
            }
            if let createError {
                Text(createError).font(Theme.Font.caption).foregroundStyle(Theme.error)
            }
        }
    }

    private func submit() {
        let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            cancel()
            return
        }
        switch model.library.createFolder(name: trimmed) {
        case .success(let folder):
            createError = nil
            creating = false
            newName = ""
            selectedFolderID = folder.id
        case .failure(let error):
            createError = error.localizedDescription
        }
    }

    private func cancel() {
        creating = false
        newName = ""
        createError = nil
    }
}

/// A single "New folder" inline text field, shown in place of the "+" button while creating.
/// Return confirms, Escape cancels — the field is small so no separate buttons are needed.
private struct NewFolderField: View {
    @Binding var text: String
    var isFocused: FocusState<Bool>.Binding
    let onSubmit: () -> Void
    let onCancel: () -> Void
    @Environment(\.isSnapshot) private var isSnapshot

    var body: some View {
        Group {
            if isSnapshot {
                SnapshotTextField(text, placeholder: "Folder name")
            } else {
                TextField("Folder name", text: $text)
                    .textFieldStyle(.plain)
                    .focused(isFocused)
                    .onSubmit(onSubmit)
                    .onExitCommand(perform: onCancel)
            }
        }
        .font(.system(size: 12, weight: .medium))
        .frame(width: 120)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(Capsule().fill(Theme.bgRaised))
        .overlay(Capsule().strokeBorder(Theme.phosphor.opacity(0.6), lineWidth: 1))
        .accessibilityLabel("New folder name")
        .help("Type a name, press Return to create or Escape to cancel")
    }
}

/// One chip in the folder strip: just the folder name.
private struct FolderChip: View {
    let title: String
    let isSelected: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            // No per-folder count: each folder is its own thing, and a total asks nothing of
            // the user (DECISIONS.md, "Sidebar badges: only actionable counts").
            Text(title).lineLimit(1)
            .font(.system(size: 12, weight: isSelected ? .semibold : .medium))
            .foregroundStyle(isSelected ? Theme.onPhosphor : (hovering ? Theme.textPrimary : Theme.textSecondary))
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(Capsule().fill(isSelected ? Theme.phosphorFill : (hovering ? Theme.selection : Theme.bgRaised)))
            .overlay(Capsule().strokeBorder(isSelected ? .clear : Theme.hairline, lineWidth: 0.5))
            // Full names; the strip scrolls sideways instead of truncating to "W…".
            .fixedSize()
        }
        .buttonStyle(.plain)
        .help(title)
        .accessibilityLabel(title)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .onHover { hovering = $0 }
        .animation(Theme.fade, value: hovering)
    }
}

/// Rename/Delete for a folder chip's context menu.
private struct FolderContextMenu: View {
    @Environment(AppModel.self) private var model
    let folder: NoteFolder
    @Binding var selectedFolderID: Int64?
    @State private var renaming = false
    @State private var confirmDelete = false

    var body: some View {
        Group {
            Button("Rename…") { renaming = true }
            Button("Delete folder…", role: .destructive) { confirmDelete = true }
        }
        // `.alert`/`.confirmationDialog` attach to a real view, not a `Menu`'s content, so they
        // ride along on an invisible sibling instead of failing to appear.
        .background(
            EmptyView()
                .alert("Rename folder", isPresented: $renaming) {
                    RenameFolderAlertFields(model: model, folder: folder)
                } message: {
                    Text("Choose a new name for “\(folder.name)”.")
                }
                .confirmationDialog("Delete “\(folder.name)”?", isPresented: $confirmDelete) {
                    Button("Delete folder", role: .destructive) {
                        if selectedFolderID == folder.id { selectedFolderID = nil }
                        model.library.deleteFolder(folder)
                    }
                } message: {
                    Text("Its notes are kept and moved to Unfiled — nothing is deleted.")
                })
    }
}

/// The `TextField` inside `Alert`'s field-based API (`.alert(_:isPresented:actions:)` on macOS
/// supports arbitrary controls, including a text field, in its `actions` closure).
private struct RenameFolderAlertFields: View {
    let model: AppModel
    let folder: NoteFolder
    @State private var name: String = ""
    @State private var didLoad = false

    var body: some View {
        TextField("Folder name", text: $name)
            .onAppear {
                guard !didLoad else { return }
                name = folder.name
                didLoad = true
            }
        Button("Cancel", role: .cancel) {}
        Button("Rename") { _ = model.library.renameFolder(folder, to: name) }
    }
}

/// "Move to folder" submenu for a note row's context menu: existing folders, "Unfiled", and
/// "New folder…" (which creates the folder and moves the note into it in one step).
private struct MoveToFolderMenu: View {
    @Environment(AppModel.self) private var model
    let note: Note
    @State private var creatingFolder = false
    @State private var newFolderName = ""

    var body: some View {
        Menu("Move to folder") {
            ForEach(model.library.folders) { folder in
                Button {
                    model.library.moveNote(note, toFolder: folder)
                } label: {
                    if note.folderId == folder.id {
                        Label(folder.name, systemImage: "checkmark")
                    } else {
                        Text(folder.name)
                    }
                }
            }
            if !model.library.folders.isEmpty { Divider() }
            Button {
                model.library.moveNote(note, toFolder: nil)
            } label: {
                if note.folderId == nil {
                    Label("Unfiled", systemImage: "checkmark")
                } else {
                    Text("Unfiled")
                }
            }
            Divider()
            Button("New folder…") { creatingFolder = true }
        }
        // Same rationale as `FolderContextMenu`: the alert rides on an invisible sibling.
        .background(
            EmptyView()
                .alert("New folder", isPresented: $creatingFolder) {
                    TextField("Folder name", text: $newFolderName)
                    Button("Cancel", role: .cancel) { newFolderName = "" }
                    Button("Create") {
                        if case .success(let folder) = model.library.createFolder(name: newFolderName) {
                            model.library.moveNote(note, toFolder: folder)
                        }
                        newFolderName = ""
                    }
                } message: {
                    Text("Notes stay put — you can move more into it later.")
                })
    }
}

/// A small "folder" menu button next to the note detail's meta line, so a note can be moved
/// without going back to the list. Shows the current folder's name, or "Unfiled".
private struct FolderMenuButton: View {
    @Environment(AppModel.self) private var model
    let note: Note
    @State private var creatingFolder = false
    @State private var newFolderName = ""

    private var currentFolderName: String {
        guard let folderId = note.folderId,
              let folder = model.library.folders.first(where: { $0.id == folderId })
        else { return "Unfiled" }
        return folder.name
    }

    var body: some View {
        Menu {
            ForEach(model.library.folders) { folder in
                Button {
                    model.library.moveNote(note, toFolder: folder)
                } label: {
                    if note.folderId == folder.id {
                        Label(folder.name, systemImage: "checkmark")
                    } else {
                        Text(folder.name)
                    }
                }
            }
            if !model.library.folders.isEmpty { Divider() }
            Button {
                model.library.moveNote(note, toFolder: nil)
            } label: {
                if note.folderId == nil {
                    Label("Unfiled", systemImage: "checkmark")
                } else {
                    Text("Unfiled")
                }
            }
            Divider()
            Button("New folder…") { creatingFolder = true }
        } label: {
            Label(currentFolderName, systemImage: "folder")
                .font(Theme.Font.caption)
                .foregroundStyle(Theme.textTertiary)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help("Move this note to a folder")
        .accessibilityLabel("Folder: \(currentFolderName)")
        .background(
            EmptyView()
                .alert("New folder", isPresented: $creatingFolder) {
                    TextField("Folder name", text: $newFolderName)
                    Button("Cancel", role: .cancel) { newFolderName = "" }
                    Button("Create") {
                        if case .success(let folder) = model.library.createFolder(name: newFolderName) {
                            model.library.moveNote(note, toFolder: folder)
                        }
                        newFolderName = ""
                    }
                } message: {
                    Text("Notes stay put — you can move more into it later.")
                })
    }
}

private struct NotesEmpty: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(spacing: Theme.Space.l) {
            EmptyState(
                symbol: "waveform.badge.mic",
                title: "Record a memo or a meeting",
                message: "Hushy transcribes while you talk, so the summary and action items are ready seconds after you stop. Everything stays on this Mac.")
            Button("Start recording") { model.toggleNoteRecording() }
                .buttonStyle(PrimaryButtonStyle())
                .keyboardShortcut("n", modifiers: [.command, .shift])
        }
    }
}

private struct NoteDetail: View {
    @Environment(AppModel.self) private var model
    @Environment(\.isSnapshot) private var isSnapshot
    let note: Note
    @State private var title: String = ""
    @State private var showTranscript = true
    @State private var confirmDelete = false
    /// Speaker-turn segments for this note, loaded once the note is `.ready` (diarization only
    /// ever runs after finalize) — nil while unloaded/loading, empty when the note has none
    /// (still processing, diarization disabled, or diarization found nothing). See
    /// docs/research/speaker-labeling.md — this is the "minimal visibility" phase: render
    /// speaker turns when both segments exist and `Entitlements.has(.speakerLabels)`; no
    /// rename/merge/paywall UI yet.
    @State private var speakerSegments: [NoteSegmentWithSpeaker]?

    private var stack: some View {
        VStack(alignment: .leading, spacing: Theme.Space.xl) {
            header
            if note.status == .recording {
                RecordingBanner(note: note)
            }
            if note.status == .processing {
                HStack(spacing: Theme.Space.s) {
                    ProgressView().controlSize(.small)
                    Text("Writing the summary on-device…").font(Theme.Font.body).foregroundStyle(Theme.textSecondary)
                }
            }
            if note.status == .failed {
                IncompleteNoteBanner(note: note)
            }
            if !note.summary.isEmpty { summary }
            if !note.actionItems.isEmpty { actions }
            transcript
        }
        .padding(.horizontal, Theme.Space.xxl + 8)
        .padding(.top, 44)
        .padding(.bottom, Theme.Space.section)
        .frame(maxWidth: 760, alignment: .leading)
        .frame(maxWidth: .infinity)
    }

    var body: some View {
        Group {
            if isSnapshot {
                stack.frame(maxHeight: .infinity, alignment: .top)
            } else {
                ScrollView { stack }
            }
        }
        .onAppear {
            title = note.title
            loadSpeakerSegments()
        }
        .onChange(of: note.title) { _, newTitle in title = newTitle }
        .onChange(of: note.id) { _, _ in loadSpeakerSegments() }
        .onChange(of: note.status) { _, _ in loadSpeakerSegments() }
        .confirmationDialog("Delete this note?", isPresented: $confirmDelete) {
            Button("Delete", role: .destructive) { model.deleteNote(note) }
        } message: {
            Text("The transcript, summary and audio will be removed from this Mac.")
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                if isSnapshot {
                    SnapshotTextField(title, placeholder: "Title")
                        .font(.system(size: 30, weight: .regular, design: .serif))
                } else {
                    TextField("Title", text: $title, axis: .vertical)
                        .lineLimit(1...3)
                        .textFieldStyle(.plain)
                        .fixedSize(horizontal: false, vertical: true)
                        .font(.system(size: 30, weight: .regular, design: .serif))
                        .onSubmit(saveTitle)
                        .disabled(note.id == model.recorder.activeNote?.id || model.recorder.isFinishing)
                }
                if note.status == .processing {
                    StatusBadge(text: "Transcribing", color: Theme.working)
                } else if note.status == .failed {
                    StatusBadge(text: "Incomplete", color: Theme.error)
                }
            }
            ViewThatFits(in: .horizontal) {
                HStack(spacing: Theme.Space.m) {
                    metadata
                    FolderMenuButton(note: note)
                    Spacer()
                    NoteActions(note: note, confirmDelete: $confirmDelete)
                }
                VStack(alignment: .leading, spacing: Theme.Space.s) {
                    HStack(spacing: Theme.Space.m) {
                        metadata
                        FolderMenuButton(note: note)
                        Spacer()
                    }
                    NoteActions(note: note, confirmDelete: $confirmDelete)
                }
            }
        }
    }

    private var metadata: some View {
        Text(metaLine)
            .font(Theme.Font.caption)
            .foregroundStyle(Theme.textTertiary)
            .help(note.createdAt.formatted(date: .complete, time: .shortened))
            .lineLimit(1)
    }

    /// "Today, 9:03 AM · 10 min · 5 words · Zoom" — the full date is on hover. The duration uses
    /// `DurationLabelFormatter` ("10 min" / "45 s"), never "10:12", so it can't be misread as a
    /// second timestamp next to the one before it. The meeting app (if any) is appended last.
    private var metaLine: String {
        let calendar = model.dayClock.calendar
        let now = model.dayClock.now
        let yesterday = calendar.date(byAdding: .day, value: -1, to: now) ?? now
        let day: String
        if calendar.isDate(note.createdAt, inSameDayAs: now) {
            day = "Today, " + note.createdAt.formatted(date: .omitted, time: .shortened)
        } else if calendar.isDate(note.createdAt, inSameDayAs: yesterday) {
            day = "Yesterday, " + note.createdAt.formatted(date: .omitted, time: .shortened)
        } else {
            day = note.createdAt.formatted(date: .abbreviated, time: .shortened)
        }
        let duration = DurationLabelFormatter.label(seconds: note.durationSeconds)
        var parts = [day, duration, "\(note.wordCount) words"]
        if let meetingApp = note.meetingApp { parts.append(meetingApp.displayName) }
        return parts.joined(separator: " · ")
    }

    private var summary: some View {
        VStack(alignment: .leading, spacing: Theme.Space.m) {
            Eyebrow("Summary")
            VStack(alignment: .leading, spacing: Theme.Space.s) {
                ForEach(note.summary.components(separatedBy: "\n").filter { !$0.isEmpty }, id: \.self) { line in
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        Circle().fill(Theme.phosphor).frame(width: 5, height: 5).offset(y: -2)
                        Text(line.hasPrefix("- ") ? String(line.dropFirst(2)) : line)
                            .font(.system(size: 15))
                            .foregroundStyle(Theme.textPrimary)
                            .textSelection(.enabled)
                            .lineSpacing(3)
                    }
                }
            }
        }
    }

    private var actions: some View {
        VStack(alignment: .leading, spacing: Theme.Space.m) {
            Eyebrow("Action items")
            Card {
                VStack(alignment: .leading, spacing: Theme.Space.s) {
                    ForEach(Array(note.actionItems.enumerated()), id: \.offset) { index, item in
                        let detail = note.actionItemDetails?[index]
                        ActionItemRow(
                            text: detail?.task ?? item, owner: detail?.owner ?? "", due: detail?.due ?? "",
                            isDone: model.library.isActionItemDone(note, itemIndex: index),
                            toggle: { model.library.toggleActionItemDone(note, itemIndex: index) })
                    }
                }
            }
        }
    }

    private var transcript: some View {
        VStack(alignment: .leading, spacing: Theme.Space.m) {
            Button {
                withAnimation(Theme.snappy) { showTranscript.toggle() }
            } label: {
                HStack(spacing: 6) {
                    Eyebrow("Transcript")
                    Image(systemName: "chevron.down")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(Theme.textTertiary)
                        .rotationEffect(.degrees(showTranscript ? 0 : -90))
                }
            }
            .buttonStyle(.plain)
            if showTranscript {
                if let segments = speakerSegments, !segments.isEmpty, Entitlements.has(.speakerLabels) {
                    SpeakerTurnsView(noteId: note.id ?? 0, segments: segments, youDisplayName: model.settings.userName)
                } else {
                    Text(transcriptPlaceholder ?? note.transcript)
                        .font(.system(size: 14))
                        .foregroundStyle(note.transcript.isEmpty ? Theme.textTertiary : Theme.textSecondary)
                        .lineSpacing(5)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .transition(.opacity)
                }
            }
        }
    }

    /// Loads this note's saved diarization segments (if any) from `Store`, off the main actor.
    /// Cheap: `Store.noteSegments` is a keyed, indexed read, and most notes have none yet (either
    /// diarization is disabled, still running in the background, or found nothing to align).
    ///
    /// Diarization runs detached, after the note is already `.ready` (see
    /// `NoteRecorder.scheduleDiarization`), so there's no single event that fires when its
    /// segments land while this view is already open. Rather than add a live-update channel for
    /// a phase that has no UI to react to yet beyond "did segments appear", this does one
    /// short-delayed re-check after the initial load — long enough to catch diarization
    /// finishing shortly after the note becomes ready (the common case for a short note),
    /// without polling indefinitely. Reopening the note later always reflects the true state.
    private func loadSpeakerSegments() {
        guard note.status == .ready, let id = note.id else {
            speakerSegments = []
            return
        }
        let store = model.store
        Task {
            let segments = (try? store.noteSegments(noteId: id)) ?? []
            await MainActor.run { speakerSegments = segments }
            guard segments.isEmpty else { return }
            try? await Task.sleep(for: .seconds(5))
            guard !Task.isCancelled, let refreshed = try? store.noteSegments(noteId: id), !refreshed.isEmpty else { return }
            await MainActor.run { speakerSegments = refreshed }
        }
    }

    private func saveTitle() {
        let trimmed = title.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, trimmed != note.title else { return }
        model.library.rename(note, to: trimmed)
    }

    private var transcriptPlaceholder: String? {
        guard note.transcript.isEmpty else { return nil }
        return switch note.status {
        case .recording: "Recording in progress…"
        case .processing: "Transcribing the captured audio…"
        case .ready: "No transcript was captured."
        case .failed: "No transcript was recovered."
        }
    }
}

private struct IncompleteNoteBanner: View {
    @Environment(AppModel.self) private var model
    let note: Note
    @State private var confirmDiscard = false

    private var savedAudioFolder: URL? {
        guard let path = note.audioPath else { return nil }
        let folder = URL(fileURLWithPath: path, isDirectory: true)
        guard let files = try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil),
              files.contains(where: { $0.pathExtension.lowercased() == "wav" }) else { return nil }
        return folder
    }

    private var isRetrying: Bool { model.recorder.retryingNoteID == note.id }
    private var hasTranscript: Bool { !note.transcript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    /// The heading and body describe only what actually happened and what's actually
    /// available, instead of a generic message that claims a transcript or audio exists
    /// when neither does.
    private var heading: String {
        switch (hasTranscript, savedAudioFolder != nil) {
        case (true, _): "Recording partially transcribed"
        case (false, true): "Transcription failed"
        case (false, false): "Recording lost"
        }
    }

    private var body_: String {
        switch (hasTranscript, savedAudioFolder != nil) {
        case (true, _): "Part of this recording was transcribed before it stopped. The rest wasn't captured."
        case (false, true): "The audio was saved, but transcription didn't finish. You can retry it or listen to the audio directly."
        case (false, false): "This recording didn't finish and no audio was saved, so there's nothing left to recover."
        }
    }

    var body: some View {
        HStack(alignment: .top, spacing: Theme.Space.m) {
            Image(systemName: "exclamationmark.circle.fill")
                .foregroundStyle(Theme.error)
            VStack(alignment: .leading, spacing: 3) {
                Text(heading)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Theme.textPrimary)
                Text(body_)
                    .font(Theme.Font.caption).foregroundStyle(Theme.textSecondary)
                HStack(spacing: Theme.Space.m) {
                    if let savedAudioFolder {
                        LinkLikeButton(title: "Show audio") {
                            NSWorkspace.shared.activateFileViewerSelecting([savedAudioFolder])
                        }
                    }
                    if savedAudioFolder != nil {
                        if isRetrying {
                            HStack(spacing: 4) {
                                ProgressView().controlSize(.mini)
                                Text("Retrying…")
                            }
                        } else {
                            LinkLikeButton(title: "Retry transcription") { model.retryNoteTranscription(note) }
                        }
                    }
                    LinkLikeButton(title: "Discard") { confirmDiscard = true }
                }
                .font(Theme.Font.caption)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(Theme.Space.l)
        .background(RoundedRectangle(cornerRadius: Theme.Radius.card).fill(Theme.error.opacity(0.1)))
        .confirmationDialog("Discard this note?", isPresented: $confirmDiscard) {
            Button("Discard", role: .destructive) { model.deleteNote(note) }
        } message: {
            Text("The transcript, summary and audio will be removed from this Mac.")
        }
    }
}

/// One action item. A note with fields shows the task alone with "Priya · by Friday" under it; an
/// older note shows its line, as before.
struct ActionItemRow: View {
    let text: String
    var owner: String = ""
    var due: String = ""
    let isDone: Bool
    let toggle: () -> Void

    /// "Priya · by Friday", or only what is there; empty when neither is.
    var secondaryText: String { ActionItemDetail.secondaryText(owner: owner, due: due) }

    var body: some View {
        Button { withAnimation(Theme.snappy) { toggle() } } label: {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Image(systemName: isDone ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(isDone ? Theme.success : Theme.textTertiary)
                VStack(alignment: .leading, spacing: 2) {
                    Text(text)
                        .font(.system(size: 14))
                        .strikethrough(isDone, color: Theme.textTertiary)
                        .foregroundStyle(isDone ? Theme.textTertiary : Theme.textPrimary)
                        .multilineTextAlignment(.leading)
                    if !secondaryText.isEmpty {
                        Text(secondaryText)
                            .font(.system(size: 12))
                            .foregroundStyle(isDone ? Theme.textTertiary : Theme.textSecondary)
                            .multilineTextAlignment(.leading)
                    }
                }
                Spacer()
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// Deliberately dark in both themes — recording is a "live" state, and a graphite panel signals
/// that distinctly from the surrounding page. Text is always white against this fixed dark
/// fill, which keeps contrast correct without doubling the color logic per theme.
private struct RecordingBanner: View {
    @Environment(AppModel.self) private var model
    let note: Note

    var body: some View {
        HStack(spacing: Theme.Space.l) {
            Waveform(levels: model.pill.levels)
            VStack(alignment: .leading, spacing: 2) {
                Text("Recording").font(.system(size: 13, weight: .semibold)).foregroundStyle(.white)
                Text("Transcribing every 30 seconds, on-device").font(Theme.Font.caption).foregroundStyle(.white.opacity(0.6))
            }
            Spacer()
            Button("Stop") { model.toggleNoteRecording() }
                .buttonStyle(PrimaryButtonStyle())
        }
        .padding(Theme.Space.l)
        .background(RoundedRectangle(cornerRadius: Theme.Radius.card).fill(Color(hex: 0x1B1F17)))
        .environment(\.colorScheme, .dark)
    }
}

/// Labelled note actions (like the mockup: "Markdown", "Apple Notes") plus a "…" menu. Every
/// action confirms what happened inline, and failures say why instead of only logging.
private struct NoteActions: View {
    @Environment(AppModel.self) private var model
    let note: Note
    @Binding var confirmDelete: Bool
    @State private var flash: String?
    @State private var failure: String?
    /// Set when saving this note to Apple Notes failed; the alert says why and what to do.
    @State private var notesProblem: AppleNotesAccessResult?

    private var isBusy: Bool { note.id == model.recorder.activeNote?.id || model.recorder.isFinishing }
    private var hasTranscript: Bool { !note.transcript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    private var canExport: Bool { note.status == .ready || (note.status == .failed && hasTranscript) }

    var body: some View {
        HStack(spacing: Theme.Space.xs) {
            if let flash {
                Label(flash, systemImage: "checkmark")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Theme.success)
                    .transition(.opacity)
            }
            if canExport {
                ShareRecapControl(note: note)
                ActionChip(symbol: "square.and.arrow.up", title: "Markdown",
                           help: "Save as a Markdown file and show it in Finder") { exportMarkdown() }
                if note.status == .ready {
                    ActionChip(symbol: "note.text", title: "Apple Notes",
                               help: "Add to the “\(AppleNotesExporter.folder)” folder in Apple Notes") { saveToAppleNotes() }
                }
            }
            Menu {
                if canExport {
                    Button("Copy as Markdown") {
                        TextInserter.copy(MarkdownExporter.markdown(
                            for: note, transcript: note.id.flatMap { try? model.store.transcript(noteId: $0) },
                            facts: note.id.flatMap { try? model.store.facts(noteId: $0) }))
                        show("Copied")
                    }
                    // Subtitles only make sense for a note with real word timings — an imported
                    // file (see `NoteSegment`). A live microphone recording has none, so SRT/VTT
                    // are hidden rather than offering an export that would come out empty.
                    if model.hasTimedTranscript(note) {
                        Divider()
                        Button("Export as SRT…") { exportTranscript(.srt) }
                        Button("Export as WebVTT…") { exportTranscript(.vtt) }
                    }
                    Button("Export as Text…") { exportTranscript(.plainText) }
                }
                if note.status == .ready {
                    Button("Summarize again") {
                        model.library.resummarize(note)
                        show("Summarizing…")
                    }
                }
                Divider()
                Button("Delete note…", role: .destructive) { confirmDelete = true }
                    .disabled(isBusy)
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Theme.textSecondary)
                    .frame(width: 26, height: 26)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("More actions")
        }
        .alert("Couldn’t finish that", isPresented: Binding(get: { failure != nil }, set: { if !$0 { failure = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(failure ?? "")
        }
        .alert("Couldn’t add to Apple Notes", isPresented: Binding(get: { notesProblem != nil }, set: { if !$0 { notesProblem = nil } })) {
            if notesProblem?.canOpenSettings == true {
                Button("Open System Settings") { NSWorkspace.shared.open(AppleNotesAccessResult.automationSettingsURL) }
            }
            Button("Try again") { saveToAppleNotes() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(notesProblem?.message ?? "")
        }
    }

    private func exportMarkdown() {
        guard let url = model.exportNote(note) else {
            failure = "The Markdown file couldn’t be written. Check the export folder in Settings → Notes."
            return
        }
        NSWorkspace.shared.activateFileViewerSelecting([url])
        show("Saved")
    }

    private func exportTranscript(_ format: NoteTranscriptExporter.Format) {
        guard let url = model.exportTranscript(note, format: format) else {
            failure = "The \(format.displayName) file couldn’t be written. Check the export folder in Settings → Notes."
            return
        }
        NSWorkspace.shared.activateFileViewerSelecting([url])
        show("Saved")
    }

    private func saveToAppleNotes() {
        do {
            try AppleNotesExporter.export(
                note, transcript: note.id.flatMap { try? model.store.transcript(noteId: $0) },
                facts: note.id.flatMap { try? model.store.facts(noteId: $0) })
            show("Added to Apple Notes")
        } catch let error as AppleNotesExporter.ExportError {
            notesProblem = error.result
        } catch {
            failure = error.localizedDescription
        }
    }

    private func show(_ message: String) {
        withAnimation(Theme.fade) { flash = message }
        Task {
            try? await Task.sleep(for: .seconds(2))
            withAnimation(Theme.fade) { if flash == message { flash = nil } }
        }
    }
}

/// A quiet text+icon button for the note header.
private struct ActionChip: View {
    let symbol: String
    let title: String
    let help: String
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Label(title, systemImage: symbol)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(hovering ? Theme.textPrimary : Theme.textSecondary)
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(Capsule().fill(hovering ? Theme.selection : .clear))
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .help(help)
        .onHover { hovering = $0 }
        .animation(Theme.fade, value: hovering)
    }
}

/// Pinned under the notes list: one switch for "also save every note to Apple Notes", the same
/// setting offered during setup and in Settings → Notes.
private struct AppleNotesSyncRow: View {
    @Environment(AppModel.self) private var model
    @Environment(\.isSnapshot) private var isSnapshot
    @Environment(\.snapshotAppleNotesResult) private var snapshotResult
    @State private var toggle = AppleNotesToggle()

    var body: some View {
        let shown = snapshotResult ?? toggle.problem
        VStack(alignment: .leading, spacing: 6) {
            Divider().overlay(Theme.hairline)
            HStack(spacing: Theme.Space.s) {
                Image(systemName: "note.text")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Theme.warning)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Save to Apple Notes")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(Theme.textPrimary)
                    if shown == nil || shown?.isGranted == true {
                        Text("New notes also go to the “\(AppleNotesExporter.folder)” folder")
                            .font(.system(size: 10.5))
                            .foregroundStyle(Theme.textSecondary)
                            .lineLimit(2)
                    }
                }
                Spacer(minLength: 4)
                SwitchToggle(isOn: Binding(
                    get: { model.settings.saveNotesToAppleNotes || snapshotResult == .granted },
                    set: { set($0) }))
                    .controlSize(.mini)
                    .accessibilityLabel("Save to Apple Notes")
                    .help("Also save every finished note to Apple Notes, so it’s on your iPhone too")
            }
            if let shown, !shown.isGranted {
                AppleNotesAccessNotice(result: shown, compact: true) { set(true) }
            }
        }
        .padding(.bottom, Theme.Space.m)
    }

    /// Never runs the script in snapshot mode, so a render can't trigger the Automation prompt.
    private func set(_ on: Bool) {
        guard !isSnapshot else { return }
        toggle.turn(on) { model.settings.saveNotesToAppleNotes = $0 }
    }
}

/// Full-page overlay shown while a supported file is dragged over the Notes page, matching the
/// existing dashed-border drop-target convention.
private struct DropOverlay: View {
    var body: some View {
        RoundedRectangle(cornerRadius: Theme.Radius.card)
            .strokeBorder(Theme.phosphor, style: StrokeStyle(lineWidth: 2, dash: [8, 6]))
            .background(RoundedRectangle(cornerRadius: Theme.Radius.card).fill(Theme.phosphor.opacity(0.06)))
            .overlay {
                VStack(spacing: Theme.Space.s) {
                    Image(systemName: "waveform.badge.plus")
                        .font(.system(size: 28, weight: .medium))
                        .foregroundStyle(Theme.phosphor)
                    Text("Drop to transcribe")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(Theme.textPrimary)
                }
            }
            .padding(Theme.Space.l)
            .allowsHitTesting(false)
    }
}

/// Brief inline message shown when a drop contained no supported audio/video files, instead of
/// silently doing nothing.
private struct DropRejectedToast: View {
    @Binding var isPresented: Bool

    var body: some View {
        Text("That file type isn't supported. Try m4a, mp3, wav, aiff, caf, mp4, mov or m4v.")
            .font(Theme.Font.caption)
            .foregroundStyle(.white)
            .padding(.horizontal, Theme.Space.m)
            .padding(.vertical, Theme.Space.s)
            .background(Capsule().fill(Theme.error))
            .padding(.bottom, Theme.Space.l)
            .transition(.move(edge: .bottom).combined(with: .opacity))
            .task {
                try? await Task.sleep(for: .seconds(3))
                isPresented = false
            }
    }
}

/// One row per file currently importing (decoding/transcribing) or that just finished, shown
/// above the notes list — see `ImportQueue`. Finished rows (`.done`/`.failed`/`.cancelled`) stay
/// visible with a dismiss button rather than disappearing on their own, so a batch's outcomes
/// don't flash past unseen.
private struct ImportQueueList: View {
    let queue: ImportQueue

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(queue.items, id: \.fileURL) { item in
                ImportQueueRow(item: item, queue: queue)
            }
        }
    }
}

private struct ImportQueueRow: View {
    @Environment(AppModel.self) private var model
    var item: FileTranscriber
    let queue: ImportQueue

    var body: some View {
        HStack(spacing: Theme.Space.s) {
            Image(systemName: "waveform")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Theme.phosphor)
            VStack(alignment: .leading, spacing: 2) {
                Text(item.displayName)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Theme.textPrimary)
                    .lineLimit(1)
                Text(statusLine)
                    .font(.system(size: 10.5))
                    .foregroundStyle(statusIsError ? Theme.error : Theme.textTertiary)
            }
            Spacer(minLength: 4)
            trailing
        }
        .padding(.horizontal, Theme.Space.m)
        .padding(.vertical, Theme.Space.s)
        .background(RoundedRectangle(cornerRadius: Theme.Radius.card).fill(Theme.bgRaised))
        .onChange(of: item.state) { _, newState in
            // Once a file finishes successfully, select its note so the user sees the result
            // immediately instead of having to find it in the list themselves.
            if case .done(let noteID) = newState { model.selectedNoteID = noteID }
        }
    }

    @ViewBuilder
    private var trailing: some View {
        switch item.state {
        case .idle:
            Text("Queued").font(Theme.Font.caption).foregroundStyle(Theme.textTertiary)
        case .decoding, .transcribing:
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                IconButton(symbol: "xmark", help: "Cancel") { queue.cancel(item) }
            }
        case .done, .failed, .cancelled:
            IconButton(symbol: "xmark", help: "Dismiss") { queue.dismiss(item) }
        }
    }

    private var statusIsError: Bool {
        if case .failed = item.state { return true }
        return false
    }

    private var statusLine: String {
        switch item.state {
        case .idle: "Waiting to transcribe…"
        case .decoding(let progress): "Reading audio…" + percent(progress)
        case .transcribing(let progress): "Transcribing…" + percent(progress)
        case .done: "Done"
        case .failed(let message): message
        case .cancelled: "Cancelled"
        }
    }

    private func percent(_ progress: Double?) -> String {
        guard let progress else { return "" }
        return " \(Int(progress * 100))%"
    }
}
