import AppKit
import SwiftUI

/// What went wrong with Apple Notes, in plain words, with the next step: "Try again" always, and
/// "Open System Settings" only when macOS itself refused (`AppleNotesAccessResult.canOpenSettings`).
/// Shared by the setup choice and the Notes sidebar row, so the two never disagree.
struct AppleNotesAccessNotice: View {
    let result: AppleNotesAccessResult
    /// Narrow layout for the Notes sidebar.
    var compact = false
    let onRetry: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: compact ? 4 : 6) {
            Text(result.message)
                .font(compact ? .system(size: 10.5) : Theme.Font.caption)
                .foregroundStyle(Theme.error)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: compact ? 10 : Theme.Space.s) {
                if result.canOpenSettings {
                    Button("Open System Settings") { NSWorkspace.shared.open(AppleNotesAccessResult.automationSettingsURL) }
                }
                Button("Try again", action: onRetry)
            }
            .buttonStyle(.plain)
            .font(.system(size: compact ? 10.5 : 12, weight: .semibold))
            .foregroundStyle(Theme.phosphor)
        }
    }
}
