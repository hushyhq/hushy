import MurmurCore
import SwiftUI

struct BetaGateView: View {
    let gate: BetaGateController?
    var snapshot: SnapshotState?
    enum SnapshotState: Equatable { case signedOut, browser, expired, waiting, couldNotCheck, checking }

    /// Access is pending and can be checked again here. Names nobody, and promises no email:
    /// the app sends none when an account is approved.
    static let waitingMessage =
        "Your beta access is pending. Press Check again to see whether this account has been approved. When it has, Hushy opens."

    private var isChecking: Bool { snapshot == .checking || (snapshot == nil && (gate?.isChecking ?? false)) }

    private var decision: BetaGateDecision {
        switch snapshot {
        case .signedOut, .browser, .expired: .signIn
        case .waiting: .waiting
        case .couldNotCheck, .checking: .couldNotCheck
        case nil: gate?.decision ?? .signIn
        }
    }

    private var browserPhase: BrowserSignIn.Phase {
        snapshot == .browser ? .waiting : (snapshot == nil ? gate?.browser.phase ?? .idle : .idle)
    }

    private var failureText: String? {
        let failure: BrowserSignIn.Failure? = snapshot == nil ? gate?.browser.failure : (snapshot == .expired ? .expired : nil)
        guard let failure else { return nil }
        switch failure {
        case .unavailable: return "Sign-in is unavailable."
        case .failed: return "Sign-in failed."
        case .expired: return "That sign-in expired. Start again."
        }
    }

    var body: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: Theme.Space.l) {
                Eyebrow("PRIVATE BETA")
                Spacer()
                Text("Hushy").font(Theme.Font.hero).foregroundStyle(Theme.textPrimary)
                Text("Your voice stays on this Mac.")
                    .font(Theme.Font.body).foregroundStyle(Theme.textSecondary)
                Spacer()
            }
            .padding(Theme.Space.xxl)
            .frame(width: 300)
            .frame(maxHeight: .infinity, alignment: .topLeading)
            .background(Theme.bgSunken.opacity(0.5))
            VStack {
                Spacer()
                content.frame(maxWidth: 520, alignment: .leading)
                Spacer()
            }
            .frame(maxWidth: .infinity)
            .padding(Theme.Space.xxl)
        }
        .background(Theme.bgBase)
        .tint(Theme.phosphor)
    }

    @ViewBuilder private var content: some View {
        switch decision {
        case .open: EmptyView()
        case .signIn where browserPhase != .idle:
            StepLayout(symbol: "safari", title: "Waiting for your browser", message: "Finish signing in on the page that just opened. Hushy continues here when you are done.") {
                ProgressView().controlSize(.small)
                if let failureText {
                    Text(failureText).font(Theme.Font.caption).foregroundStyle(Theme.error)
                }
                HStack {
                    Button("Start again") { gate?.browser.start() }
                        .buttonStyle(SecondaryButtonStyle()).disabled(browserPhase == .claiming)
                    Button("Cancel") { gate?.browser.cancel() }
                        .buttonStyle(SecondaryButtonStyle())
                }
            }
        case .signIn:
            StepLayout(symbol: "person.crop.circle", title: "Sign in to Hushy", message: "Use the account you signed up with on the website.") {
                Button("Sign in") { gate?.browser.start() }
                    .buttonStyle(PrimaryButtonStyle())
                if let failureText {
                    Text(failureText).font(Theme.Font.caption).foregroundStyle(Theme.error)
                }
            }
        case .waiting:
            StepLayout(symbol: "clock", title: "Waiting for approval", message: Self.waitingMessage) {
                Text(snapshot == nil ? (gate?.email ?? "") : "person@example.com")
                    .font(Theme.Font.body).foregroundStyle(Theme.textPrimary)
                Button("Check again") { Task { await gate?.checkAgain() } }
                    .buttonStyle(PrimaryButtonStyle()).disabled(isChecking)
                Button("Use another address") { gate?.signOut() }
                    .buttonStyle(SecondaryButtonStyle()).disabled(isChecking)
            }
        case .couldNotCheck where isChecking:
            // The first check is still running; no failure has happened yet, so no failure screen.
            VStack(alignment: .leading, spacing: Theme.Space.l) {
                ProgressView().controlSize(.regular)
                Text(snapshot == nil ? (gate?.email ?? "") : "person@example.com")
                    .font(Theme.Font.body).foregroundStyle(Theme.textPrimary)
            }
        case .couldNotCheck:
            StepLayout(symbol: "wifi.exclamationmark", title: "Could not check approval", message: "Hushy could not check this account. Connect to the internet and try again.") {
                Text(snapshot == nil ? (gate?.email ?? "") : "person@example.com")
                    .font(Theme.Font.body).foregroundStyle(Theme.textPrimary)
                Button("Try again") { Task { await gate?.checkAgain() } }
                    .buttonStyle(PrimaryButtonStyle())
                Button("Use another address") { gate?.signOut() }
                    .buttonStyle(SecondaryButtonStyle())
            }
        }
    }
}
