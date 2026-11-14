import MurmurCore
import SwiftUI

/// The chat half of Home's Assistant column: messages (or suggested prompts when empty), the
/// input, and — always visible, directly under the input — where the words go when you send.
/// When Claude Code isn't installed or isn't signed in it's a single setup card instead; never
/// an empty pane.
struct AssistantChatView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.isSnapshot) private var isSnapshot

    private var assistant: AssistantModel { model.assistant }

    var body: some View {
        if assistant.isConnected {
            VStack(spacing: 0) {
                conversation
                composer
            }
        } else {
            ScrollingIfLive {
                AgentSetupCard()
                    .padding(Theme.Space.l)
            }
        }
    }

    @ViewBuilder
    private var conversation: some View {
        if assistant.messages.isEmpty {
            ScrollingIfLive {
                SuggestedPrompts { prompt in assistant.send(prompt) }
                    .padding(Theme.Space.l)
            }
            .frame(maxHeight: .infinity, alignment: .bottom)
        } else if isSnapshot {
            messageList.frame(maxHeight: .infinity, alignment: .bottom)
        } else {
            ScrollViewReader { proxy in
                ScrollView {
                    messageList
                }
                .scrollContentBackground(.hidden)
                .defaultScrollAnchor(.bottom)
                .onChange(of: assistant.messages.last?.text) { _, _ in
                    proxy.scrollTo(Self.bottomID, anchor: .bottom)
                }
                .onChange(of: assistant.messages.count) { _, _ in
                    withAnimation(Theme.fade) { proxy.scrollTo(Self.bottomID, anchor: .bottom) }
                }
            }
        }
    }

    private static let bottomID = "assistant-bottom"

    private var messageList: some View {
        LazyVStack(alignment: .leading, spacing: Theme.Space.m) {
            ForEach(assistant.messages) { message in
                ChatMessageRow(message: message, agentTitle: assistant.agent.title)
                    .transition(.opacity)
            }
            Color.clear.frame(height: 1).id(Self.bottomID)
        }
        .padding(.horizontal, Theme.Space.l)
        .padding(.vertical, Theme.Space.m)
    }

    private var composer: some View {
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            ChatComposer()
            PrivacyLine(agent: assistant.agent)
        }
        .padding(.horizontal, Theme.Space.l)
        .padding(.top, Theme.Space.s)
        .padding(.bottom, Theme.Space.m)
        .background(Theme.bgBase)
        .overlay(alignment: .top) { Rectangle().fill(Theme.hairline).frame(height: 0.5) }
    }
}

/// The input row: the growing text field, and Send — or Stop while a request is running.
private struct ChatComposer: View {
    @Environment(AppModel.self) private var model
    @Environment(\.isSnapshot) private var isSnapshot
    @State private var inputHeight = ChatInputField.minHeight

    var body: some View {
        @Bindable var assistant = model.assistant
        HStack(alignment: .bottom, spacing: Theme.Space.s) {
            Group {
                if isSnapshot {
                    SnapshotTextField(assistant.draft, placeholder: placeholder)
                } else {
                    ChatInputField(
                        text: $assistant.draft, placeholder: placeholder, isEnabled: true,
                        onSubmit: { assistant.sendDraft() }, height: $inputHeight)
                        .frame(height: inputHeight)
                }
            }
            .padding(.vertical, 2)
            if assistant.isRunning {
                RoundAction(symbol: "stop.fill", help: "Stop", isProminent: false) { assistant.cancel() }
            } else {
                RoundAction(symbol: "arrow.up", help: "Send (Return)", isProminent: assistant.canSend) { assistant.sendDraft() }
                    .disabled(!assistant.canSend)
            }
        }
        .padding(.leading, Theme.Space.m)
        .padding(.trailing, 6)
        .padding(.vertical, 6)
        .background(RoundedRectangle(cornerRadius: 12).fill(Theme.bgRaised))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Theme.hairline, lineWidth: 0.5))
    }

    private var placeholder: String { "Ask about your meetings…" }
}

private struct RoundAction: View {
    let symbol: String
    let help: String
    let isProminent: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(isProminent ? Theme.onPhosphor : Theme.textSecondary)
                .frame(width: 26, height: 26)
                .background(Circle().fill(isProminent ? Theme.phosphorFill : (hovering ? Theme.selection : Theme.bgSunken)))
        }
        .buttonStyle(.plain)
        .help(help)
        .accessibilityLabel(help)
        .onHover { hovering = $0 }
        .animation(Theme.fade, value: isProminent)
    }
}

/// The honest line: this is the one place Hushy's data leaves the Mac, so it says so in plain
/// words every time, right where the user hits Send.
struct PrivacyLine: View {
    let agent: AgentKind

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 5) {
            Image(systemName: "arrow.up.right.circle")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(Theme.textTertiary)
            Text("Your question, and whatever \(agent.title) looks up in Hushy, go to \(agent.provider) through your \(agent.title) account. Nothing else leaves this Mac.")
                .font(.system(size: 11))
                .foregroundStyle(Theme.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .combine)
    }
}

private struct SuggestedPrompts: View {
    let send: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            Text("Ask about your meetings")
                .font(.system(size: 17, design: .serif))
                .foregroundStyle(Theme.textPrimary)
            // The plain, explicit line product direction asked for, stated rather than implied
            // by omission — dictations are never shared with the Assistant.
            Text("Your agent searches your notes and meetings through Hushy, then answers here. Dictations are never shared with the Assistant.")
                .font(Theme.Font.caption)
                .foregroundStyle(Theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.bottom, Theme.Space.xs)
            ForEach(AssistantModel.suggestions, id: \.self) { prompt in
                SuggestionChip(text: prompt) { send(prompt) }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct SuggestionChip: View {
    let text: String
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: Theme.Space.s) {
                Image(systemName: "sparkle")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(Theme.phosphor)
                Text(text)
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.textPrimary)
                Spacer(minLength: 0)
                Image(systemName: "arrow.up.right")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(Theme.textTertiary)
                    .opacity(hovering ? 1 : 0)
            }
            .padding(.horizontal, Theme.Space.m)
            .padding(.vertical, Theme.Space.s + 1)
            .background(RoundedRectangle(cornerRadius: Theme.Radius.card).fill(hovering ? Theme.selection : Theme.bgRaised))
            .overlay(RoundedRectangle(cornerRadius: Theme.Radius.card).strokeBorder(Theme.hairline, lineWidth: 0.5))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(Theme.fade, value: hovering)
    }
}

/// A real `ScrollView` when live; flat under `ImageRenderer`, which can't draw scroll contents.
struct ScrollingIfLive<Content: View>: View {
    @Environment(\.isSnapshot) private var isSnapshot
    @ViewBuilder var content: Content

    var body: some View {
        if isSnapshot {
            content
        } else {
            ScrollView { content }.scrollContentBackground(.hidden)
        }
    }
}
