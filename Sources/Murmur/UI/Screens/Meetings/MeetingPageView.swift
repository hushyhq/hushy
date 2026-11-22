import MurmurCore
import SwiftUI

/// The page a meeting becomes, about a minute after it ends. Read top to bottom it answers, in
/// order: what did I write, what did we decide, who owes what by when, what is still open, and,
/// underneath, the words themselves with who said them. Every row has its moment: the play chip
/// scrolls the transcript there, marks the line and plays the recording from it.
struct MeetingPageView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.isSnapshot) private var isSnapshot
    let note: Note
    /// Snapshots pass the content in; the app reads it from the store.
    var pinned: MeetingsModel.PageContent?
    @State private var content: MeetingsModel.PageContent?
    @State private var highlighted: Int?
    @State private var showTranscript = true
    @State private var showDiscussed = false
    @State private var confirmDelete = false
    @State private var newLine = ""

    private var meetings: MeetingsModel { model.meetings }
    private var current: MeetingsModel.PageContent? {
        pinned ?? content ?? (isSnapshot ? meetings.content(for: note) : nil)
    }

    var body: some View {
        ScrollViewReader { proxy in
            Group {
                if isSnapshot {
                    column.frame(maxHeight: .infinity, alignment: .top)
                } else {
                    ScrollView { column }
                }
            }
            .onChange(of: meetings.jump) { _, jump in apply(jump, proxy: proxy) }
            .onAppear {
                reload()
                apply(meetings.jump, proxy: proxy)
            }
        }
        .onChange(of: note) { _, _ in reload() }
        .task(id: note.status) {
            // Speaker turns land a little after the page (diarization runs after it): look again
            // for as long as the stage track says they are coming, then stop.
            guard note.status == .ready, !isSnapshot else { return }
            while expectsSpeakerTurns, current?.hasSpeakerTurns == false, !Task.isCancelled {
                try? await Task.sleep(for: .seconds(5))
                reload()
            }
        }
        .confirmationDialog("Delete this meeting?", isPresented: $confirmDelete) {
            Button("Delete", role: .destructive) { model.deleteNote(note) }
        } message: {
            Text("The page, transcript, your notes and the audio are removed from this Mac.")
        }
    }

    private var column: some View {
        VStack(alignment: .leading, spacing: Theme.Space.xl + 4) {
            MeetingPageHeader(note: note, content: current, confirmDelete: $confirmDelete)
            stageBanner
            if note.status == .failed { MeetingIncompleteLine(note: note) }
            if let page = current?.page { sections(page) }
        }
        .padding(.horizontal, Theme.Space.xxl + 8)
        .padding(.top, 44)
        .padding(.bottom, Theme.Space.section)
        .frame(maxWidth: 780, alignment: .leading)
        .frame(maxWidth: .infinity)
    }

    /// Speaker turns are only expected for a recording that finished in the last few minutes;
    /// an old note, an import or a failed diarization never gets them, and the page says ready.
    private var expectsSpeakerTurns: Bool {
        FeatureFlags.speakerLabels && note.source == .recording && model.dayClock.now.timeIntervalSince(note.updatedAt) < 300
    }

    @ViewBuilder
    private var stageBanner: some View {
        let stage = MeetingAfterStage.stage(
            status: note.status, isTranscribing: model.recorder.isFinishing && model.recorder.activeNote?.id == note.id,
            hasSpeakerTurns: current?.hasSpeakerTurns ?? false, expectsSpeakerTurns: expectsSpeakerTurns)
        if stage != .ready, note.status != .failed {
            MeetingStageTrack(stage: stage)
        }
    }

    @ViewBuilder
    private func sections(_ page: MeetingPage) -> some View {
        MeetingSection(title: "Your notes", count: page.yourNotes.count) {
            VStack(alignment: .leading, spacing: Theme.Space.s) {
                ForEach(page.yourNotes) { row in rowLine(row) }
                addLineField
            }
        }
        if !page.decisions.isEmpty {
            MeetingSection(title: "Decided", count: page.decisions.count) {
                VStack(alignment: .leading, spacing: Theme.Space.s) { ForEach(page.decisions) { rowLine($0) } }
            }
        }
        if !page.commitments.isEmpty { commitments(page) }
        if !page.openQuestions.isEmpty {
            MeetingSection(title: "Still open", count: page.openQuestions.count) {
                VStack(alignment: .leading, spacing: Theme.Space.s) { ForEach(page.openQuestions) { rowLine($0) } }
            }
        }
        if !page.keyPoints.isEmpty { discussed(page) }
        transcript(page)
    }

    private func rowLine(_ row: MeetingPage.Row) -> some View {
        MeetingRowLine(row: row, isPlaying: row.moment.map { meetings.audio.isPlaying(noteId: note.id, seconds: $0.seconds) } ?? false,
                       play: play)
    }

    private func commitments(_ page: MeetingPage) -> some View {
        MeetingSection(
            title: "Who owes what", count: page.commitments.filter { !$0.isDone }.count,
            trailing: AnyView(followUpButton)
        ) {
            Card(padding: Theme.Space.m) {
                VStack(alignment: .leading, spacing: Theme.Space.s) {
                    if !page.mine.isEmpty {
                        groupLabel("You")
                        ForEach(page.mine) { commitmentRow($0) }
                    }
                    if !page.theirs.isEmpty {
                        if !page.mine.isEmpty { Divider().overlay(Theme.hairline).padding(.vertical, 2) }
                        groupLabel("Others")
                        ForEach(page.theirs) { commitmentRow($0) }
                    }
                }
            }
            if let flash = meetings.flash {
                Label(flash, systemImage: "checkmark").font(Theme.Font.caption).foregroundStyle(Theme.textSecondary)
            }
        }
    }

    private func groupLabel(_ text: String) -> some View {
        Text(text).font(.system(size: 11, weight: .semibold)).foregroundStyle(Theme.textTertiary)
    }

    private func commitmentRow(_ commitment: MeetingPage.Commitment) -> some View {
        CommitmentRow(
            commitment: commitment,
            isPlaying: commitment.moment.map { meetings.audio.isPlaying(noteId: note.id, seconds: $0.seconds) } ?? false,
            toggle: {
                if let uuid = commitment.factUUID {
                    model.library.setActionFactDone(note, uuid: uuid, isDone: !commitment.isDone)
                } else {
                    model.library.toggleActionItemDone(note, itemIndex: commitment.itemIndex)
                }
                reload()
            },
            play: play,
            addToReminders: { Task { await meetings.addToReminders(commitment, from: note) } })
    }

    private var followUpButton: some View {
        Button { meetings.draftFollowUp(note) } label: {
            Label("Draft follow-up", systemImage: "envelope").font(.system(size: 11, weight: .medium))
        }
        .buttonStyle(SecondaryButtonStyle())
        .help("Opens a draft in your mail app with the decisions and who owes what. Hushy never sends it.")
    }

    private func discussed(_ page: MeetingPage) -> some View {
        MeetingSection(title: "Discussed", count: page.keyPoints.count, trailing: AnyView(disclosure($showDiscussed))) {
            if showDiscussed || isSnapshot {
                VStack(alignment: .leading, spacing: Theme.Space.s) { ForEach(page.keyPoints) { rowLine($0) } }
            }
        }
    }

    private func disclosure(_ flag: Binding<Bool>) -> some View {
        Button { withAnimation(Theme.snappy) { flag.wrappedValue.toggle() } } label: {
            Image(systemName: "chevron.down").font(.system(size: 9, weight: .bold)).foregroundStyle(Theme.textTertiary)
                .rotationEffect(.degrees(flag.wrappedValue || isSnapshot ? 0 : -90))
        }
        .buttonStyle(.plain)
    }

    private func transcript(_ page: MeetingPage) -> some View {
        MeetingSection(title: "Transcript", trailing: AnyView(disclosure($showTranscript))) {
            if showTranscript {
                // A memo's text can be shown in another style; a meeting's transcript stays as it was said.
                if current?.restyle == .available {
                    NoteRestyleSection(note: note) { transcriptText(page) }
                } else {
                    transcriptText(page)
                }
            }
        }
    }

    @ViewBuilder
    private func transcriptText(_ page: MeetingPage) -> some View {
        if page.hasTimedTranscript {
            MeetingTranscriptList(
                lines: page.transcript, highlighted: highlighted,
                playingSeconds: meetings.audio.playing?.noteId == note.id ? meetings.audio.playing?.seconds : nil,
                youName: model.settings.userName, play: play)
        } else {
            Text(note.transcript.isEmpty ? "No transcript yet." : note.transcript)
                .font(.system(size: 14)).foregroundStyle(Theme.textSecondary).lineSpacing(5)
                .textSelection(.enabled)
        }
    }

    @ViewBuilder
    private var addLineField: some View {
        if isSnapshot {
            SnapshotTextField("", placeholder: "Add a note…", font: .system(size: 14))
                .padding(.leading, 13)
        } else {
            TextField("Add a note…", text: $newLine)
                .textFieldStyle(.plain)
                .font(.system(size: 14))
                .padding(.leading, 13)
                .onSubmit {
                    guard let id = note.id else { return }
                    meetings.addJot(noteId: id, text: newLine, atSeconds: nil)
                    newLine = ""
                    reload()
                }
        }
    }

    private func journal(of note: Note) -> CaptureJournal? {
        note.id.flatMap { try? model.store.captureJournal(noteId: $0) }
    }

    private func play(_ moment: MeetingMoment) {
        if meetings.audio.isPlaying(noteId: note.id, seconds: moment.seconds) {
            meetings.audio.stop()
            return
        }
        highlighted = moment.lineIndex
        meetings.audio.play(note: note, from: moment.seconds, key: model.encryption.currentKey, journal: journal(of: note))
    }

    /// Opens the moment a row elsewhere pointed at: marks the line, plays from it, and scrolls there
    /// once the transcript rows exist (on a freshly opened page they are laid out a turn later).
    private func apply(_ jump: MeetingsModel.Jump?, proxy: ScrollViewProxy) {
        guard let jump, jump.noteId == note.id, let page = current?.page else { return }
        meetings.jump = nil
        let line = page.transcript.last { $0.start <= jump.seconds + 0.5 }
        highlighted = line?.index
        meetings.audio.play(note: note, from: jump.seconds, key: model.encryption.currentKey, journal: journal(of: note))
        guard let line else { return }
        Task { @MainActor in
            await Task.yield()
            withAnimation(Theme.settle) { proxy.scrollTo("line-\(line.index)", anchor: .center) }
        }
    }

    private func reload() {
        guard pinned == nil else { return }
        content = meetings.content(for: note)
    }
}

