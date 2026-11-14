import MurmurCore
import SwiftUI

/// The answer card: a stacked card on the capsule, like the multi-row confirm card, opening
/// toward the screen centre. Purple marks the model's work (the ✦ glyph, the thinking shimmer,
/// the source mark); lime marks what waits for you (Copy, the follow-up mic). Esc or a click
/// outside closes it; holding the action chord while it's open asks a follow-up.
struct AnswerCard: View {
    static let width: CGFloat = 440

    let card: AnswerCardState
    let onCopy: () -> Void
    let onSaveNote: () -> Void
    let onOpenSource: () -> Void
    let onOpenInAssistant: () -> Void
    let onSuggestion: () -> Void
    let onClose: () -> Void
    var onFileReveal: (Int) -> Void = { _ in }
    var onFileOpen: (Int) -> Void = { _ in }
    @Environment(\.isSnapshot) private var isSnapshot
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            header
            switch card.phase {
            case .thinking:
                thinkingRow
            case .listening:
                Text("Listening for a follow-up…")
                    .font(.system(size: 12)).foregroundStyle(.white.opacity(0.6))
            case .failure(let failure):
                failureRows(failure)
            case .files(let content):
                FileResultsRows(content: content, onReveal: onFileReveal, onOpen: onFileOpen)
            case .answer(let content):
                answerRows(content)
                buttons(content)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .frame(width: Self.width, alignment: .leading)
        .background(
            ZStack {
                if !isSnapshot && !reduceTransparency { VisualEffectBlur() }
                Theme.pillSurface
            })
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(.white.opacity(0.08), lineWidth: 0.5))
        .shadow(color: .black.opacity(0.35), radius: 12, y: 4)
        .environment(\.colorScheme, .dark)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(card.accessibilityText)
    }

    /// The question, dim, with the thread count when this is a follow-up.
    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Image(systemName: "sparkle")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(Theme.pillWorking)
            Text(card.question)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.white.opacity(0.55))
                .lineLimit(1)
                .truncationMode(.tail)
            if !card.thread.isEmpty {
                Text("· \(card.thread.count + 1)")
                    .font(.system(size: 11, weight: .medium).monospacedDigit())
                    .foregroundStyle(.white.opacity(0.35))
                    .help("Follow-up \(card.thread.count + 1) in this thread")
            }
            Spacer(minLength: 4)
            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(.white.opacity(0.7))
                    .frame(width: 18, height: 18)
                    .background(Circle().fill(.white.opacity(0.12)))
            }
            .buttonStyle(PressableStyle(scale: 0.9))
            .accessibilityLabel("Close")
            .help("Close (Esc)")
        }
    }

    private var thinkingRow: some View {
        HStack(spacing: 8) {
            Waveform(levels: Array(repeating: 0.35, count: PillModel.barCount), shimmer: true, vertical: false)
            Text(card.thinkingLabel)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Theme.pillWorking)
        }
    }

    private func failureRows(_ failure: AnswerCardState.AnswerFailureContent) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(failure.message)
                .font(.system(size: 13))
                .foregroundStyle(.white.opacity(0.9))
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 8) {
                if let suggestion = failure.suggestion {
                    Button(suggestion, action: onSuggestion).buttonStyle(PillButtonStyle())
                }
                Button("Close", action: onClose).buttonStyle(GhostPillButtonStyle())
            }
        }
    }

    private func answerRows(_ content: AnswerCardState.AnswerContent) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            if !content.text.isEmpty {
                Text(content.text)
                    .font(.system(size: 13))
                    .foregroundStyle(.white.opacity(0.92))
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
            if !content.items.isEmpty {
                VStack(alignment: .leading, spacing: 3) {
                    ForEach(Array(content.items.prefix(8).enumerated()), id: \.offset) { _, item in
                        HStack(alignment: .firstTextBaseline, spacing: 6) {
                            Circle().fill(.white.opacity(0.4)).frame(width: 3, height: 3).offset(y: -2)
                            Text(item).font(.system(size: 12.5)).foregroundStyle(.white.opacity(0.88))
                        }
                    }
                    if content.items.count > 8 {
                        Text("and \(content.items.count - 8) more").font(.system(size: 11)).foregroundStyle(.white.opacity(0.45))
                    }
                }
            }
            HStack(spacing: 5) {
                Circle().fill(Theme.pillWorking).frame(width: 5, height: 5)
                Text(content.sourceLabel)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.white.opacity(0.5))
                    .lineLimit(1)
            }
            .padding(.top, 2)
            .help("Where this answer comes from. Nothing outside your Mac was read.")
        }
    }

    private func buttons(_ content: AnswerCardState.AnswerContent) -> some View {
        HStack(spacing: 6) {
            Button(card.copied ? "Copied" : "Copy", action: onCopy)
                .buttonStyle(PillButtonStyle())
                .help("Copy the answer (the card then closes)")
            // Notes and the Assistant that reads them are private in release builds (`FeatureFlags.meetings`).
            if FeatureFlags.meetings {
                Button("Save as note", action: onSaveNote).buttonStyle(GhostPillButtonStyle())
            }
            if content.sourceLink != nil, FeatureFlags.meetings || !content.sourceIsNote {
                Button(content.isScreenSummary ? "Show window" : "Open source", action: onOpenSource)
                    .buttonStyle(GhostPillButtonStyle())
            }
            if FeatureFlags.meetings {
                Button("Open in Assistant", action: onOpenInAssistant)
                    .buttonStyle(GhostPillButtonStyle())
                    .help("Continue this thread in the Assistant window")
            }
            Spacer(minLength: 0)
        }
        .padding(.top, 4)
    }
}

