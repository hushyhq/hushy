import AppKit
import MurmurCore
import SwiftUI

/// The sentences of Advanced → "Let your AI apps read Hushy" and of the Assistant's rows, kept
/// together so a test can hold them to the code. Two different things carry the name "Claude
/// Code" and each row says which it is: the Assistant's sign-in (chat
/// inside Hushy, launched with `--scope notes`: notes and meetings only) and the connector (the
/// AI app reading Hushy by itself through `MCPServer`, scope `.all`: notes, dictation history
/// and usage totals, read-only).
enum AIConnectionsCopy {
    /// The Assistant's agent row: whose sign-in it is, then its state.
    static func assistantAccountDetail(agentTitle: String, state: AgentAccountState) -> String {
        let what = "The Assistant asks through this account."
        switch state {
        case .notInstalled: return "\(what) \(agentTitle) is not installed."
        case .signedOut: return "\(what) Not signed in; signing in opens \(agentTitle)'s own flow."
        case .ready: return "\(what) Signed in."
        case .unknown: return "\(what) Hushy could not check the sign-in; your first question will tell."
        }
    }

    static let connectorsTitle = "Let your AI apps read Hushy"
    /// `MCPServer.tools` at scope `.all`, which is what every connected client gets.
    static var connectorScopeDetail: String { scopeDetail(meetings: FeatureFlags.meetings) }

    static func scopeDetail(meetings: Bool) -> String {
        let what = meetings
            ? "Your notes and meetings, your dictation history and your usage totals"
            : "Your dictation history and your usage totals"
        return "\(what), when you ask that app about them. It reads from this Mac and cannot change anything."
    }

    /// A connector row: what connecting does for this app, then its state. Claude Code appears
    /// twice in the pane, so its row says it is not the Assistant's sign-in.
    static func connectorDetail(clientTitle: String, isAlsoAssistantAgent: Bool, status: MCPInstaller.ConnectionStatus) -> String {
        let what = isAlsoAssistantAgent
            ? "Separate from the Assistant: lets \(clientTitle) read Hushy when you use it on its own."
            : "Lets \(clientTitle) read Hushy when you ask it to."
        switch status {
        case .notInstalled: return "\(what) \(clientTitle) is not installed."
        case .notConnected: return "\(what) Not connected."
        case .connected: return "\(what) Connected."
        }
    }
}

/// Claude Desktop, Claude Code and Cursor: one row each with a status dot and a Connect button,
/// using the same `MCPInstaller` the full "Ask your AI" page (`AIConnectView`) uses. Codex has no
/// row: it cannot be connected yet, and a row that only says "coming soon" is noise. Lives in
/// Settings → Advanced.
struct AIAppsSettingsSection: View {
    /// The Assistant's own Claude Code sign-in is on screen too, so the Claude Code row says it is
    /// a different thing.
    let showsAssistant: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            SettingsGroup(title: AIConnectionsCopy.connectorsTitle) {
                ForEach(MCPInstaller.Client.allCases.filter { $0 != .codex }) { client in
                    AIConnectionRow(client: client, isAlsoAssistantAgent: client == .claudeCode && showsAssistant)
                }
            }
            Text(AIConnectionsCopy.connectorScopeDetail)
                .font(Theme.Font.caption).foregroundStyle(Theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, Theme.Space.l)
        }
    }
}

/// One client's compact row: status dot + Connect/Update button. Re-reads status on appear and
/// after every action, same as the full page's `ConnectionRow`, so this never shows a stale
/// "Connected" after an install elsewhere.
private struct AIConnectionRow: View {
    let client: MCPInstaller.Client
    let isAlsoAssistantAgent: Bool
    @State private var status: MCPInstaller.ConnectionStatus = .notInstalled
    @State private var hasLegacyEntry = false
    @State private var confirmInstall = false
    @State private var errorMessage: String?

    var body: some View {
        SettingsRow(title: client.title, detail: detail) {
            HStack(spacing: Theme.Space.s) {
                statusDot
                actionButton
            }
        }
        .onAppear { refresh() }
        .confirmationDialog(hasLegacyEntry ? "Update \(client.title) from murmur to hushy?" : "Add Hushy to \(client.title)?", isPresented: $confirmInstall) {
            Button(hasLegacyEntry ? "Update" : "Connect") { install() }
        } message: {
            Text(confirmMessage)
        }
    }

    private var detail: String {
        if let errorMessage { return errorMessage }
        return AIConnectionsCopy.connectorDetail(
            clientTitle: client.title, isAlsoAssistantAgent: isAlsoAssistantAgent, status: status)
    }

    private var confirmMessage: String {
        guard let url = client.configURL else {
            return "Copies the command to your clipboard. Run it once in Terminal, then restart \(client.title)."
        }
        return hasLegacyEntry
            ? "Hushy will rename the existing “murmur” entry in \(url.path) to “hushy” and keep a backup of the previous file. Restart \(client.title) afterwards."
            : "Hushy will add a “hushy” entry to \(url.path) and keep a backup of the previous file. Restart \(client.title) afterwards."
    }

    private var statusDot: some View {
        Circle().fill(statusColor).frame(width: 6, height: 6)
    }

    private var statusColor: Color {
        switch status {
        case .notInstalled: Theme.textTertiary
        case .notConnected: Theme.warning
        case .connected: Theme.success
        }
    }

    @ViewBuilder
    private var actionButton: some View {
        switch status {
        case .notInstalled:
            Text("Not installed").font(Theme.Font.caption).foregroundStyle(Theme.textTertiary)
        case .notConnected:
            Button(hasLegacyEntry ? "Update" : "Connect") { confirmInstall = true }
                .buttonStyle(SecondaryButtonStyle())
                .disabled(!MCPInstaller.serverExists)
        case .connected:
            Label("Connected", systemImage: "checkmark.circle.fill")
                .font(Theme.Font.caption).foregroundStyle(Theme.success)
        }
    }

    private func refresh() {
        status = MCPInstaller.status(for: client)
        hasLegacyEntry = MCPInstaller.hasLegacyEntry(client)
    }

    private func install() {
        guard client.configURL != nil else {
            // Claude Code: no config file to edit — copy the command for the user to run.
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(MCPInstaller.snippet(for: client), forType: .string)
            MCPInstaller.markClaudeCodeConnected()
            refresh()
            return
        }
        do {
            try MCPInstaller.install(client)
            refresh()
            if status != .connected {
                errorMessage = "Wrote the config, but couldn't verify it on re-read."
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