/// Title, when and who, how the others were told, and the page's actions.
private struct MeetingPageHeader: View {
    @Environment(AppModel.self) private var model
    @Environment(\.isSnapshot) private var isSnapshot
    let note: Note
    let content: MeetingsModel.PageContent?
    @Binding var confirmDelete: Bool
    @State private var title = ""

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            if isSnapshot {
                Text(note.title).font(.system(size: 32, weight: .regular, design: .serif)).foregroundStyle(Theme.textPrimary)
            } else {
                TextField("Title", text: $title, axis: .vertical)
                    .lineLimit(1...3).textFieldStyle(.plain)
                    .font(.system(size: 32, weight: .regular, design: .serif))
                    .onSubmit {
                        let trimmed = title.trimmingCharacters(in: .whitespaces)
                        if !trimmed.isEmpty, trimmed != note.title { model.library.rename(note, to: trimmed) }
                    }
                    .onAppear { title = note.title }
                    .onChange(of: note.title) { _, new in title = new }
            }
            HStack(spacing: Theme.Space.m) {
                Text(metaLine).font(Theme.Font.caption).foregroundStyle(Theme.textTertiary).lineLimit(1)
                Spacer()
                if isSnapshot {
                    Image(systemName: "ellipsis").font(.system(size: 13, weight: .medium)).foregroundStyle(Theme.textSecondary)
                        .frame(width: 26, height: 26)
                } else {
                    Menu {
                        Button("Copy as Markdown") { copyMarkdown() }
                        Button("Show audio in Finder") {
                            if let path = note.audioPath { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)]) }
                        }
                        Divider()
                        Button("Delete meeting…", role: .destructive) { confirmDelete = true }
                    } label: {
                        Image(systemName: "ellipsis").font(.system(size: 13, weight: .medium)).foregroundStyle(Theme.textSecondary)
                            .frame(width: 26, height: 26)
                    }
                    .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                }
            }
            consentLine
        }
    }

    private var people: [String] {
        let speakers = content?.page.speakers.filter { $0 != "You" && $0 != model.settings.userName } ?? []
        var seen = Set<String>()
        return (speakers + (content?.attendees ?? [])).filter { !$0.hasPrefix("Speaker ") && seen.insert($0.lowercased()).inserted }
    }

    private var metaLine: String {
        var parts = [note.createdAt.meetingDayLabel(now: model.dayClock.now, calendar: model.dayClock.calendar),
                     DurationLabelFormatter.label(seconds: note.durationSeconds)]
        if !people.isEmpty { parts.append("with " + ListFormatter.localizedString(byJoining: Array(people.prefix(4)))) }
        if let app = note.meetingApp { parts.append(app.displayName) }
        return parts.joined(separator: " · ")
    }

    private var consentLine: some View {
        HStack(spacing: 6) {
            Image(systemName: "lock.fill").font(.system(size: 9)).foregroundStyle(Theme.textTertiary)
            Text(content?.consent?.summary.appending(" · ") ?? "")
                .foregroundColor(Theme.textSecondary)
            + Text("Kept on this Mac. Never sent to Hushy or used for training.")
                .foregroundColor(Theme.textTertiary)
        }
        .font(.system(size: 11.5))
    }

    private func copyMarkdown() {
        NSPasteboard.general.clearContents()
        let done = (note.id.flatMap { try? model.store.doneActionItemIndexes(noteId: $0) }) ?? []
        NSPasteboard.general.setString(MarkdownExporter.markdown(for: note, done: done), forType: .string)
        model.meetings.flash = "Copied as Markdown"
    }
}

