import MurmurCore
import SwiftUI

/// Lets people ask questions about their notes using the AI they already pay for,
/// through Hushy's local, read-only MCP server. Shows each supported client as a
/// Connections row (detect → connect → restart hint → verify), with raw config tucked
/// under Advanced rather than shown by default.
struct AIConnectView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.isSnapshot) private var isSnapshot

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.xl) {
            PageBanner(
                title: "Connect",
                emphasis: "your own AI apps",
                subtitle: "Let Claude, Codex or Cursor — on the subscription you already have — answer questions about your \(FeatureFlags.meetings ? "notes and dictation history" : "dictation history"). Read-only: an excerpt leaves this Mac only when you ask that app a question.",
                palette: .blue)

            explainer

            VStack(alignment: .leading, spacing: Theme.Space.s) {
                Eyebrow("Connections")
                Card(padding: 0) {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(MCPInstaller.Client.allCases) { client in
                            ConnectionRow(client: client, isSnapshot: isSnapshot)
                            if client != MCPInstaller.Client.allCases.last {
                                Rectangle().fill(Theme.hairline).frame(height: 0.5)
                            }
                        }
                    }
                }
                if !MCPInstaller.serverExists {
                    Text("The MCP helper is missing from this build. Run scripts/build-app.sh.")
                        .font(Theme.Font.caption).foregroundStyle(Theme.warning)
                }
            }

            examples

            Card {
                HStack(spacing: Theme.Space.m) {
                    Image(systemName: "folder").foregroundStyle(Theme.textSecondary)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Or just point any tool at your Markdown folder").font(Theme.Font.emphasis)
                        Text(model.settings.exportDirectory.path).font(Theme.Font.mono).foregroundStyle(Theme.textSecondary)
                    }
                    Spacer()
                    Button("Open folder") {
                        try? FileManager.default.createDirectory(at: model.settings.exportDirectory, withIntermediateDirectories: true)
                        NSWorkspace.shared.open(model.settings.exportDirectory)
                    }
                    .buttonStyle(SecondaryButtonStyle())
                }
            }
        }
        .screen()
    }

    private var explainer: some View {
        HStack(alignment: .top, spacing: Theme.Space.l) {
            Step(number: "1", title: "Stays local", text: "Hushy runs a tiny read-only server on this Mac. No port is opened; your AI app launches it directly.")
            Step(number: "2", title: "You stay in control", text: "Your AI only sees the excerpts it asks for, when you ask. It can never change or delete anything.")
            Step(number: "3", title: "Goes to your AI's provider", text: "Once your AI client has an excerpt, it may send that text to its own provider (Anthropic, OpenAI, …) to answer you — the same as any other question you ask it.")
        }
    }

    /// Questions to try. The ones about notes and meetings go with them (`FeatureFlags.meetings`).
    static var examplePrompts: [String] { prompts(meetings: FeatureFlags.meetings) }

    static func prompts(meetings: Bool) -> [String] {
        guard meetings else {
            return ["What have I dictated about the launch?", "What did I say about pricing last week?"]
        }
        return [
            "What did we decide about pricing last week?",
            "List every action item assigned to me this month",
            "Summarize my notes from Tuesday",
            "Draft a follow-up email from today's meeting",
            "What have I dictated about the launch?",
        ]
    }

    private var examples: some View {
        VStack(alignment: .leading, spacing: Theme.Space.m) {
            Eyebrow("Try asking")
            FlowLayout(spacing: Theme.Space.s) {
                ForEach(Self.examplePrompts, id: \.self) { prompt in
                    Text("“\(prompt)”")
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.textSecondary)
                        .padding(.horizontal, Theme.Space.m)
                        .padding(.vertical, 6)
                        .background(Capsule().fill(Theme.bgRaised))
                        .overlay(Capsule().strokeBorder(Theme.hairline, lineWidth: 0.5))
                }
            }
        }
    }
}

/// One client: status, a single Connect action, a post-connect restart hint, and the raw
/// config collapsed under Advanced.
private struct ConnectionRow: View {
    let client: MCPInstaller.Client
    let isSnapshot: Bool