/// The capsule under the answer card: "✦ Answer · esc close · press control twice to follow up", the
/// purple shimmer while thinking, and the lime rim with live bars while a follow-up is heard.
struct AnswerCardFooter: View {
    let card: AnswerCardState
    let levels: [Double]
    let peaks: [Double]
    /// The key pressed twice for a voice action, named in the follow-up hint.
    var actionKey = ActionTriggerKey.default.keyCap
    let onFollowUp: () -> Void
    let onClose: () -> Void

    var body: some View {
        HStack(spacing: 6) {
            switch card.phase {
            case .thinking:
                Waveform(levels: Array(repeating: 0.3, count: PillModel.barCount), shimmer: true, vertical: false)
                Text("Thinking").foregroundStyle(Theme.pillWorking)
            case .listening:
                Image(systemName: "mic.fill")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(Theme.phosphorFill)
                Waveform(levels: levels, peaks: peaks, vertical: false)
                Text("Follow-up").foregroundStyle(.white.opacity(0.75))
            case .answer, .failure, .files:
                Image(systemName: "sparkle")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(Theme.pillWorking)
                Text("Answer").foregroundStyle(.white.opacity(0.75))
                Text("·").foregroundStyle(.white.opacity(0.45))
                Button(action: onFollowUp) {
                    HStack(spacing: 3) {
                        Text("press").foregroundStyle(.white.opacity(0.45))
                        KeyCap(label: actionKey)
                        Text("twice to follow up").foregroundStyle(.white.opacity(0.45))
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(PressableStyle(scale: 0.94))
                .accessibilityLabel("Ask a follow-up")
                .help("Press the action key twice and speak (or hold fn + control), or click to start listening")
                Text("·").foregroundStyle(.white.opacity(0.45))
                Button(action: onClose) {
                    HStack(spacing: 3) {
                        KeyCap(label: "esc")
                        Text("close").foregroundStyle(.white.opacity(0.45))
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(PressableStyle(scale: 0.94))
                .accessibilityLabel("Close")
            }
        }
        .font(.system(size: 11, weight: .medium))
        .fixedSize()
    }
}

/// "✓ Added: Call Dana · Fri 9:00 · Undo": a Tier-1 action already done. Undo is the one lime
/// thing. While the delete runs the row reads "Undoing…" (neutral); only once the item is really
/// gone does it read "Undone" and cool. If the delete failed it says so and offers Undo again.
struct DoneChipRow: View {
    let chip: DoneChipState
    /// The pill's own chip: the title and Undo, nothing else. The time and place wait behind a
    /// hover (`PillState.hoverDetail`) and in History. Onboarding's practice chip, which is not in
    /// the pill and cannot be hovered, keeps its detail in line.
    var compact = false
    let onUndo: () -> Void

    /// The longest title the compact chip shows in full; a longer one ends in an ellipsis.
    static let compactTitleLimit: CGFloat = 170

    var body: some View {
        HStack(spacing: 6) {
            if chip.undone {
                Image(systemName: "arrow.uturn.backward")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.75))
                Text(ActionWording.undone).foregroundStyle(.white.opacity(0.75))
            } else if chip.isUndoing {
                ProgressView().controlSize(.mini)
                if compact {
                    Text(ActionWording.undoing).foregroundStyle(.white.opacity(0.75)).lineLimit(1)
                } else {
                    Text(chip.title).foregroundStyle(.white.opacity(0.55)).lineLimit(1)
                    Text("\u{00B7} \(ActionWording.undoing)").foregroundStyle(.white.opacity(0.75)).lineLimit(1)
                }
            } else if let failure = chip.undoFailure {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(Theme.warning)
                Text(failure).foregroundStyle(.white.opacity(0.85)).lineLimit(1)
                if chip.canUndo {
                    Button("Try again", action: onUndo)
                        .buttonStyle(PillButtonStyle())
                        .padding(.leading, 2)
                        .help("Try to take it back again")
                }
            } else {
                if chip.isPractice {
                    Image(systemName: "circle.dashed")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.75))
                } else {
                    CheckmarkDraw()
                }
                Text(chip.title).foregroundStyle(.white.opacity(0.85)).lineLimit(1)
                    .truncationMode(.tail)
                    .frame(maxWidth: compact ? Self.compactTitleLimit : nil)
                if !compact, let detail = chip.detail, !detail.isEmpty {
                    Text("· \(detail)").foregroundStyle(.white.opacity(0.45)).lineLimit(1)
                }
                if chip.canUndo {
                    Button("Undo", action: onUndo)
                        .buttonStyle(PillButtonStyle())
                        .padding(.leading, 2)
                        .help("Take it back: the reminder or event is deleted")
                }
            }
        }
        .font(.system(size: 11, weight: .medium))
        .fixedSize()
        .accessibilityElement(children: .contain)
        .accessibilityLabel(chip.accessibilityText)
    }
}
