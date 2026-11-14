import FluidAudio
import MurmurCore
import SwiftUI

/// Shared row/group/badge building blocks used by every settings pane, plus the small pieces
/// (`PermissionsCard`, `PermissionRow`) that live above the pane split when something needs
/// attention, and the sidebar row used by the left navigation list. Split out of
/// `SettingsView.swift` so each pane file only contains its own rows.

extension AsrModelVersion {
    /// What users see: the language coverage, not the model or hardware behind it. Debug
    /// builds append the engine name for us.
    var settingsLabel: String {
        #if DEBUG
        return "\(userLabel) · \(engineName)"
        #else
        return userLabel
        #endif
    }

    private var userLabel: String {
        switch self {
        case .ultra: "Best accuracy on natural speech"
        case .v3: "25 languages"
        case .v2: "English only fallback"
        case .redux: "25 languages · compact"
        case .tdtCtc110m: "English · compact"
        case .tdtJa: "Japanese"
        }
    }

    private var engineName: String {
        switch self {
        case .ultra: "Parakeet Ultra"
        case .v3: "Parakeet TDT v3"
        case .v2: "Parakeet TDT v2"
        case .redux: "Parakeet Redux"
        case .tdtCtc110m: "Parakeet TDT-CTC 110M"
        case .tdtJa: "Parakeet TDT ja"
        }
    }
}

struct SettingsGroup<Content: View>: View {
    var title: String?
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            if let title { Eyebrow(title) }
            Card(padding: 0) {
                VStack(alignment: .leading, spacing: 0) {
                    content
                }
            }
        }
    }
}

struct SettingsRow<Control: View>: View {
    let title: String
    let detail: String
    /// False for a group's last row, where the line would run past the card's rounded corner.
    var showsDivider = true
    /// Puts the detail under the title and the control, across the whole row, for a row whose
    /// control is wide and whose detail is a sentence or two: beside a wide control the detail
    /// would be squeezed into a narrow, tall column. Off everywhere else.
    var detailBelow = false
    /// A link that opens more about the setting, under its detail rather than beside the control.
    var detailLink: SettingsRowLink?
    @ViewBuilder var control: Control

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            HStack(spacing: Theme.Space.l) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.system(size: 14, weight: .medium)).foregroundStyle(Theme.textPrimary)
                    if !detailBelow { detailText }
                }
                Spacer(minLength: Theme.Space.l)
                control
            }
            if detailBelow { detailText }
        }
        .padding(.horizontal, Theme.Space.l)
        .padding(.vertical, Theme.Space.m)
        .overlay(alignment: .bottom) {
            if showsDivider {
                Rectangle().fill(Theme.hairline).frame(height: 0.5).padding(.leading, Theme.Space.l)
            }
        }
    }

    // Wraps rather than truncates: the Settings window sizes to its content, and a clipped "…"
    // hides exactly the sentence that explains the setting.
    private var detailText: some View {
        VStack(alignment: .leading, spacing: Theme.Space.xs) {
            Text(detail).font(Theme.Font.caption).foregroundStyle(Theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            if let detailLink {
                LinkLikeButton(title: detailLink.title, action: detailLink.action)
            }
        }
    }
}

struct SettingsRowLink {
    let title: String
    let action: () -> Void
}

/// A row that shows the current value as plain text plus a "Change" button, for settings whose
/// control is a picker/sheet elsewhere rather than an inline toggle — the Wispr-Flow-style
/// pattern this Settings window follows throughout.
struct SettingsChangeRow: View {
    let title: String
    let value: String
    let action: () -> Void
    var buttonTitle = "Change"

    var body: some View {
        SettingsRow(title: title, detail: value) {
            Button(buttonTitle, action: action).buttonStyle(SecondaryButtonStyle())
        }
    }
}