    @State private var status: MCPInstaller.ConnectionStatus = .notInstalled
    @State private var confirmInstall = false
    @State private var showAdvanced = false
    @State private var message: (text: String, isError: Bool)?
    @State private var justConnected = false
    @State private var hasLegacyEntry = false

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.m) {
            HStack(spacing: Theme.Space.m) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(client.title).font(Theme.Font.emphasis)
                    Text(instructions).font(Theme.Font.caption).foregroundStyle(Theme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: Theme.Space.l)
                StatusBadge(status: status)
                actionButton
            }

            if hasLegacyEntry, !justConnected {
                Label("Still connected as “murmur” from before the rename — update to “hushy”.", systemImage: "arrow.triangle.2.circlepath")
                    .font(Theme.Font.caption).foregroundStyle(Theme.warning)
            }
            if justConnected {
                Label("Restart \(client.title) to pick up the change.", systemImage: "arrow.clockwise")
                    .font(Theme.Font.caption).foregroundStyle(Theme.warning)
            }
            if let message {
                Label(message.text, systemImage: message.isError ? "exclamationmark.triangle" : "checkmark.circle")
                    .font(Theme.Font.caption)
                    .foregroundStyle(message.isError ? Theme.error : Theme.success)
            }

            DisclosureGroup("Advanced: raw config", isExpanded: $showAdvanced) {
                if isSnapshot {
                    Text(MCPInstaller.snippet(for: client))
                        .font(Theme.Font.mono).foregroundStyle(Theme.textPrimary)
                        .padding(.top, Theme.Space.s)
                        .frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    CodeBlock(code: MCPInstaller.snippet(for: client))
                        .padding(.top, Theme.Space.s)
                }
                if let url = client.configURL {
                    Text(url.path).font(Theme.Font.caption).foregroundStyle(Theme.textTertiary)
                }
            }
            .font(Theme.Font.caption)
            .tint(Theme.textSecondary)
        }
        .padding(Theme.Space.l)
        .onAppear { refresh() }
        .confirmationDialog(hasLegacyEntry ? "Update \(client.title) from murmur to hushy?" : "Add Hushy to \(client.title)?", isPresented: $confirmInstall) {
            Button(hasLegacyEntry ? "Update" : "Add") { install() }
        } message: {
            Text(confirmMessage)
        }
    }

    private var lookupScope: String { FeatureFlags.meetings ? "notes and dictation history" : "dictation history" }

    private var instructions: String {
        switch client {
        case .claudeDesktop: "Lets Claude Desktop look up your \(lookupScope)."
        case .claudeCode:
            FeatureFlags.meetings
                ? "Ask Claude Code about your meetings from any project's terminal."
                : "Ask Claude Code about what you've dictated from any project's terminal."
        case .codex: "Lets the Codex CLI and app look up your \(lookupScope)."
        case .cursor: "Lets Cursor look up your \(lookupScope)."
        }
    }

    private var confirmMessage: String {
        if let url = client.configURL {
            if hasLegacyEntry {
                return "Hushy will rename the existing “murmur” entry in \(url.path) to “hushy” and keep a backup of the previous file. Restart \(client.title) afterwards."
            }
            return "Hushy will add a “hushy” entry to \(url.path) and keep a backup of the previous file. Restart \(client.title) afterwards."
        }
        return "Copies the command to your clipboard. Run it once in Terminal, then restart \(client.title)."
    }

    @ViewBuilder
    private var actionButton: some View {
        switch status {
        case .notInstalled:
            Text("Install \(client.title) first").font(Theme.Font.caption).foregroundStyle(Theme.textTertiary)
        case .notConnected:
            Button(hasLegacyEntry ? "Update" : "Connect") { confirmInstall = true }
                .buttonStyle(PrimaryButtonStyle())
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
        if client.configURL == nil {
            // Claude Code: no config file to edit — copy the command for the user to run.
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(MCPInstaller.snippet(for: client), forType: .string)
            MCPInstaller.markClaudeCodeConnected()
            message = ("Command copied. Run it in Terminal, then restart Claude Code.", false)
            justConnected = true
            refresh()
            return
        }
        do {
            try MCPInstaller.install(client)
            // Verify by re-reading the config from disk rather than trusting the write succeeded.
            refresh()
            if status == .connected {
                message = ("Added and verified in \(client.title)'s config.", false)
                justConnected = true
            } else {
                message = ("Wrote the config, but couldn't verify it on re-read.", true)
            }
        } catch {
            message = (error.localizedDescription, true)
        }
    }
}

private struct StatusBadge: View {
    let status: MCPInstaller.ConnectionStatus

    private var color: Color {
        switch status {
        case .notInstalled: Theme.textTertiary
        case .notConnected: Theme.warning
        case .connected: Theme.success
        }
    }

    var body: some View {
        HStack(spacing: 5) {
            Circle().fill(color).frame(width: 6, height: 6)
            Text(status.title).font(Theme.Font.caption).foregroundStyle(Theme.textSecondary)
        }
        .padding(.horizontal, Theme.Space.s)
        .padding(.vertical, 4)
        .background(Capsule().fill(Theme.bgSunken))
    }
}

private struct Step: View {
    let number: String
    let title: String
    let text: String

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            Text(number)
                .font(.system(size: 12, weight: .bold, design: .monospaced))
                .foregroundStyle(Theme.onPhosphor)
                .frame(width: 22, height: 22)
                .background(Circle().fill(Theme.phosphorFill))
            Text(title).font(Theme.Font.emphasis).foregroundStyle(Theme.textPrimary)
            Text(text).font(Theme.Font.body).foregroundStyle(Theme.textSecondary).fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
