import AppKit
import MurmurCore
import SwiftUI

/// What Hushy keeps, what it shares, and who can open it: how long dictations are kept (and a
/// way to erase them), the three things that can be sent (a daily count, on by default; usage numbers and crash
/// reports, each its own consent), on-screen context, learning from edits, and the Touch ID lock. Eight switches and
/// buttons in three groups. Audio retention, recording encryption and the clipboard choice live in
/// Advanced. The retention-impact confirmation is owned by `SettingsView`, which needs it to float
/// above pane switches.
struct PrivacySettingsPane: View {
    @Environment(AppModel.self) private var model
    let retentionBinding: (ReferenceWritableKeyPath<AppSettings, Int?>) -> Binding<Int?>
    @State private var showErase = false
    @State private var showMemory = false

    /// True whatever is switched on, and short enough to read as a footnote: speech becomes text
    /// on this Mac, and Hushy uploads neither audio nor dictations by itself. The Assistant (notes
    /// and meetings, on Send) and connected AI apps (notes, dictation history and usage totals,
    /// when asked) are the person's own doing, so this does not claim that nothing ever leaves.
    static var networkDetail: String { networkText(meetings: FeatureFlags.meetings) }

    static func networkText(meetings: Bool) -> String {
        let readers = meetings ? "Connected AI apps and the Assistant" : "Connected AI apps"
        return "Speech becomes text on this Mac, and Hushy never uploads your audio or dictations by itself. \(readers) read only what you let them, when you use them."
    }

    var body: some View {
        @Bindable var settings = model.settings
        VStack(alignment: .leading, spacing: Theme.Space.xl) {
            SettingsGroup {
                SettingsRow(title: "Keep history", detail: FeatureFlags.meetings
                        ? "Older dictations are deleted from this Mac automatically. Notes are always kept."
                        : "Older dictations are deleted from this Mac automatically.", detailBelow: true) {
                    Picker("", selection: retentionBinding(\.textRetentionDays)) {
                        Text("7 days").tag(Int?.some(7))
                        Text("30 days").tag(Int?.some(30))
                        Text("90 days").tag(Int?.some(90))
                        Text("Forever").tag(Int?.none)
                    }
                    .labelsHidden().frame(width: 140)
                }
                SettingsRow(title: "Erase data", detail: "Choose what to remove from this Mac: history, learning data and more.", showsDivider: false) {
                    Button("Erase…") { showErase = true }.buttonStyle(SecondaryButtonStyle())
                }
                if let error = model.library.storeError {
                    Text("Database error, running in memory: \(error)").font(Theme.Font.caption).foregroundStyle(Theme.error)
                        .padding(.horizontal, Theme.Space.l).padding(.bottom, Theme.Space.m)
                }
            }

            SettingsGroup {
                DailyCountSettingsSection(isOn: $settings.sendDailyCount)
                UsageNumbersSettingsSection(isOn: $settings.shareUsageNumbers, isPausedByStorageFault: settings.usageStorageFault)
                CrashReportsSettingsSection(settings: settings)
            }

            SettingsGroup {
                ContextAwarenessSettingsSection(isEnabled: $settings.contextAwarenessEnabled)
                LearningSettingsSection(learnFromEdits: $settings.learnFromEdits) { showMemory = true }
                SettingsRow(
                    title: FeatureFlags.meetings ? "Require Touch ID to open History & Notes" : "Require Touch ID to open History",
                    detail: FeatureFlags.meetings
                        ? "Dictation keeps working while locked; only viewing past history, notes and insights needs unlocking."
                        : "Dictation keeps working while locked; only viewing past history and insights needs unlocking.",
                    showsDivider: settings.appLockEnabled
                ) {
                    SwitchToggle(isOn: appLockEnabledBinding)
                }
                if settings.appLockEnabled {
                    SettingsRow(title: "Lock after", detail: "Also locks immediately when the screen locks or the Mac sleeps.", showsDivider: false, detailBelow: true) {
                        Picker("", selection: autoLockMinutesBinding) {
                            Text("1 minute").tag(1)
                            Text("5 minutes").tag(5)
                            Text("15 minutes").tag(15)
                            Text("30 minutes").tag(30)
                        }
                        .labelsHidden().frame(width: 140)
                    }
                }
            }

            Label(Self.networkDetail, systemImage: sendsUsageNumbers ? "arrow.up.circle" : "lock.fill")
                .font(Theme.Font.caption).foregroundStyle(Theme.textSecondary)
                .labelStyle(.titleAndIcon)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, Theme.Space.l)
        }
        .sheet(isPresented: $showErase) { EraseDataSheet().environment(model) }
        .sheet(isPresented: $showMemory) {
            if FeatureFlags.personMemory { LockGate { MemoryPane(store: model.store) } }
        }
    }

    /// True only when this build has an endpoint and the person has turned usage numbers on.
    private var sendsUsageNumbers: Bool { model.usageMetrics.isUploadConfigured && model.usageMetrics.isCollecting }

    /// Turning the lock OFF requires a fresh Touch ID / password prompt (see
    /// `AppLockController.authenticateToWeakenProtection`); the toggle snaps back on failure or
    /// cancellation. Turning it ON needs no extra auth beyond enrolling.
    private var appLockEnabledBinding: Binding<Bool> {
        Binding(
            get: { model.settings.appLockEnabled },
            set: { newValue in
                guard !newValue else {
                    model.settings.appLockEnabled = true
                    model.appLock.isEnabled = true
                    return
                }
                Task {
                    let authorized = await model.appLock.authenticateToWeakenProtection(
                        reason: "Confirm it's you to turn off Hushy's lock")
                    guard authorized else { return }
                    model.settings.appLockEnabled = false
                    model.appLock.isEnabled = false
                }
            })
    }

    /// Lengthening the delay weakens protection and requires the same auth prompt; shortening it
    /// does not.
    private var autoLockMinutesBinding: Binding<Int> {
        Binding(
            get: { model.settings.appLockAutoLockMinutes },
            set: { newValue in
                guard newValue > model.settings.appLockAutoLockMinutes else {
                    model.settings.appLockAutoLockMinutes = newValue
                    model.appLock.autoLockMinutes = newValue
                    return
                }
                Task {
                    let authorized = await model.appLock.authenticateToWeakenProtection(
                        reason: "Confirm it's you to lengthen Hushy's auto-lock delay")
                    guard authorized else { return }
                    model.settings.appLockAutoLockMinutes = newValue
                    model.appLock.autoLockMinutes = newValue
                }
            })
    }
}
