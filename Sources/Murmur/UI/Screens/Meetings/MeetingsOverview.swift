import MurmurCore
import SwiftUI

/// Between meetings: what is next and what to bring to it, what you owe and are owed across every
/// meeting, the people you meet, a question box over all of it, and what is kept on this Mac. All
/// of it is composed in code from stored rows; nothing here asks a model to merge meetings.
struct MeetingsOverview: View {
    @Environment(AppModel.self) private var model
    @Environment(\.isSnapshot) private var isSnapshot

    private var meetings: MeetingsModel { model.meetings }
    private var overview: MeetingsModel.Overview { meetings.overview }

    var body: some View {
        Group {
            if isSnapshot { column.frame(maxHeight: .infinity, alignment: .top) } else { ScrollView { column } }
        }
        .task { if !isSnapshot { await meetings.refreshOverview() } }
    }

    private var column: some View {
        VStack(alignment: .leading, spacing: Theme.Space.xl + 4) {
            header
            if meetings.crossMeetingMemory {
                MeetingAskBox()
                if let answer = meetings.answer { MeetingAnswerView(answer: answer) }
            }
            upNext
            commitments
            if meetings.crossMeetingMemory, !overview.people.isEmpty { people }
            MeetingDataCard()
        }
        .padding(.horizontal, Theme.Space.xxl + 8)
        .padding(.top, 44)
        .padding(.bottom, Theme.Space.section)
        .frame(maxWidth: 820, alignment: .leading)
        .frame(maxWidth: .infinity)
    }

    private var header: some View {
        HStack(alignment: .center) {
            Text("Recorded and kept on this Mac, both sides, no bot. Nothing is uploaded.")
                .font(Theme.Font.body).foregroundStyle(Theme.textSecondary)
            Spacer()
            if let live = model.recorder.activeNote, model.recorder.isRecording {
                Button { model.selectedNoteID = live.id } label: {
                    Label("Back to the meeting", systemImage: "record.circle.fill")
                }
                .buttonStyle(PrimaryButtonStyle())
            } else {
                Button {
                    model.toggleNoteRecording()
                } label: {
                    Label("Start a meeting", systemImage: "record.circle")
                }
                .buttonStyle(PrimaryButtonStyle())
                .help("Records your microphone and the call's audio (⇧⌘N)")
            }
        }
    }

    @ViewBuilder
    private var upNext: some View {
        if let event = overview.upcoming {
            MeetingSection(title: "Up next") {
                Card {
                    VStack(alignment: .leading, spacing: Theme.Space.m) {
                        HStack(alignment: .firstTextBaseline) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(event.title).font(.system(size: 18, weight: .semibold)).foregroundStyle(Theme.textPrimary)
                                Text(eventLine(event)).font(Theme.Font.caption).foregroundStyle(Theme.textTertiary)
                            }
                            Spacer()
                            Button("Start notes") { model.toggleNoteRecording() }.buttonStyle(SecondaryButtonStyle())
                                .disabled(model.recorder.isRecording)
                        }
                        if let prep = overview.prep { MeetingPrepView(prep: prep) }
                    }
                }
            }
        } else if !overview.calendarReadable {
            MeetingSection(title: "Up next") {
                Text("Turn on Calendar in Settings → Meetings to see your next meeting here, with what is still open from the last one with the same people.")
                    .font(Theme.Font.caption).foregroundStyle(Theme.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func eventLine(_ event: CalendarEvent) -> String {
        let start = event.start.formatted(date: .omitted, time: .shortened)
        let minutes = Int(event.start.timeIntervalSince(model.dayClock.now) / 60)
        let when = minutes > 0 && minutes < 120 ? "in \(minutes) min · \(start)" : event.start.meetingDayLabel(now: model.dayClock.now)
        let others = event.attendees.filter { !$0.isCurrentUser }.map(\.name)
        return others.isEmpty ? when : "\(when) · with \(ListFormatter.localizedString(byJoining: Array(others.prefix(4))))"
    }

    private var commitments: some View {
        let owed = overview.commitments
        return HStack(alignment: .top, spacing: Theme.Space.l) {
            MeetingItemColumn(title: "You owe", items: owed.iOwe, empty: "Nothing you promised is still open.")
            MeetingItemColumn(title: "Owed to you", items: owed.owedToMe, empty: "Nobody owes you anything from a meeting.")
        }
    }

    private var people: some View {
        MeetingSection(title: "People", count: overview.people.count) {
            FlowRow(spacing: Theme.Space.s) {
                ForEach(overview.people) { person in
                    Button { meetings.focus = .person(person.name); model.selectedNoteID = nil } label: {
                        HStack(spacing: 6) {
                            MeetingAvatar(name: person.name)
                            Text(person.name).font(.system(size: 13, weight: .medium)).foregroundStyle(Theme.textPrimary)
                            Text("\(person.meetingCount)").font(.system(size: 11).monospacedDigit()).foregroundStyle(Theme.textTertiary)
                        }
                        .padding(.leading, 4).padding(.trailing, 10).padding(.vertical, 4)
                        .background(Capsule().fill(Theme.bgRaised))
                        .overlay(Capsule().strokeBorder(Theme.hairline, lineWidth: 0.5))
                    }
                    .buttonStyle(.plain)
                }
            }
            if overview.companies.isEmpty {
                Text("Companies appear once Hushy may keep attendees' email domains with each meeting, on this Mac.")
                    .font(.system(size: 11)).foregroundStyle(Theme.textTertiary)
            }
        }
    }
}

/// The brief before a meeting: what happened last time with these people, what is still open, and
/// talking points to start the notepad with.
struct MeetingPrepView: View {
    @Environment(AppModel.self) private var model
    let prep: MeetingPrep

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.m) {
            if prep.isFirstMeeting {
                Text("First meeting with \(ListFormatter.localizedString(byJoining: Array(prep.attendees.prefix(3)))). Nothing to bring forward.")
                    .font(Theme.Font.caption).foregroundStyle(Theme.textSecondary)
            } else {
                if let last = prep.lastTime.first {
                    Button { model.meetings.open(noteId: last.noteId, at: nil, app: model) } label: {
                        HStack(spacing: 6) {
                            Text("Last time").font(.system(size: 11, weight: .semibold)).foregroundStyle(Theme.textTertiary)
                            Text("\(last.title) · \(last.date.meetingDayLabel(now: model.dayClock.now))")
                                .font(.system(size: 12)).foregroundStyle(Theme.textSecondary)
                            Image(systemName: "arrow.right").font(.system(size: 9, weight: .semibold)).foregroundStyle(Theme.textTertiary)
                        }
                    }
                    .buttonStyle(.plain)
                    ForEach(last.decisions.prefix(3), id: \.self) { decision in
                        MeetingRowLine(row: .init(id: decision, text: decision, author: .model, moment: nil))
                    }
                }
                if !prep.talkingPoints.isEmpty {
                    Text("Bring up").font(.system(size: 11, weight: .semibold)).foregroundStyle(Theme.textTertiary)
                    ForEach(prep.talkingPoints, id: \.self) { point in
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Image(systemName: "arrow.turn.down.right").font(.system(size: 10)).foregroundStyle(Theme.phosphor)
                            Text(point).font(.system(size: 14)).foregroundStyle(Theme.textPrimary)
                        }
                    }
                }
            }
        }
    }
}

