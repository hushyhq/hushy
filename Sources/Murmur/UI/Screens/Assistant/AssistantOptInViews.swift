import MurmurCore
import SwiftUI

/// The Assistant while it's off (the default): one compact card under the action items. Nothing
/// is checked, launched or sent until the user turns it on and agrees to the consent sheet.
struct AssistantOffCard: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            HStack(spacing: Theme.Space.s) {
                ZStack {
                    Circle().fill(Theme.phosphorTint).frame(width: 28, height: 28)
                    Image(systemName: "bubble.left.and.text.bubble.right")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(Theme.phosphor)
                }
                Text(AssistantAgentCopy.offCardTitle)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Theme.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Text(AssistantAgentCopy.offCardDetail)
                .font(Theme.Font.caption)
                .foregroundStyle(Theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            Text(AssistantAgentCopy.offCardInstallLine)
                .font(Theme.Font.caption)
                .foregroundStyle(Theme.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
            Button("Turn on…") { model.assistant.requestEnable(from: .home) }
                .buttonStyle(SecondaryButtonStyle())
                .padding(.top, 2)
        }
        .padding(Theme.Space.m)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: Theme.Radius.card).fill(Theme.bgRaised))
        .overlay(RoundedRectangle(cornerRadius: Theme.Radius.card).strokeBorder(Theme.hairline, lineWidth: 0.5))
    }
}

