import MurmurCore
import SwiftUI

/// Settings → Advanced → Assistant chat (shown only when it is already on or the notes and meetings preview is): the opt-in switch (off by default, consent sheet the
/// first time), the Claude model (Haiku fastest, Sonnet smarter), and each agent CLI's state
/// with the same Install / Sign in buttons as the Assistant column.
struct AssistantSettingsSection: View {
    @Environment(AppModel.self) private var model
    @Environment(\.isSnapshot) private var isSnapshot

    /// Under the switch. It agrees with the title (`AssistantConsent.title`) and with what the
    /// Assistant can read: notes and meetings only.
    static let chatDetail =
        "Ask Claude Code about your notes and meetings from Home. Sign in to Claude Code first. Codex chat is coming soon. Dictations are never shared. Off until you turn it on."

    var body: some View {
        let assistant = model.assistant
        VStack(alignment: .leading, spacing: Theme.Space.xl) {
            SettingsGroup(title: "Assistant chat") {
                SettingsRow(
                    title: AssistantConsent.title,
                    detail: Self.chatDetail
                ) {
                    SwitchToggle(isOn: Binding(
                        get: { assistant.isEnabled },
                        set: { $0 ? assistant.requestEnable(from: .settings) : assistant.disable() }))
                }
                SettingsRow(title: "Claude model", detail: "Haiku answers fastest; Sonnet thinks harder about longer questions.") {
                    Picker("", selection: Binding(
                        get: { model.settings.assistantModel }, set: { model.settings.assistantModel = $0 })
                    ) {
                        ForEach(AssistantModelChoice.allCases) { choice in
                            Text("\(choice.title) · \(choice.detail.lowercased())").tag(choice)
                        }
                    }
                    .labelsHidden().frame(width: 170)
                }
                ForEach(AgentKind.allCases) { agent in
                    AgentAccountRow(agent: agent)
                }
            }
        }
        .onAppear { if !isSnapshot { assistant.refreshAvailability() } }
        .sheet(isPresented: Binding(
            get: { assistant.consentHost == .settings }, set: { if !$0 { assistant.declineConsent() } })
        ) {
            AssistantConsentSheet(onAccept: { assistant.acceptConsent() }, onCancel: { assistant.declineConsent() })
        }
    }
}

/// One agent CLI: its state (Not installed / Not signed in / Ready) and the matching buttons.
private struct AgentAccountRow: View {
    let agent: AgentKind
    @Environment(AppModel.self) private var model

    var body: some View {
        let state = model.assistant.accounts.state(of: agent)
        SettingsRow(title: agent.title, detail: detail(state)) {
            HStack(spacing: Theme.Space.s) {
                if agent.isSupported {
                    Circle().fill(color(state)).frame(width: 6, height: 6)
                }
                if !agent.isSupported {
                    // Chat isn't built for this agent yet — no Install/Sign-in button that
                    // would lead to a flow with nothing behind it (audit item "Codex in
                    // Settings › AI connections"). A quiet status label instead.
                    Text("Coming soon").font(Theme.Font.caption).foregroundStyle(Theme.textTertiary)
                } else if state == .ready || state == .unknown {
                    Text(state == .ready ? "Ready" : "Unknown").font(Theme.Font.caption).foregroundStyle(Theme.textSecondary)
                } else {
                    AgentAccountControls(agent: agent, compact: true)
                }
            }
        }
    }

    private func detail(_ state: AgentAccountState) -> String {
        guard agent.isSupported else { return "Chat coming soon." }
        return AIConnectionsCopy.assistantAccountDetail(agentTitle: agent.title, state: state)
    }

    private func color(_ state: AgentAccountState) -> Color {
        switch state {
        case .notInstalled: Theme.textTertiary
        case .signedOut, .unknown: Theme.warning
        case .ready: Theme.success
        }
    }
}