struct PermissionsCard: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Card(padding: Theme.Space.xl) {
            VStack(alignment: .leading, spacing: Theme.Space.m) {
                Label("Finish setup", systemImage: "exclamationmark.circle.fill")
                    .font(Theme.Font.emphasis).foregroundStyle(Theme.warning)
                PermissionRow(
                    title: "Microphone", detail: "To hear you. Audio is processed on this Mac only.",
                    granted: model.permissions.microphone == .granted
                ) { Task { await model.permissions.requestMicrophone() } }
                PermissionRow(
                    title: "Accessibility", detail: "To detect the \(model.settings.triggerKey.glyph) key and paste text where your cursor is.",
                    granted: model.permissions.accessibility == .granted
                ) {
                    model.permissions.requestAccessibility()
                    model.installHotkeys()
                }
                if model.settings.triggerKey == .fn, Permissions.globeKeyAction.conflicts {
                    PermissionRow(
                        title: "Globe key", detail: "It's set to “\(Permissions.globeKeyAction.title)”. Set “Press 🌐 key to” → Do Nothing so fn only dictates.",
                        granted: false, actionTitle: "Open Keyboard Settings"
                    ) { Permissions.openKeyboardSettings() }
                }
            }
        }
        .onAppear { model.permissions.startPolling() }
    }
}

struct PermissionRow: View {
    let title: String
    let detail: String
    let granted: Bool
    var actionTitle = "Grant"
    let action: () -> Void

    var body: some View {
        HStack(spacing: Theme.Space.m) {
            Image(systemName: granted ? "checkmark.circle.fill" : "circle.dashed")
                .font(.system(size: 18))
                .foregroundStyle(granted ? Theme.success : Theme.textTertiary)
                .contentTransition(.symbolEffect(.replace))
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(Theme.Font.emphasis)
                Text(detail).font(Theme.Font.caption).foregroundStyle(Theme.textSecondary)
            }
            Spacer()
            if !granted {
                Button(actionTitle, action: action).buttonStyle(PrimaryButtonStyle())
            }
        }
    }
}

/// One row in the left sidebar — icon, title, and a needs-
/// attention dot when that pane has something to resolve (only General currently surfaces one,
/// via the permissions badge).
struct SettingsSidebarRow: View {
    let pane: SettingsPane
    let isSelected: Bool
    var showsAttentionDot = false
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: Theme.Space.s) {
                Image(systemName: pane.symbol)
                    .font(.system(size: 14, weight: .medium))
                    .frame(width: 18)
                    .foregroundStyle(isSelected ? Theme.textPrimary : Theme.textSecondary)
                Text(pane.title)
                    .font(.system(size: 14, weight: isSelected ? .semibold : .regular))
                    .foregroundStyle(isSelected ? Theme.textPrimary : Theme.textSecondary)
                Spacer()
                if showsAttentionDot {
                    Circle().fill(Theme.warning).frame(width: 6, height: 6)
                }
            }
            .padding(.horizontal, Theme.Space.m)
            .padding(.vertical, 7)
            .background(
                RoundedRectangle(cornerRadius: Theme.Radius.control)
                    .fill(isSelected ? Theme.phosphorTint : (hovering ? Theme.selection : .clear)))
            // The whole row takes the click and the hover, not only its icon and words.
            .contentShape(RoundedRectangle(cornerRadius: Theme.Radius.control))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(Theme.fade, value: hovering)
    }
}

/// The Settings window's left column: one row per pane and the version at the bottom. Shared by
/// the live window and the snapshot page so they cannot drift apart.
struct SettingsSidebar: View {
    let panes: [SettingsPane]
    let selected: SettingsPane
    let needsAttentionBadge: Bool
    let select: (SettingsPane) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 1) {
                ForEach(panes) { pane in
                    SettingsSidebarRow(
                        pane: pane, isSelected: pane == selected,
                        showsAttentionDot: pane == .general && needsAttentionBadge
                    ) { select(pane) }
                }
            }
            .padding(.top, Theme.Space.xl)
            .padding(.horizontal, Theme.Space.s)

            Spacer(minLength: Theme.Space.l)

            Text(AppVersion.footerString)
                .font(.system(size: 12))
                .foregroundStyle(Theme.textTertiary)
                .padding(.horizontal, Theme.Space.l)
                .padding(.bottom, Theme.Space.l)
        }
        .frame(width: SettingsView.sidebarWidth, alignment: .topLeading)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(Theme.bgSunken)
    }
}
