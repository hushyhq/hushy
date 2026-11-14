import MurmurCore
import SwiftUI

/// Who you are and what Hushy costs: your name, the founding-member badge, the price line, and the
/// account itself (sign in or out). Hushy is free (founder, 2026-11-11): there is no plan to buy,
/// no allowance and no invite code to enter.
struct AccountSettingsPane: View {
    @Environment(AppModel.self) private var model
    @Environment(BetaGateController.self) private var gate
    @Environment(\.isSnapshot) private var isSnapshot
    @Environment(\.snapshotPlan) private var snapshotPlan
    @Environment(\.snapshotProAccount) private var snapshotAccount

    private var signedIn: Bool { snapshotAccount?.signedIn ?? (gate.currentSession != nil) }
    private var configuration: AccountConfiguration? { snapshotAccount?.configuration ?? AccountConfiguration() }
    private var isFoundingMember: Bool {
        snapshotPlan?.isFoundingMember ?? FoundingMember().isMember(signedIn: signedIn)
    }

    var body: some View {
        @Bindable var settings = model.settings
        VStack(alignment: .leading, spacing: Theme.Space.l) {
            SettingsGroup {
                SettingsRow(title: "Your name", detail: "Used in greetings and your email sign-off.", showsDivider: false) {
                    if isSnapshot {
                        SnapshotTextField(settings.userName, placeholder: "")
                            .frame(width: 180)
                    } else {
                        TextField("", text: $settings.userName).textFieldStyle(.roundedBorder).frame(width: 180)
                    }
                }
            }
            .padding(.bottom, Theme.Space.s)
            MembershipRow(isFoundingMember: isFoundingMember)
            VStack(alignment: .leading, spacing: Theme.Space.xs) {
                ForEach(AccountCopy.lines(isFoundingMember: isFoundingMember), id: \.self) { line in
                    Text(line)
                        .font(Theme.Font.body).foregroundStyle(Theme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            if FeatureFlags.accounts, let configuration {
                AccountSettingsSection(configuration: configuration, onChanged: { model.refreshEntitlementSnapshot() })
            }
        }
    }
}

/// The words on the Account pane and the sidebar's profile row (`AccountCopyTests`). The price line
/// is the founder's approved wording (2026-11-11), word for word; the site says the same.
enum AccountCopy {
    static let priceLine = "What runs on your Mac stays free; if we ever charge, it’s for things we host."
    static let foundingPledge = "Nothing you use today will ever go behind a paywall, and you get six months free of any paid plan we add."

    /// "Founding member", or "Free" for everyone else.
    static func badge(isFoundingMember: Bool) -> String {
        isFoundingMember ? "Founding member" : "Free"
    }

    static func lines(isFoundingMember: Bool) -> [String] {
        isFoundingMember ? [priceLine, foundingPledge] : [priceLine]
    }
}

/// The badge: a lime star for a founding member, a quiet person for everyone else.
private struct MembershipRow: View {
    let isFoundingMember: Bool

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: isFoundingMember ? "star.circle.fill" : "person.circle")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(isFoundingMember ? Theme.phosphor : Theme.textTertiary)
            Text(AccountCopy.badge(isFoundingMember: isFoundingMember))
                .font(Theme.Font.body).foregroundStyle(Theme.textPrimary)
            Spacer()
        }
        .accessibilityElement(children: .combine)
    }
}

/// Limits foreground refreshes while allowing a web change to replace the local plan promptly.
struct PlanReturnRefresh {
    static func shouldRefresh(last: Date?, now: Date, signedIn: Bool) -> Bool {
        signedIn && (last.map { now.timeIntervalSince($0) >= 60 } ?? true)
    }
}
