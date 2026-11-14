import MurmurCore
import SwiftUI

/// One chat turn. The user's words sit right in a quiet lime wash; the agent's reply sits left
/// on a raised card, rendered as Markdown, with a live activity line while it works.
struct ChatMessageRow: View {
    let message: AssistantModel.Message
    let agentTitle: String

    var body: some View {
        switch message.role {
        case .user:
            HStack {
                Spacer(minLength: 40)
                Text(message.text)
                    .font(.system(size: 13.5))
                    .foregroundStyle(Theme.textPrimary)
                    .textSelection(.enabled)
                    .padding(.horizontal, Theme.Space.m)
                    .padding(.vertical, Theme.Space.s)
                    .background(
                        UnevenRoundedRectangle(
                            topLeadingRadius: 12, bottomLeadingRadius: 12, bottomTrailingRadius: 4, topTrailingRadius: 12)
                            .fill(Theme.phosphorTint))
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel("You: \(message.text)")
        case .assistant:
            AssistantReplyView(message: message, agentTitle: agentTitle)
        case .notice:
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Image(systemName: "arrow.triangle.2.circlepath")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(Theme.textTertiary)
                Text(message.text)
                    .font(Theme.Font.caption)
                    .foregroundStyle(Theme.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, Theme.Space.s)
            .accessibilityElement(children: .combine)
        }
    }
}

private struct AssistantReplyView: View {
    let message: AssistantModel.Message
    let agentTitle: String

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            if !message.text.isEmpty {
                ChatMarkdownView(text: message.text)
            }
            if !message.actions.isEmpty {
                ChatActionCard(message: message)
            }
            if let activity = message.activity {
                ActivityLine(text: activity)
            } else if let summary = message.toolSummary, message.errorText == nil {
                Text(summary)
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.textTertiary)
                    .accessibilityLabel("Used: \(summary)")
            }
            if message.dataUnavailable {
                Notice(symbol: "exclamationmark.triangle", tint: Theme.warning,
                       text: "\(agentTitle) couldn't reach Hushy's data this time, so this answer isn't based on your history.")
            }
            if let errorText = message.errorText {
                Notice(symbol: "exclamationmark.circle", tint: Theme.error, text: errorText)
            }
        }
        .padding(.horizontal, Theme.Space.m)
        .padding(.vertical, Theme.Space.s + 2)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            UnevenRoundedRectangle(topLeadingRadius: 4, bottomLeadingRadius: 12, bottomTrailingRadius: 12, topTrailingRadius: 12)
                .fill(Theme.bgRaised))
        .overlay(
            UnevenRoundedRectangle(topLeadingRadius: 4, bottomLeadingRadius: 12, bottomTrailingRadius: 12, topTrailingRadius: 12)
                .strokeBorder(Theme.hairline, lineWidth: 0.5))
        .padding(.trailing, Theme.Space.l)
        .accessibilityElement(children: .combine)
    }
}

/// "Searching your history…" / "Thinking…" with a softly pulsing purple dot (still under Reduce
/// Motion): this is the model working, not the user, so it takes `Theme.working`
/// (docs/product/UI-ROUND-2026-09-28.md §3, C2), not the lime `phosphor`.
private struct ActivityLine: View {
    let text: String
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var pulsing = false

    var body: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(Theme.working)
                .frame(width: 6, height: 6)
                .opacity(pulsing ? 0.35 : 1)
            Text(text)
                .font(Theme.Font.caption)
                .foregroundStyle(Theme.textSecondary)
                .contentTransition(.opacity)
        }
        .onAppear {
            guard !reduceMotion else { return }
            withAnimation(.easeInOut(duration: 0.8).repeatForever(autoreverses: true)) { pulsing = true }
        }
        .accessibilityLabel(text)
    }
}

private struct Notice: View {
    let symbol: String
    let tint: Color
    let text: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Image(systemName: symbol).font(.system(size: 11, weight: .semibold)).foregroundStyle(tint)
            Text(text)
                .font(Theme.Font.caption)
                .foregroundStyle(Theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
        }
    }
}

/// Renders an assistant reply's Markdown: `ChatMarkdown` splits the blocks, and each block's
/// inline Markdown (bold, italics, `code`, links) goes through `AttributedString`.
struct ChatMarkdownView: View {
    let text: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(Array(ChatMarkdown.blocks(from: text).enumerated()), id: \.offset) { _, block in
                blockView(block)
            }
        }
        .textSelection(.enabled)
    }

    @ViewBuilder
    private func blockView(_ block: ChatMarkdown.Block) -> some View {
        switch block {
        case .paragraph(let text):
            Text(Self.inline(text))
                .font(.system(size: 13.5))
                .foregroundStyle(Theme.textPrimary)
                .lineSpacing(2)
                .fixedSize(horizontal: false, vertical: true)
        case .heading(let text):
            Text(Self.inline(text))
                .font(.system(size: 13.5, weight: .semibold))
                .foregroundStyle(Theme.textPrimary)
                .padding(.top, 2)
        case .listItem(let marker, let text, let depth):
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(marker)
                    .font(.system(size: 13.5, weight: .medium).monospacedDigit())
                    .foregroundStyle(Theme.phosphor)
                Text(Self.inline(text))
                    .font(.system(size: 13.5))
                    .foregroundStyle(Theme.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.leading, CGFloat(depth) * 14)
        case .code(let code):
            Text(code)
                .font(Theme.Font.mono)
                .foregroundStyle(Theme.textPrimary)
                .padding(Theme.Space.s)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: Theme.Radius.control).fill(Theme.bgSunken))
        }
    }

    /// Inline Markdown, falling back to the literal text if it doesn't parse.
    static func inline(_ text: String) -> AttributedString {
        (try? AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
            ?? AttributedString(text)
    }
}
