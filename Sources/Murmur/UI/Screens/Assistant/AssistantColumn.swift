import MurmurCore
import SwiftUI

/// Home's right-hand column: a header (title, agent picker, history, new chat, collapse), a
/// compact "Open action items" section that folds to its header, and the chat filling the
/// rest. The chat is opt-in: while it's off the column shows only the action items and a small
/// "Turn on…" card, and no agent CLI is even probed.
struct AssistantColumn: View {
    @Environment(AppModel.self) private var model
    @Environment(\.isSnapshot) private var isSnapshot
    @Environment(\.snapshotAppLocked) private var snapshotAppLocked

    /// The app lock is on. The pane sits beside every section, outside `LockGate`, and both its
    /// halves hold note text (action items; answers and saved chats about notes), so it shows
    /// one line and Unlock instead.
    private var isLocked: Bool { snapshotAppLocked || model.appLock.isLocked }

    var body: some View {
        let assistant = model.assistant
        VStack(spacing: 0) {
            AssistantHeader(isLocked: isLocked)
            if isLocked {
                LockedContentNotice(message: LockedCopy.assistant)
                Spacer(minLength: 0)
            } else {
                unlockedContent(assistant)
            }
        }
        .frame(maxHeight: .infinity, alignment: .top)
        .background(Theme.bgBase)
        .onAppear { refreshIfLive() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            refreshIfLive()
        }
        .onChange(of: assistant.isEnabled) { _, _ in refreshIfLive() }
        .sheet(isPresented: Binding(
            get: { assistant.consentHost == .home }, set: { if !$0 { assistant.declineConsent() } })
        ) {
            AssistantConsentSheet(onAccept: { assistant.acceptConsent() }, onCancel: { assistant.declineConsent() })
        }
    }

    @ViewBuilder
    private func unlockedContent(_ assistant: AssistantModel) -> some View {
        ActionItemsSection()
        if assistant.isEnabled {
            AssistantChatView()
                .frame(maxHeight: .infinity)
        } else {
            AssistantOffCard()
                .padding(Theme.Space.l)
            Spacer(minLength: 0)
        }
    }

    /// Status checks run only while the Assistant is on (it's a local, offline CLI call).
    private func refreshIfLive() {
        guard !isSnapshot, model.assistant.isEnabled else { return }
        model.assistant.refreshAvailability()
    }
}

private struct AssistantHeader: View {
    @Environment(AppModel.self) private var model
    /// Locked: no saved chats and no new chat; the title and the hide button stay.
    var isLocked = false

    var body: some View {
        let assistant = model.assistant
        HStack(spacing: Theme.Space.s) {
            Image(systemName: "sparkles")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Theme.phosphor)
            Text("Assistant")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(Theme.textPrimary)
            if assistant.isEnabled, !assistant.installedAgents.isEmpty {
                AgentPicker()
            }
            Spacer(minLength: 0)
            if assistant.isEnabled, !isLocked {
                HistoryButton()
                IconButton(symbol: "square.and.pencil", help: "New chat") {
                    withAnimation(Theme.fade) { assistant.newConversation() }
                }
                .disabled(assistant.messages.isEmpty)
            }
            IconButton(symbol: "sidebar.right", help: "Hide Assistant (⌥⌘0)") {
                model.settings.assistantCollapsed = true
            }
        }
        .padding(.leading, Theme.Space.l)
        .padding(.trailing, Theme.Space.s)
        .frame(height: 52)
        // Clears the hidden title bar's drag area without fighting the traffic lights (those sit
        // over the left sidebar, not here).
        .padding(.top, Theme.Space.s)
    }
}

/// The header's clock button: the saved-chats popover (search, grouped by day, open/rename/
/// delete), like VS Code's chat history.
private struct HistoryButton: View {
    @Environment(AppModel.self) private var model
    @State private var showing = false

    var body: some View {
        IconButton(symbol: "clock.arrow.circlepath", help: "Chat history") {
            model.assistant.historyQuery = ""
            showing.toggle()
        }
        .popover(isPresented: $showing, arrowEdge: .bottom) {
            ChatHistoryView(onOpen: { showing = false })
                .environment(model)
        }
    }
}

/// "Claude Code ▾" — lists every agent CLI on this Mac; signed-out ones offer "Sign in" and
/// unsupported ones say "Coming soon". With a single agent it's a plain label, not a menu.
private struct AgentPicker: View {
    @Environment(AppModel.self) private var model
    @Environment(\.isSnapshot) private var isSnapshot

