import MurmurCore
import SwiftUI

/// The sidebar's lower band (founder, 2026-09-28: "the lower pane looks bad… we need a profile
/// for the user"; founder test the same night, P0 9: the two status rows under Record a note —
/// "Hold fn to dictate · ready" and the action row — were clickable but did nothing, and he
/// doesn't want them there at all). Two layouts, one live, both rendered by `--snapshots` for
/// the founder's pick (`home` and `home-sidebar-hint`):
///
/// - `.quiet` (live): Record a note, then the Assistant. Readiness is folded into one row that
///   exists only while something blocks dictation (`SidebarReadinessRow`: mic or Accessibility
///   missing, the speech model downloading or failed, a Keyboard-settings conflict) and carries
///   that state's fix; when everything is ready there is nothing to click and nothing to read.
/// - `.hint`: the same, plus a static key-cap line under Record a note ("fn dictate ·
///   fn + control action") — never a button, so it can't do nothing when clicked.
enum SidebarLayout: Equatable {
    case quiet
    case hint
}

/// The pure copy behind the profile row (`SidebarRowsTests`).
enum SidebarProfile {
    /// The display name, or "You" until a name is set (Settings → General → Your name).
    static func title(name: String) -> String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "You" : trimmed
    }

    /// The initial for the avatar, or nil when there's no name to take one from.
    static func initial(name: String) -> String? {
        title(name: name) == "You" ? nil : title(name: name).prefix(1).uppercased()
    }

    /// "Founding member" or "Free" (`AccountCopy.badge`).
    static func planLine(isFoundingMember: Bool) -> String {
        AccountCopy.badge(isFoundingMember: isFoundingMember)
    }
}

/// When the sidebar shows its readiness row: only while dictation is blocked or the model is on
/// its way (`SidebarRowsTests`). "Ready" is the absence of the row, not a line saying so.
enum SidebarReadiness {
    static func showsRow(_ status: DictationReadinessStatus) -> Bool {
        status.kind != .ready
    }
}

/// The footer's profile: who you are (Settings → General → Your name) and, for a founding member,
/// the badge. Clicking opens Settings → Account — the account lives there — like the workspace
/// row at the bottom of Slack's or Notion's sidebar.
struct SidebarProfileRow: View {
    @Environment(AppModel.self) private var model
    @Environment(\.snapshotPlan) private var snapshotPlan
    @Environment(BetaGateController.self) private var gate
    var collapsed: Bool
    @State private var hovering = false

    private var name: String { model.settings.userName }
    private var isFoundingMember: Bool {
        snapshotPlan?.isFoundingMember ?? FoundingMember().isMember(signedIn: gate.currentSession != nil)
    }

    var body: some View {
        Button { model.openAccountSettings() } label: {
            HStack(spacing: 8) {
                avatar
                if !collapsed {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(SidebarProfile.title(name: name))
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(Theme.textPrimary)
                            .lineLimit(1)
                        // One point under the caption size, so "Founding member" reads whole beside the
                        // footer's three buttons.
                        Text(SidebarProfile.planLine(isFoundingMember: isFoundingMember))
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(isFoundingMember ? Theme.phosphor : Theme.textTertiary)
                            .lineLimit(1)
                            .minimumScaleFactor(0.85)
                    }
                    Spacer(minLength: 0)
                }
            }
            .padding(.horizontal, collapsed ? 0 : Theme.Space.s)
            .padding(.vertical, 6)
            .background(RoundedRectangle(cornerRadius: Theme.Radius.control).fill(hovering ? Theme.selection.opacity(0.6) : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(Theme.fade, value: hovering)
        .help("Your account (Settings → Account)")
        .accessibilityLabel("\(SidebarProfile.title(name: name)), \(SidebarProfile.planLine(isFoundingMember: isFoundingMember))")
    }

    /// A 26 pt disc with the first letter of the name; lime-tinted for a founding member, quiet otherwise.
    private var avatar: some View {
        ZStack {
            Circle().fill(isFoundingMember ? Theme.phosphorTint : Theme.bgRaised)
            Circle().strokeBorder(Theme.hairline, lineWidth: 0.5)
            if let initial = SidebarProfile.initial(name: name) {
                Text(initial)
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                    .foregroundStyle(isFoundingMember ? Theme.phosphor : Theme.textSecondary)
            } else {
                Image(systemName: "person.fill")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Theme.textTertiary)
            }
        }
        .frame(width: 26, height: 26)
    }
}

/// The one readiness row, shown only while something blocks dictation (see `SidebarReadiness`).
/// Shares its state-to-copy mapping with `DictationReadinessStatus` (unit-tested) — the same
/// computation Home's dictation card uses (`AppModel.dictationReadiness`) — and clicking runs
/// that state's fix (request mic access, request Accessibility, open Keyboard settings, retry
/// the model load, approve a metered download). It never starts a dictation: the founder's "Hold fn to dictate · ready"
/// row was a button that did nothing visible, and this row exists only when there is something
/// to do.
struct SidebarReadinessRow: View {
    @Environment(AppModel.self) private var model
    @Environment(\.snapshotDictateWarning) private var snapshotDictateWarning
    var collapsed: Bool
    @State private var hovering = false

