import MurmurCore
import SwiftUI

/// "Ask your meetings": a question over every meeting, answered as a dated list where each line
/// opens the meeting at its moment. Fixed shapes read in code (decisions, what is owed, anything
/// about a word), with the person named in the question as a filter.
struct MeetingAskBox: View {
    @Environment(AppModel.self) private var model
    @Environment(\.isSnapshot) private var isSnapshot

    var body: some View {
        @Bindable var meetings = model.meetings
        HStack(spacing: Theme.Space.s) {
            Image(systemName: "text.magnifyingglass").font(.system(size: 13)).foregroundStyle(Theme.textTertiary)
            if isSnapshot {
                SnapshotTextField(meetings.question, placeholder: "Ask your meetings: what did we decide with Dana?", font: .system(size: 14))
            } else {
                TextField("Ask your meetings: what did we decide with Dana?", text: $meetings.question)
                    .textFieldStyle(.plain).font(.system(size: 14))
                    .onSubmit { Task { await meetings.ask() } }
            }
            if meetings.answer != nil {
                IconButton(symbol: "xmark", help: "Clear") { meetings.clearAnswer() }
            }
        }
        .padding(.horizontal, Theme.Space.m)
        .padding(.vertical, 10)
        .background(RoundedRectangle(cornerRadius: Theme.Radius.card).fill(Theme.bgRaised))
        .overlay(RoundedRectangle(cornerRadius: Theme.Radius.card).strokeBorder(Theme.hairlineStrong, lineWidth: 0.5))
    }
}

struct MeetingAnswerView: View {
    @Environment(AppModel.self) private var model
    let answer: MeetingAnswer

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            if let reason = answer.emptyReason {
                Text(reason).font(Theme.Font.body).foregroundStyle(Theme.textSecondary)
            }
            if let heading = answer.heading {
                Text(heading).font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.textPrimary)
            }
            ForEach(groups, id: \.noteId) { group in
                VStack(alignment: .leading, spacing: 6) {
                    Button { model.meetings.open(noteId: group.noteId, at: nil, app: model) } label: {
                        HStack(spacing: 6) {
                            Text(group.title).font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.textPrimary)
                            Text(group.date.meetingDayLabel(now: model.dayClock.now)).font(.system(size: 11)).foregroundStyle(Theme.textTertiary)
                            Image(systemName: "arrow.right").font(.system(size: 9, weight: .semibold)).foregroundStyle(Theme.textTertiary)
                        }
                    }
                    .buttonStyle(.plain)
                    ForEach(group.lines) { line in lineView(line) }
                }
                .padding(.vertical, 4)
            }
            Text("Answered from your meetings on this Mac. Each line is what was stored, not a guess.")
                .font(.system(size: 11)).foregroundStyle(Theme.textTertiary)
        }
        .padding(Theme.Space.l)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: Theme.Radius.card).fill(Theme.workingTint.opacity(0.6)))
    }

    private struct AnswerGroup {
        let noteId: Int64
        let title: String
        let date: Date
        var lines: [MeetingAnswer.Line]
    }

    private var groups: [AnswerGroup] {
        var result: [AnswerGroup] = []
        for line in answer.lines {
            if let index = result.firstIndex(where: { $0.noteId == line.noteId }) {
                result[index].lines.append(line)
            } else {
                result.append(AnswerGroup(noteId: line.noteId, title: line.noteTitle, date: line.noteDate, lines: [line]))
            }
        }
        return result
    }

    private func lineView(_ line: MeetingAnswer.Line) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(label(line.kind)).font(.system(size: 10, weight: .semibold)).foregroundStyle(line.kind == .yourNote ? Theme.phosphor : Theme.working)
                .frame(width: 58, alignment: .leading)
            VStack(alignment: .leading, spacing: 2) {
                Text(line.kind == .quote ? line.speaker.map { "\($0): “\(line.text)”" } ?? line.text : line.text)
                    .font(.system(size: 13.5)).foregroundStyle(line.kind == .meeting ? Theme.textTertiary : Theme.textPrimary)
                if let quote = line.quote {
                    Text(line.speaker.map { "\($0): “\(quote)”" } ?? "“\(quote)”")
                        .font(.system(size: 12)).foregroundStyle(Theme.textTertiary).lineLimit(2)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if let at = line.atSeconds {
                MomentChip(moment: MeetingMoment(seconds: at, lineIndex: nil, speaker: line.speaker)) {
                    model.meetings.open(noteId: line.noteId, at: at, app: model)
                }
            }
        }
    }

    private func label(_ kind: MeetingAnswer.Kind) -> String {
        switch kind {
        case .decision: "DECIDED"
        case .item: "OWED"
        case .closed: "CLOSED"
        case .changed: "CHANGED"
        case .yourNote: "YOU WROTE"
        case .quote: "SAID"
        case .meeting: "MEETING"
        }
    }
}