/// One side of "what I owe / what I'm owed", each item opening the meeting it was promised in.
struct MeetingItemColumn: View {
    @Environment(AppModel.self) private var model
    let title: String
    let items: [MeetingItemRef]
    let empty: String

    var body: some View {
        MeetingSection(title: title, count: items.count) {
            Card(padding: Theme.Space.m) {
                VStack(alignment: .leading, spacing: Theme.Space.s) {
                    if items.isEmpty {
                        Text(empty).font(Theme.Font.caption).foregroundStyle(Theme.textTertiary)
                    }
                    ForEach(items.prefix(6)) { item in
                        Button { model.meetings.open(noteId: item.noteId, at: nil, app: model) } label: {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(item.detail.task).font(.system(size: 14)).foregroundStyle(Theme.textPrimary)
                                    .multilineTextAlignment(.leading)
                                Text(([item.isMine ? "" : item.detail.owner, item.detail.due, item.noteTitle].filter { !$0.isEmpty })
                                        .joined(separator: " · "))
                                    .font(.system(size: 11.5)).foregroundStyle(Theme.textTertiary).lineLimit(1)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                    if items.count > 6 {
                        Text("and \(items.count - 6) more").font(.system(size: 11)).foregroundStyle(Theme.textTertiary)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }
}

struct MeetingAvatar: View {
    let name: String
    var size: CGFloat = 20

    var body: some View {
        let initials = name.split(separator: " ").prefix(2).compactMap(\.first).map(String.init).joined()
        let index = abs(name.lowercased().unicodeScalars.reduce(0) { $0 &+ Int($1.value) }) % Theme.speakerColors.count
        return Text(initials.uppercased())
            .font(.system(size: size * 0.42, weight: .semibold))
            .foregroundStyle(Theme.speakerColors[index])
            .frame(width: size, height: size)
            .background(Circle().fill(Theme.speakerColors[index].opacity(0.16)))
    }
}

/// Wraps chips onto as many lines as they need.
struct FlowRow: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = arrange(width: proposal.width ?? .infinity, subviews: subviews)
        return CGSize(width: proposal.width ?? rows.width, height: rows.height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, line: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x + size.width > bounds.maxX, x > bounds.minX { x = bounds.minX; y += line + spacing; line = 0 }
            view.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            line = max(line, size.height)
        }
    }

    private func arrange(width: CGFloat, subviews: Subviews) -> (width: CGFloat, height: CGFloat) {
        var x: CGFloat = 0, height: CGFloat = 0, line: CGFloat = 0, widest: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x + size.width > width, x > 0 { height += line + spacing; x = 0; line = 0 }
            x += size.width + spacing
            widest = max(widest, x)
            line = max(line, size.height)
        }
        return (widest, height + line)
    }
}
