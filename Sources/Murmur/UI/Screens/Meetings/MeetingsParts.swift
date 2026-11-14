import MurmurCore
import SwiftUI

/// Small pieces every meetings screen shares. The rule behind them is the app's own: lime is you,
/// purple is the model. A line the person typed carries a lime tick; a line the model wrote
/// carries a small purple mark, the way Granola keeps your words black and its words grey.
struct AuthorMark: View {
    let author: MeetingPage.Author

    var body: some View {
        Group {
            switch author {
            case .you:
                RoundedRectangle(cornerRadius: 1).fill(Theme.phosphor).frame(width: 3, height: 14)
            case .model:
                Image(systemName: "sparkle").font(.system(size: 8, weight: .semibold)).foregroundStyle(Theme.working)
                    .frame(width: 3, height: 14)
            }
        }
        .accessibilityLabel(author == .you ? "Your note" : "Written by Hushy")
    }
}

/// "▸ 4:05": opens the transcript at that moment and plays from it.
struct MomentChip: View {
    let moment: MeetingMoment
    var isPlaying = false
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 3) {
                Image(systemName: isPlaying ? "stop.fill" : "play.fill").font(.system(size: 7, weight: .bold))
                Text(moment.label).font(.system(size: 11, design: .monospaced).monospacedDigit())
            }
            .foregroundStyle(hovering || isPlaying ? Theme.textPrimary : Theme.textTertiary)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Capsule().fill(hovering || isPlaying ? Theme.selection : Theme.bgSunken.opacity(0.6)))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(moment.speaker.map { "Hear \($0) at \(moment.label)" } ?? "Hear it at \(moment.label)")
        .accessibilityLabel("Play from \(moment.label)")
    }
}

/// A titled group on a meeting page: "DECIDED · 2".
struct MeetingSection<Content: View>: View {
    let title: String
    var count: Int?
    var trailing: AnyView?
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.m) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Eyebrow(title)
                if let count, count > 0 {
                    Text("\(count)").font(Theme.Font.caption.monospacedDigit()).foregroundStyle(Theme.textTertiary)
                }
                Spacer()
                trailing
            }
            content
        }
    }
}

/// One written row: who wrote it, the words, and the way back to the moment.
struct MeetingRowLine: View {
    let row: MeetingPage.Row
    var isPlaying = false
    var play: ((MeetingMoment) -> Void)?

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            AuthorMark(author: row.author).alignmentGuide(.firstTextBaseline) { $0[.bottom] - 3 }
            Text(row.text)
                .font(.system(size: 15))
                .foregroundStyle(Theme.textPrimary)
                .lineSpacing(3)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
            if let moment = row.moment, let play {
                MomentChip(moment: moment, isPlaying: isPlaying) { play(moment) }
            }
        }
    }
}

/// One thing someone owes: check it off, see who and by when, hear where it was promised, and
/// for the person's own items, send it to Reminders in one tap.
struct CommitmentRow: View {
    let commitment: MeetingPage.Commitment
    var isPlaying = false
    let toggle: () -> Void
    var play: ((MeetingMoment) -> Void)?
    var addToReminders: (() -> Void)?
    @State private var hovering = false

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Button { withAnimation(Theme.snappy) { toggle() } } label: {
                Image(systemName: commitment.isDone ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 15))
                    .foregroundStyle(commitment.isDone ? Theme.success : Theme.textTertiary)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(commitment.isDone ? "Mark not done" : "Mark done")
            VStack(alignment: .leading, spacing: 3) {
                Text(commitment.task)
                    .font(.system(size: 14.5))
                    .strikethrough(commitment.isDone, color: Theme.textTertiary)
                    .foregroundStyle(commitment.isDone ? Theme.textTertiary : Theme.textPrimary)
                if !commitment.whoAndWhen.isEmpty {
                    Text(commitment.whoAndWhen)
                        .font(.system(size: 12, weight: commitment.isMine ? .semibold : .regular))
                        .foregroundStyle(commitment.isMine && !commitment.isDone ? Theme.phosphor : Theme.textSecondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if let addToReminders, commitment.isMine, !commitment.isDone {
                Button(action: addToReminders) {
                    Label("Remind me", systemImage: "checklist").font(.system(size: 11, weight: .medium))
                }
                .buttonStyle(SecondaryButtonStyle())
                .opacity(hovering ? 1 : 0.75)
            }
            if let moment = commitment.moment, let play {
                MomentChip(moment: moment, isPlaying: isPlaying) { play(moment) }
            }
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
    }
}

/// A side of the call and whether it is coming through: a dot that glows while that side is
/// heard, a hollow dot when quiet, and a warning colour when it has gone silent for too long.
struct CaptureSideBadge: View {
    let title: String
    let signal: MeetingCapture.Signal

    var body: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(fill)
                .overlay(Circle().strokeBorder(stroke, lineWidth: 1))
                .frame(width: 8, height: 8)
                .shadow(color: signal == .hearing ? Theme.phosphorFill.opacity(0.7) : .clear, radius: 4)
            Text(title).font(.system(size: 12, weight: .medium)).foregroundStyle(.white.opacity(0.9))
            Text(caption).font(.system(size: 11)).foregroundStyle(signal == .silent ? Theme.warning : .white.opacity(0.55))
        }
        .accessibilityElement(children: .combine)
    }

    private var fill: Color {
        switch signal {
        case .hearing: Theme.phosphorFill
        case .silent: Theme.warning
        case .quiet, .off: .clear
        }
    }

    private var stroke: Color {
        switch signal {
        case .hearing: Theme.phosphorFill
        case .silent: Theme.warning
        case .quiet: .white.opacity(0.5)
        case .off: .white.opacity(0.25)
        }
    }

    private var caption: String {
        switch signal {
        case .hearing: "heard"
        case .quiet: "quiet"
        case .silent: "silent"
        case .off: "not recorded"
        }
    }
}

extension Date {
    /// "Today, 9:03 AM", "Yesterday, 4:10 PM", or "Oct 30, 4:10 PM".
    func meetingDayLabel(now: Date = Date(), calendar: Calendar = .current) -> String {
        let time = formatted(date: .omitted, time: .shortened)
        if calendar.isDate(self, inSameDayAs: now) { return "Today, \(time)" }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: now), calendar.isDate(self, inSameDayAs: yesterday) {
            return "Yesterday, \(time)"
        }
        return formatted(.dateTime.month(.abbreviated).day().hour().minute())
    }
}