/// What is kept on this Mac, and the two things a person may want to do with all of it.
struct MeetingDataCard: View {
    @Environment(AppModel.self) private var model
    @State private var erasePlan: MeetingErasePlan?
    @State private var exported: String?

    var body: some View {
        let overview = model.meetings.overview
        MeetingSection(title: "On this Mac") {
            HStack(alignment: .center, spacing: Theme.Space.l) {
                Image(systemName: "internaldrive").font(.system(size: 18)).foregroundStyle(Theme.textTertiary)
                VStack(alignment: .leading, spacing: 2) {
                    Text("\(Self.meetings(overview.meetingCount)) recorded from calls · \(ByteCountFormatter.string(fromByteCount: overview.audioBytes, countStyle: .file)) of audio")
                        .font(.system(size: 13, weight: .medium)).foregroundStyle(Theme.textPrimary)
                    Text(exported ?? "Full history, no 30-day limit. Nothing is uploaded; nothing trains on it.")
                        .font(.system(size: 11.5)).foregroundStyle(Theme.textSecondary)
                }
                Spacer()
                Button("Export all…") { exportAll() }.buttonStyle(SecondaryButtonStyle())
                Button("Erase meetings…") { prepareErase() }
                    .buttonStyle(SecondaryButtonStyle())
                    .disabled(overview.meetingCount == 0 || model.recorder.isFinishing)
            }
            .padding(Theme.Space.m)
            .background(RoundedRectangle(cornerRadius: Theme.Radius.card).strokeBorder(Theme.hairline, lineWidth: 0.5))
        }
        .confirmationDialog(
            "Erase the meetings recorded from calls?",
            isPresented: Binding(get: { erasePlan != nil }, set: { if !$0 { erasePlan = nil } }),
            presenting: erasePlan
        ) { plan in
            Button("Erase \(Self.meetings(plan.count))", role: .destructive) {
                if let selected = model.selectedNoteID, plan.noteIDs.contains(selected) { model.selectedNoteID = nil }
                Task { await model.meetings.erase(plan) }
            }
        } message: { plan in
            Text(Self.eraseMessage(plan))
        }
    }

    static func meetings(_ count: Int) -> String { "\(count) meeting\(count == 1 ? "" : "s")" }

    /// Names exactly what goes: the same notes the count counts, and what stays.
    static func eraseMessage(_ plan: MeetingErasePlan) -> String {
        "The \(meetings(plan.count)) Hushy recorded from a detected call: their pages, transcripts, your typed lines "
            + "and audio. Memos, imported files and recordings you started yourself stay. This can't be undone."
    }

    private func prepareErase() {
        let keeping = Set([model.recorder.activeNote?.id].compactMap { $0 })
        Task {
            guard let plan = await model.meetings.erasePlan(keeping: keeping), plan.count > 0 else { return }
            erasePlan = plan
        }
    }

    private func exportAll() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "Export here"
        guard panel.runModal() == .OK, let folder = panel.url else { return }
        var count = 0
        for note in model.library.notes where note.status == .ready {
            let done = (note.id.flatMap { try? model.store.doneActionItemIndexes(noteId: $0) }) ?? []
            if (try? MarkdownExporter.export(note, to: folder, done: done)) != nil { count += 1 }
        }
        exported = "Exported \(count) meetings as Markdown to \(folder.lastPathComponent)."
    }
}