    private var status: DictationReadinessStatus {
        model.dictationReadiness(forcingKeyConflict: snapshotDictateWarning)
    }

    var body: some View {
        let status = status
        if SidebarReadiness.showsRow(status) {
            row(status)
                .transition(.opacity)
        }
    }

    private func tint(_ status: DictationReadinessStatus) -> Color {
        switch status.kind {
        case .ready: Theme.textSecondary
        case .warning: Theme.warning
        case .error: Theme.error
        // A transfer is ink, not the model's purple (docs/product/UI-ROUND-2026-09-28.md §3, C2).
        case .downloading: Theme.textTertiary
        case .loading: Theme.working
        }
    }

    private func row(_ status: DictationReadinessStatus) -> some View {
        let isBusy = status.kind == .downloading || status.kind == .loading
        let hasFix = status.fix != nil
        return Button { model.runReadinessFix(status.fix) } label: {
            HStack(spacing: 8) {
                if isBusy {
                    ProgressView().controlSize(.mini).tint(tint(status)).frame(width: 13, height: 13)
                } else {
                    Image(systemName: status.kind == .warning ? "exclamationmark.triangle" : "exclamationmark.circle")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(tint(status))
                        .frame(width: 13)
                }
                if !collapsed {
                    Text(status.text)
                        .font(Theme.Font.caption)
                        .foregroundStyle(Theme.textSecondary)
                        .lineLimit(1)
                    Spacer(minLength: 0)
                    if hasFix {
                        Image(systemName: "arrow.right")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundStyle(Theme.textTertiary)
                    }
                }
            }
            .padding(.horizontal, collapsed ? 0 : Theme.Space.s)
            .padding(.vertical, 6)
            .background(RoundedRectangle(cornerRadius: Theme.Radius.control)
                .fill(hovering && hasFix ? Theme.selection.opacity(0.5) : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!hasFix)
        .onHover { hovering = $0 }
        .help(collapsed ? status.text : status.detail)
        .accessibilityLabel(status.text)
        .accessibilityHint(status.detail)
    }
}

/// `SidebarLayout.hint`'s static key-cap line: "fn dictate · control ×2 action" (the second key is the chosen action key). Text, not a
/// control — it explains the two holds where Record a note lives, and nothing happens when it's
/// clicked because it isn't clickable. The key cap follows Settings (`effectiveActionTrigger`)
/// so it reads the same as onboarding and Home.
struct SidebarKeyHint: View {
    @Environment(AppModel.self) private var model
    var collapsed: Bool

    var body: some View {
        if !collapsed {
            HStack(spacing: 5) {
                KeyCap(label: model.settings.triggerKey.glyph, size: 10)
                Text("dictate")
                Text("·").foregroundStyle(Theme.textTertiary)
                KeyCap(label: model.settings.effectiveActionTrigger.keyCap, size: 10)
                Text("×2 action")
                Spacer(minLength: 0)
            }
            .font(Theme.Font.caption)
            .foregroundStyle(Theme.textTertiary)
            .padding(.horizontal, Theme.Space.s)
            .padding(.vertical, 4)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Hold \(model.settings.triggerKey.title) to dictate; press \(model.settings.effectiveActionTrigger.phrase) for a voice action")
        }
    }
}
