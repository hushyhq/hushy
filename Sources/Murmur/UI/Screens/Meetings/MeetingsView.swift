import MurmurCore
import SwiftUI

/// The Meetings section: a list of meetings by day on the left, and on the right whichever is
/// open: the overview (between meetings), a person, the live notepad while recording, or a
/// meeting's page. Replaces the old Notes page in builds where meetings are on.
struct MeetingsView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.isSnapshot) private var isSnapshot
    /// Snapshots pass a live state; the app reads the recorder.
    @Environment(\.snapshotMeetingLive) private var pinnedLive
    @Environment(\.snapshotMeetingNow) private var pinnedNow
    @State private var query = ""
    @State private var compactShowsDetail = false
    @State private var isTargetedForDrop = false

    var body: some View {
        GeometryReader { geometry in
            let decision = DetailLayout.decide(
                available: geometry.size.width, preferredList: 280, minimumList: 260, minimumDetail: 460,
                hasSelection: true, showSelectedDetail: compactShowsDetail, dividerWidth: 0.5)
            switch decision {
            case .split:
                HStack(alignment: .top, spacing: 0) {
                    list.frame(width: 280)
                    Rectangle().fill(Theme.hairline).frame(width: 0.5)
                    detail
                }
            case .listOnly:
                CompactList(onShowDetail: { compactShowsDetail = true }) { list }
            case .detailOnly:
                CompactDetail(backTitle: "Meetings", onBack: { compactShowsDetail = false }) { detail }
            }
        }
        .background(Theme.bgBase)
        .onChange(of: model.selectedNoteID) { _, id in if id != nil { compactShowsDetail = true } }
        .dropDestination(for: URL.self) { urls, _ in model.importFiles(urls) > 0 } isTargeted: { isTargetedForDrop = $0 }
        .overlay {
            if isTargetedForDrop {
                RoundedRectangle(cornerRadius: Theme.Radius.sheet).strokeBorder(Theme.phosphor, style: StrokeStyle(lineWidth: 2, dash: [6]))
                    .padding(Theme.Space.l)
                    .overlay(Text("Drop audio or video to transcribe it on this Mac").font(Theme.Font.emphasis))
            }
        }
    }

    // MARK: Detail

    private var selectedNote: Note? {
        guard let id = model.selectedNoteID else { return nil }
        if let active = model.recorder.activeNote, active.id == id { return active }
        return model.library.notes.first { $0.id == id }
    }

    @ViewBuilder
    private var detail: some View {
        Group {
            if let live = pinnedLive {
                MeetingLiveView(state: live, now: pinnedNow)
            } else if let note = selectedNote, note.id == model.recorder.activeNote?.id, model.recorder.isRecording {
                liveView(for: note)
            } else if let note = selectedNote {
                MeetingPageView(note: note).id(note.id)
            } else if model.meetings.crossMeetingMemory, case let .person(name) = model.meetings.focus {
                MeetingPersonView(name: name).id(name)
            } else {
                MeetingsOverview()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func liveView(for note: Note) -> some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            let id = note.id ?? 0
            let _ = model.meetings.revision
            if let state = LiveMeetingState.from(
                model.recorder, turns: model.meetings.liveTurns(noteId: id), jots: model.meetings.jots(noteId: id),
                consent: try? model.store.consent(forNote: id), now: context.date) {
                MeetingLiveView(state: state)
            }
        }
    }

    // MARK: List

    private var meetings: [Note] {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        var notes = trimmed.isEmpty ? model.library.notes : ((try? model.store.searchNotes(trimmed)) ?? [])
        if let active = model.recorder.activeNote ?? pinnedLive?.note, !notes.contains(where: { $0.id == active.id }), trimmed.isEmpty {
            notes.insert(active, at: 0)
        }
        return notes
    }

    private var list: some View {
        VStack(alignment: .leading, spacing: Theme.Space.m) {
            HStack(alignment: .firstTextBaseline) {
                Text("Meetings").font(Theme.Font.section)
                if FeatureFlags.isMeetingsPreviewBuild {
                    Text("PREVIEW").font(.system(size: 9, weight: .bold)).tracking(0.8).foregroundStyle(Theme.working)
                        .padding(.horizontal, 5).padding(.vertical, 2)
                        .background(Capsule().fill(Theme.workingTint))
                        .help("A test build with meetings switched on. Release builds have no Meetings section.")
                }
            }
            .padding(.top, 44)
            if isSnapshot {
                SearchFieldLook(prompt: "Search meetings")
            } else {
                SearchField(text: $query, prompt: "Search meetings")
            }
            overviewRow
            rows
        }
        .padding(.horizontal, Theme.Space.l)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(Theme.bgSunken.opacity(0.35))
    }

    private var overviewRow: some View {
        let isOn = model.selectedNoteID == nil && model.meetings.focus == .overview
        let owed = model.meetings.overview.commitments.iOwe.count
        return Button {
            model.selectedNoteID = nil
            model.meetings.focus = .overview
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "square.grid.2x2").font(.system(size: 12)).foregroundStyle(Theme.textSecondary)
                Text("Overview").font(.system(size: 13, weight: .medium)).foregroundStyle(Theme.textPrimary)
                Spacer()
                if owed > 0 {
                    Text("\(owed) you owe").font(.system(size: 11, weight: .medium)).foregroundStyle(Theme.phosphor)
                }
            }
            .padding(.horizontal, 10).padding(.vertical, 8)
            .background(RoundedRectangle(cornerRadius: Theme.Radius.control).fill(isOn ? Theme.selection : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private var rows: some View {
        let grouped = Dictionary(grouping: meetings) { Calendar.current.startOfDay(for: $0.createdAt) }
        let days = grouped.keys.sorted(by: >)
        let stack = LazyVStack(alignment: .leading, spacing: 2) {
            ForEach(days, id: \.self) { day in
                Text(dayTitle(day)).font(.system(size: 11, weight: .semibold)).foregroundStyle(Theme.textTertiary)
                    .padding(.top, Theme.Space.m).padding(.leading, 10)
                ForEach(grouped[day] ?? []) { note in
                    MeetingListRow(note: note, isSelected: note.id == model.selectedNoteID,
                                   isLive: note.id == pinnedLive?.note.id || (note.id == model.recorder.activeNote?.id && model.recorder.isRecording)) {
                        model.meetings.focus = .overview
                        model.selectedNoteID = note.id
                    }
                }
            }
            if meetings.isEmpty {
                Text(query.isEmpty ? "Your meetings will appear here." : "No meetings match.")
                    .font(Theme.Font.caption).foregroundStyle(Theme.textTertiary).padding(10)
            }
        }
        if isSnapshot { stack } else { ScrollView { stack }.scrollIndicators(.never) }
    }

    private func dayTitle(_ day: Date) -> String {
        let calendar = Calendar.current
        if calendar.isDateInToday(day) { return "Today" }
        if calendar.isDateInYesterday(day) { return "Yesterday" }
        return day.formatted(.dateTime.weekday(.wide).month(.abbreviated).day())
    }
}

private struct MeetingListRow: View {
    let note: Note
    let isSelected: Bool
    let isLive: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    if isLive {
                        Circle().fill(Theme.phosphorFill).frame(width: 7, height: 7)
                    }
                    Text(note.title).font(.system(size: 13, weight: .medium)).foregroundStyle(Theme.textPrimary).lineLimit(1)
                }
                Text(subtitle).font(.system(size: 11.5)).foregroundStyle(status == nil ? Theme.textTertiary : Theme.working).lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 10).padding(.vertical, 7)
            .background(RoundedRectangle(cornerRadius: Theme.Radius.control)
                .fill(isSelected ? Theme.selection : (hovering ? Theme.selection.opacity(0.5) : .clear)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }

    private var status: String? {
        if isLive { return "Recording now" }
        switch note.status {
        case .processing: return "Writing the page…"
        case .failed: return "Incomplete · audio kept"
        case .recording, .ready: return nil
        }
    }

    private var subtitle: String {
        if let status { return status }
        var parts = [note.createdAt.formatted(date: .omitted, time: .shortened), DurationLabelFormatter.label(seconds: note.durationSeconds)]
        let open = note.actionItems.count
        if open > 0 { parts.append("\(open) to do") }
        if let app = note.meetingApp { parts.append(app.displayName) }
        return parts.joined(separator: " · ")
    }
}

/// The search field as `ImageRenderer` can draw it.
private struct SearchFieldLook: View {
    let prompt: String

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass").font(.system(size: 12)).foregroundStyle(Theme.textTertiary)
            Text(prompt).font(Theme.Font.body).foregroundStyle(Theme.textTertiary)
            Spacer()
        }
        .padding(.horizontal, 10).padding(.vertical, 7)
        .background(RoundedRectangle(cornerRadius: Theme.Radius.control).fill(Theme.bgRaised))
        .overlay(RoundedRectangle(cornerRadius: Theme.Radius.control).strokeBorder(Theme.hairline, lineWidth: 0.5))
    }
}
