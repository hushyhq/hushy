import AppKit
import MurmurCore
import SwiftUI

/// Accounts are optional. Nothing is shown unless the feature is enabled and this build carries
/// a Supabase URL. Free use and invite redemption remain entirely local.
struct AccountSettingsSection: View {
    @Environment(BetaGateController.self) private var gate
    @Environment(\.snapshotProAccount) private var snapshotAccount
    let configuration: AccountConfiguration
    let onChanged: () -> Void
    @State private var session: AccountSession?

    private var client: AccountClient { AccountClient(configuration: configuration) }
    private let store = AccountSessionStore()
    private var displaySession: AccountSession? {
        guard let snapshotAccount else { return session }
        return snapshotAccount.signedIn ? snapshotAccount.session : nil
    }

    var body: some View {
        SettingsGroup {
            VStack(alignment: .leading, spacing: Theme.Space.s) {
                if let session = displaySession {
                    Text(session.email ?? "Signed in").font(Theme.Font.body)
                    HStack {
                        Button("Open your account on the web") { NSWorkspace.shared.open(configuration.accountURL) }
                            .buttonStyle(SecondaryButtonStyle())
                        Button("Sign out") { Task { await signOut() } }
                            .buttonStyle(SecondaryButtonStyle())
                    }
                } else {
                    Text(BetaGateBuild.enabled && !BetaGateBuild.bypassesAutomation
                         ? "Sign in with your approved account to use Hushy."
                         : "Sign in to your Hushy account.")
                        .font(Theme.Font.caption).foregroundStyle(Theme.textSecondary)
                    if gate.browser.isActive {
                        Text("Waiting for your browser").font(Theme.Font.body)
                        if gate.browser.failure == .expired {
                            Text("That sign-in expired. Start again.").font(Theme.Font.caption).foregroundStyle(Theme.error)
                        }
                        HStack {
                            Button("Start again") { gate.browser.start() }
                                .buttonStyle(SecondaryButtonStyle()).disabled(gate.browser.phase == .claiming)
                            Button("Cancel") { gate.browser.cancel() }
                                .buttonStyle(SecondaryButtonStyle())
                        }
                    } else {
                        Button("Sign in") { gate.browser.start() }
                            .buttonStyle(PrimaryButtonStyle())
                        switch gate.browser.failure {
                        case .unavailable: Text("Sign-in is unavailable.").font(Theme.Font.caption).foregroundStyle(Theme.error)
                        case .failed: Text("Sign-in failed.").font(Theme.Font.caption).foregroundStyle(Theme.error)
                        case .expired: Text("That sign-in expired. Start again.").font(Theme.Font.caption).foregroundStyle(Theme.error)
                        case nil: EmptyView()
                        }
                    }
                }
            }
            .padding(Theme.Space.l)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .task { if snapshotAccount == nil { await restore() } }
        .onChange(of: gate.signedInRevision) { Task { await adopt() } }

    }

    private func restore() async {
        guard let saved = try? store.load() else { return }
        session = saved
        if saved.expiresAt < Date(), let renewed = try? await AccountSessionKeeper.shared.usable() {
            if renewed.userID != saved.userID { try? AccountEntitlementStore().clear(); onChanged() }
            session = renewed
        }
        await refreshEntitlement()
    }
    private func refreshEntitlement() async {
        guard let session = (try? await AccountSessionKeeper.shared.usable(fallback: session)) ?? session else { return }
        self.session = session
        let cached = try? AccountEntitlementStore().load(for: session.userID)
        if let cached, Date().timeIntervalSince(cached.verifiedAt) < 24 * 3600 { return }
        if let value = try? await client.entitlement(session.accessToken, userID: session.userID),
           self.session?.userID == session.userID {
            try? AccountEntitlementStore().save(value)
            onChanged()
        }
    }
    /// A sign-in the gate has just accepted: take up the new account and what it is entitled to.
    private func adopt() async {
        let previous = session
        session = gate.currentSession ?? (try? store.load())
        if previous?.userID != session?.userID { try? AccountEntitlementStore().clear(); onChanged() }
        await refreshEntitlement()
    }
    private func signOut() async {
        if BetaGateBuild.enabled, !BetaGateBuild.bypassesAutomation {
            gate.signOut()
            session = nil
            onChanged()
            return
        }
        if let session { try? await client.signOut(session.accessToken) }
        try? store.clear()
        try? BetaApprovalStore().clear()
        try? AccountEntitlementStore().clear()
        session = nil
        onChanged()
    }
}