    var body: some View {
        let assistant = model.assistant
        if isSnapshot {
            // `ImageRenderer` can't draw `Menu`; show its resting label instead.
            chip(assistant.agent.title, showsChevron: assistant.showsAgentPicker)
        } else if assistant.showsAgentPicker {
            Menu {
                ForEach(assistant.installedAgents) { agent in
                    // Unsupported agents (chat not built yet, e.g. Codex) never offer Sign in —
                    // same rule as Settings › Advanced (see AssistantSettingsSection): a working sign-in flow that leads to a feature
                    // that doesn't exist yet is worse than no button. Checked before `signedOut`
                    // so an unsupported-and-signed-out agent still reads "Coming soon", not
                    // "Sign in".
                    let signedOut = agent.isSupported && assistant.accounts.state(of: agent) == .signedOut
                    Button {
                        if signedOut {
                            assistant.accounts.startSignIn(agent)
                        } else if agent.isSupported {
                            assistant.agent = agent
                        }
                    } label: {
                        if !agent.isSupported {
                            Text("\(agent.title) · Coming soon")
                        } else if signedOut {
                            Text("\(agent.title) · Sign in")
                        } else if agent == assistant.agent {
                            Label(agent.title, systemImage: "checkmark")
                        } else {
                            Text(agent.title)
                        }
                    }
                    .disabled(!signedOut && (!agent.isSupported || assistant.isRunning))
                }
                Divider()
                Text("Model: \(model.settings.assistantModel.title) (change in Settings)")
            } label: {
                chip(assistant.agent.title, showsChevron: true)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
        } else {
            chip(assistant.agent.title, showsChevron: false)
        }
    }

    private func chip(_ title: String, showsChevron: Bool) -> some View {
        HStack(spacing: 3) {
            Text(title).font(.system(size: 11, weight: .medium))
            if showsChevron {
                Image(systemName: "chevron.down").font(.system(size: 8, weight: .bold))
            }
        }
        .foregroundStyle(Theme.textSecondary)
        .padding(.horizontal, 7)
        .padding(.vertical, 3)
        .background(Capsule().fill(Theme.bgSunken))
    }
}

/// Open action items, compact: a header with the count that folds the list away, and the
/// existing toggle rows. Hidden entirely when there's nothing open — no empty sections.
private struct ActionItemsSection: View {
    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let items = OpenActionItems.current(
            in: model.library, mine: OpenActionItems.myNames(userName: model.settings.userName))
        if !items.isEmpty {
            let collapsed = model.settings.assistantActionItemsCollapsed
            VStack(alignment: .leading, spacing: Theme.Space.s) {
                Button {
                    withAnimation(Theme.spatial(reduceMotion: reduceMotion)) {
                        model.settings.assistantActionItemsCollapsed.toggle()
                    }
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "chevron.right")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundStyle(Theme.textTertiary)
                            .rotationEffect(.degrees(collapsed ? 0 : 90))
                        Eyebrow("Open action items")
                        Text("\(items.count)")
                            .font(.system(size: 11, weight: .semibold).monospacedDigit())
                            .foregroundStyle(Theme.textSecondary)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 1)
                            .background(Capsule().fill(Theme.bgSunken))
                        Spacer(minLength: 0)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Open action items, \(items.count)")
                .accessibilityValue(collapsed ? "Collapsed" : "Expanded")

                if !collapsed {
                    VStack(alignment: .leading, spacing: Theme.Space.s + 2) {
                        ForEach(items) { item in
                            ActionItemToggleRow(
                                text: item.text, secondary: item.secondary, noteTitle: item.note.title,
                                isDone: model.library.isActionItemDone(item.note, itemIndex: item.itemIndex),
                                toggle: { model.library.toggleActionItemDone(item.note, itemIndex: item.itemIndex) })
                        }
                    }
                    .padding(Theme.Space.m)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(RoundedRectangle(cornerRadius: Theme.Radius.card).fill(Theme.bgRaised))
                    .overlay(RoundedRectangle(cornerRadius: Theme.Radius.card).strokeBorder(Theme.hairline, lineWidth: 0.5))
                    .transition(.opacity)
                }
            }
            .padding(.horizontal, Theme.Space.l)
            .padding(.bottom, Theme.Space.m)
            .overlay(alignment: .bottom) { Rectangle().fill(Theme.hairline).frame(height: 0.5) }
        }
    }
}