/// The three steps after Stop, with the one in progress marked. Purple: the model is working.
struct MeetingStageTrack: View {
    @Environment(\.isSnapshot) private var isSnapshot
    let stage: MeetingAfterStage

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            track
            Text(stage == .namingSpeakers
                 ? "The page is ready. Names appear on the transcript in a moment."
                 : "Your notes and the transcript are below already. Decisions and who owes what appear when the page is written.")
                .font(.system(size: 11.5)).foregroundStyle(Theme.textSecondary)
        }
        .padding(.horizontal, Theme.Space.l)
        .padding(.vertical, Theme.Space.m)
        .background(RoundedRectangle(cornerRadius: Theme.Radius.card).fill(Theme.workingTint))
        .accessibilityElement(children: .combine)
    }

    private var track: some View {
        HStack(spacing: Theme.Space.l) {
            ForEach(MeetingAfterStage.allCases.filter { $0 != .ready }, id: \.self) { step in
                HStack(spacing: 6) {
                    if step < stage {
                        Image(systemName: "checkmark").font(.system(size: 10, weight: .bold)).foregroundStyle(Theme.success)
                    } else if step == stage {
                        if isSnapshot {
                            Circle().trim(from: 0, to: 0.7).stroke(Theme.working, lineWidth: 1.5).frame(width: 9, height: 9)
                        } else {
                            ProgressView().controlSize(.mini).tint(Theme.working)
                        }
                    } else {
                        Circle().strokeBorder(Theme.hairlineStrong, lineWidth: 1).frame(width: 9, height: 9)
                    }
                    Text(step.title).font(.system(size: 12, weight: step == stage ? .semibold : .regular))
                        .foregroundStyle(step == stage ? Theme.working : (step < stage ? Theme.textSecondary : Theme.textTertiary))
                }
            }
            Spacer()
        }
    }
}

/// A recording that did not finish says exactly what is left and what can be done.
private struct MeetingIncompleteLine: View {
    @Environment(AppModel.self) private var model
    let note: Note

    var body: some View {
        HStack(alignment: .top, spacing: Theme.Space.m) {
            Image(systemName: "exclamationmark.circle.fill").foregroundStyle(Theme.error)
            VStack(alignment: .leading, spacing: 4) {
                Text(note.transcript.isEmpty ? "This meeting wasn't transcribed" : "Part of this meeting was transcribed")
                    .font(.system(size: 13, weight: .semibold))
                Text("The audio is still on this Mac. Run it again to try the whole recording once more.")
                    .font(Theme.Font.caption).foregroundStyle(Theme.textSecondary)
                LinkLikeButton(title: "Run it again") { model.retryNoteTranscription(note) }
            }
        }
        .padding(Theme.Space.l)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: Theme.Radius.card).fill(Theme.error.opacity(0.1)))
    }
}
