import MurmurCore
import SwiftUI

/// The transcript under a meeting page: one turn per speaker change, with the time it started.
/// The line a row jumped to is marked, and the line being played carries the live (lime) edge.
/// Consecutive lines from one speaker share one name, so a long monologue reads as one turn.
struct MeetingTranscriptList: View {
    let lines: [MeetingLine]
    let highlighted: Int?
    let playingSeconds: Double?
    let youName: String
    let play: (MeetingMoment) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(lines) { line in
                row(line, showsSpeaker: line.index == 0 || lines[line.index - 1].speaker != line.speaker)
                    .id("line-\(line.index)")
            }
        }
    }

    private func row(_ line: MeetingLine, showsSpeaker: Bool) -> some View {
        let isPlaying = playingSeconds.map { $0 >= line.start - 0.5 && $0 < max(line.end, line.start + 1) } ?? false
        let isMarked = highlighted == line.index
        return HStack(alignment: .firstTextBaseline, spacing: Theme.Space.m) {
            Button { play(MeetingMoment(seconds: line.start, lineIndex: line.index, speaker: line.speaker)) } label: {
                Text(MeetingMoment.clock(line.start))
                    .font(.system(size: 11, design: .monospaced).monospacedDigit())
                    .foregroundStyle(isPlaying ? Theme.phosphor : Theme.textTertiary)
                    .frame(width: 44, alignment: .trailing)
            }
            .buttonStyle(.plain)
            .help("Play from here")
            VStack(alignment: .leading, spacing: 2) {
                if showsSpeaker {
                    Text(displayName(line.speaker))
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(color(for: line.speaker))
                }
                Text(line.text)
                    .font(.system(size: 14))
                    .foregroundStyle(Theme.textSecondary)
                    .lineSpacing(4)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(.vertical, showsSpeaker ? 6 : 2)
        .padding(.horizontal, 8)
        .background(
            RoundedRectangle(cornerRadius: Theme.Radius.control)
                .fill(isMarked ? Theme.phosphorTint : .clear))
        .overlay(alignment: .leading) {
            if isPlaying { Rectangle().fill(Theme.phosphor).frame(width: 2) }
        }
        .animation(Theme.fade, value: isMarked)
    }

    private func displayName(_ speaker: String?) -> String {
        guard let speaker else { return "Someone" }
        return speaker == youName && !youName.isEmpty ? "You" : speaker
    }

    /// "You" is ink; everyone else gets a stable speaker colour by order of first appearance.
    private func color(for speaker: String?) -> Color {
        guard let speaker, speaker != "You", speaker != youName else { return Theme.textPrimary }
        var order: [String] = []
        for line in lines {
            if let name = line.speaker, name != "You", name != youName, !order.contains(name) { order.append(name) }
        }
        let index = order.firstIndex(of: speaker) ?? 0
        return Theme.speakerColors[index % Theme.speakerColors.count]
    }
}