/// The one-time consent sheet shown the first time the Assistant is turned on (and again if
/// `AssistantConsent.currentVersion` is bumped). Plain words, three points, two buttons.
struct AssistantConsentSheet: View {
    let onAccept: () -> Void
    let onCancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.l) {
            HStack(spacing: Theme.Space.m) {
                ZStack {
                    Circle().fill(Theme.phosphorTint).frame(width: 40, height: 40)
                    Image(systemName: "arrow.up.right.circle").font(.system(size: 18, weight: .medium)).foregroundStyle(Theme.phosphor)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(AssistantConsent.title)
                        .font(.system(size: 20, design: .serif))
                        .foregroundStyle(Theme.textPrimary)
                    Text("Before you turn this on")
                        .font(Theme.Font.caption)
                        .foregroundStyle(Theme.textSecondary)
                }
            }
            VStack(alignment: .leading, spacing: Theme.Space.m) {
                ForEach(Array(AssistantConsent.points.enumerated()), id: \.offset) { index, point in
                    HStack(alignment: .firstTextBaseline, spacing: Theme.Space.s) {
                        Image(systemName: ["paperplane", "hand.raised", "lock"][index % 3])
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(index == 0 ? Theme.warning : Theme.success)
                            .frame(width: 18)
                        Text(point)
                            .font(.system(size: 13))
                            .foregroundStyle(Theme.textPrimary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            .padding(Theme.Space.l)
            .background(RoundedRectangle(cornerRadius: Theme.Radius.card).fill(Theme.bgRaised))
            .overlay(RoundedRectangle(cornerRadius: Theme.Radius.card).strokeBorder(Theme.hairline, lineWidth: 0.5))
            Text("You can turn this off, and delete saved chats, in Settings any time.")
                .font(Theme.Font.caption)
                .foregroundStyle(Theme.textTertiary)
            HStack {
                Spacer()
                Button("Not now", action: onCancel)
                    .buttonStyle(SecondaryButtonStyle())
                    .keyboardShortcut(.cancelAction)
                Button("Turn on Assistant", action: onAccept)
                    .buttonStyle(PrimaryButtonStyle())
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(Theme.Space.xl)
        .frame(width: 460)
        .background(Theme.bgBase)
    }
}

/// Shown instead of the chat while the Assistant is on but Claude Code can't answer yet: not
/// installed (copyable install command + docs), or signed out (the vendor's own sign-in).
struct AgentSetupCard: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let accounts = model.assistant.accounts
        let state = accounts.state(of: .claudeCode)
        VStack(alignment: .leading, spacing: Theme.Space.m) {
            ZStack {
                Circle().fill(Theme.phosphorTint).frame(width: 36, height: 36)
                Image(systemName: "sparkles").font(.system(size: 15, weight: .medium)).foregroundStyle(Theme.phosphor)
            }
            Text(AssistantAgentCopy.setupTitle(claudeState: state))
                .font(.system(size: 17, design: .serif))
                .foregroundStyle(Theme.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
            let setupDetail = AssistantAgentCopy.setupBody(claudeState: state)
            if !setupDetail.isEmpty {
                Text(setupDetail)
                    .font(Theme.Font.caption)
                    .foregroundStyle(Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            AgentAccountControls(agent: .claudeCode, compact: false)
            if let footnote = AssistantAgentCopy.codexInstalledFootnote(codexState: accounts.state(of: .codex)) {
                Text(footnote)
                    .font(Theme.Font.caption)
                    .foregroundStyle(Theme.textTertiary)
            }
        }
        .padding(Theme.Space.l)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: Theme.Radius.card).fill(Theme.bgRaised))
        .overlay(RoundedRectangle(cornerRadius: Theme.Radius.card).strokeBorder(Theme.hairline, lineWidth: 0.5))
    }
}

/// An agent's sign-in/install controls, shared by the Assistant's setup card and Settings →
/// AI connections: Install (copy command + docs), Sign in, the in-progress line, Check again.
struct AgentAccountControls: View {
    let agent: AgentKind
    var compact: Bool
    @Environment(AppModel.self) private var model
    @State private var copied = false

    var body: some View {
        let accounts = model.assistant.accounts
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            switch accounts.state(of: agent) {
            case .notInstalled:
                if !compact {
                    Text(AgentAuth.installCommand(for: agent))
                        .font(Theme.Font.mono)
                        .foregroundStyle(Theme.textPrimary)
                        .textSelection(.enabled)
                        .padding(Theme.Space.s)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(RoundedRectangle(cornerRadius: Theme.Radius.control).fill(Theme.bgSunken))
                }
                HStack(spacing: Theme.Space.s) {
                    Button(copied ? "Copied" : "Copy install command") {
                        accounts.copyInstallCommand(agent)
                        copied = true
                    }
                    .buttonStyle(SecondaryButtonStyle())
                    Link("Install guide ↗", destination: AgentAuth.docsURL(for: agent))
                        .font(Theme.Font.caption)
                    checkAgain
                }
            case .signedOut:
                signInRow
            case .ready, .unknown:
                if !compact { checkAgain }
            }
            if let line = progressLine {
                Label(line.text, systemImage: line.symbol)
                    .font(Theme.Font.caption)
                    .foregroundStyle(line.isError ? Theme.error : Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    @ViewBuilder
    private var signInRow: some View {
        let accounts = model.assistant.accounts
        HStack(spacing: Theme.Space.s) {
            if accounts.signIn == .inBrowser(agent) {
                ProgressView().controlSize(.small)
                Button("Cancel") { accounts.cancelSignIn() }.buttonStyle(SecondaryButtonStyle())
            } else {
                Button(compact ? "Sign in" : "Sign in to \(agent.title)") { accounts.startSignIn(agent) }
                    .buttonStyle(PrimaryButtonStyle())
                    .fixedSize()
            }
            checkAgain
        }
    }

    private var checkAgain: some View {
        Button("Check again") { model.assistant.refreshAvailability() }
            .buttonStyle(SecondaryButtonStyle())
            .fixedSize()
            .disabled(model.assistant.accounts.isChecking)
    }

    private var progressLine: (text: String, symbol: String, isError: Bool)? {
        switch model.assistant.accounts.signIn {
        case .inBrowser(let current) where current == agent:
            ("Finish signing in in your browser…", "safari", false)
        case .inTerminal(let current) where current == agent:
            ("Finish in Terminal, then click Check again.", "terminal", false)
        case .failed(let current, let message) where current == agent:
            (message, "exclamationmark.triangle", true)
        default:
            nil
        }
    }
}