/// Everyone's page: every meeting with this person, newest first, what was decided and what is
/// still open between you.
struct MeetingPersonView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.isSnapshot) private var isSnapshot
    let name: String
    var pinned: [MeetingTimelineEntry]?
    @State private var entries: [MeetingTimelineEntry] = []

    private var timeline: [MeetingTimelineEntry] {
        pinned ?? (isSnapshot ? model.meetings.timeline(for: name) : entries)
    }

    var body: some View {
        Group {
            if isSnapshot { column.frame(maxHeight: .infinity, alignment: .top) } else { ScrollView { column } }
        }
        .task(id: name) { if pinned == nil { entries = model.meetings.timeline(for: name) } }
    }

    private var column: some View {
        VStack(alignment: .leading, spacing: Theme.Space.xl) {
            Button { model.meetings.focus = .overview } label: {
                Label("Meetings", systemImage: "chevron.left").font(Theme.Font.caption).foregroundStyle(Theme.textSecondary)
            }
            .buttonStyle(.plain)
            HStack(spacing: Theme.Space.m) {
                MeetingAvatar(name: name, size: 44)
                VStack(alignment: .leading, spacing: 2) {
                    Text(name).font(Theme.Font.section).foregroundStyle(Theme.textPrimary)
                    Text(summary).font(Theme.Font.caption).foregroundStyle(Theme.textTertiary)
                }
            }
            let open = timeline.flatMap(\.openItems)
            if !open.isEmpty {
                HStack(alignment: .top, spacing: Theme.Space.l) {
                    MeetingItemColumn(title: "You owe \(firstName)", items: open.filter(\.isMine), empty: "Nothing.")
                    MeetingItemColumn(title: "\(firstName) owes", items: open.filter { owes($0) }, empty: "Nothing.")
                }
            }
            MeetingSection(title: "Timeline", count: timeline.count) {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(timeline) { entry in entryRow(entry) }
                }
            }
        }
        .padding(.horizontal, Theme.Space.xxl + 8)
        .padding(.top, 44)
        .padding(.bottom, Theme.Space.section)
        .frame(maxWidth: 820, alignment: .leading)
        .frame(maxWidth: .infinity)
    }

    private func owes(_ item: MeetingItemRef) -> Bool {
        let owner = item.detail.owner.lowercased()
        return !item.isMine && (owner == name.lowercased() || owner == firstName.lowercased())
    }

    private var firstName: String { name.split(separator: " ").first.map(String.init) ?? name }

    private var summary: String {
        guard let last = timeline.first else { return "No recorded meetings yet" }
        return "\(timeline.count) meeting\(timeline.count == 1 ? "" : "s") · last \(last.date.meetingDayLabel(now: model.dayClock.now))"
    }

    private func entryRow(_ entry: MeetingTimelineEntry) -> some View {
        HStack(alignment: .top, spacing: Theme.Space.m) {
            VStack(spacing: 0) {
                Circle().fill(Theme.textTertiary).frame(width: 7, height: 7).padding(.top, 6)
                Rectangle().fill(Theme.hairline).frame(width: 1).frame(maxHeight: .infinity)
            }
            .frame(width: 10)
            Button { model.meetings.open(noteId: entry.noteId, at: nil, app: model) } label: {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        Text(entry.title).font(.system(size: 15, weight: .semibold)).foregroundStyle(Theme.textPrimary)
                        Text("\(entry.date.meetingDayLabel(now: model.dayClock.now)) · \(DurationLabelFormatter.label(seconds: entry.durationSeconds))")
                            .font(.system(size: 11.5)).foregroundStyle(Theme.textTertiary)
                    }
                    ForEach(entry.decisions.prefix(3), id: \.self) { decision in
                        MeetingRowLine(row: .init(id: decision, text: decision, author: .model, moment: nil))
                    }
                    if !entry.openItems.isEmpty {
                        Text("\(entry.openItems.count) still open").font(.system(size: 11.5, weight: .medium)).foregroundStyle(Theme.warning)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.bottom, Theme.Space.l)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .fixedSize(horizontal: false, vertical: true)
    }
}
