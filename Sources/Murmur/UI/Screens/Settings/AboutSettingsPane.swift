import AppKit
import MurmurCore
import SwiftUI

/// Version and updates, what Hushy is running on, feedback, the tour, and the data folder shortcut.
/// "Uninstall Hushy…" sits at the bottom: the one row nobody opens daily, next to the data it
/// removes. The status of the speech model and of what polishes text is one block here, "How Hushy
/// is running", and nowhere else in Settings.
struct AboutSettingsPane: View {
    @Environment(AppModel.self) private var model
    @Environment(\.isSnapshot) private var isSnapshot
    @State private var uninstall: UninstallFlow?
    @State private var showFeedback = false
    @State private var installsUpdatesAutomatically = false

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.xl) {
            SettingsGroup {
                SettingsRow(title: "Version", detail: AppVersion.displayString) { EmptyView() }
                SettingsRow(title: "Updates", detail: model.updates.statusText) {
                    Button("Check for Updates…") { model.updates.checkForUpdates() }
                        .buttonStyle(SecondaryButtonStyle())
                }
                SettingsRow(title: "Install updates automatically", detail: UpdateCopy.switchDetail) {
                    SwitchToggle(isOn: $installsUpdatesAutomatically)
                        .disabled(!model.updates.isConfigured)
                        .onChange(of: installsUpdatesAutomatically) { _, value in model.updates.installsAutomatically = value }
                }
                SettingsRow(title: "Data folder", detail: "Where Hushy keeps your history and settings on this Mac.", showsDivider: false) {
                    Button("Show in Finder") { NSWorkspace.shared.open(AppPaths.supportDirectory) }
                        .buttonStyle(SecondaryButtonStyle())
                }
            }
            SettingsGroup(title: "How Hushy is running") {
                SettingsRow(title: "Speech recognition", detail: speechDetail) { speechStatus }
                SettingsRow(title: "Polish", detail: model.cleanupModel.activeBackendDescription, showsDivider: false) { EmptyView() }
            }
            SettingsGroup {
                SettingsRow(title: "Feedback", detail: FeedbackCopy.aboutDetail) {
                    Button(FeedbackCopy.menuItem) { showFeedback = true }.buttonStyle(SecondaryButtonStyle())
                }
                SettingsRow(title: "Setup tour", detail: "Replay setup and the try-it demo.", showsDivider: false) {
                    Button("Show the tour again", action: replayOnboarding).buttonStyle(SecondaryButtonStyle())
                }
            }
            SettingsGroup {
                SettingsRow(
                    title: "Uninstall Hushy",
                    detail: "Removes the app and everything it keeps on this Mac. You see the full list first, and your export folder stays.",
                    showsDivider: false) {
                    Button("Uninstall…", action: openUninstall).buttonStyle(SecondaryButtonStyle())
                }
            }
        }
        .onAppear { installsUpdatesAutomatically = model.updates.installsAutomatically }
        .sheet(item: $uninstall) { flow in UninstallSheet(flow: flow) }
        .sheet(isPresented: $showFeedback) { FeedbackSheet().environment(model) }
    }

    /// The language coverage, as the General pane's Language picker offers it.
    private var speechDetail: String { model.settings.speechLanguageMode.modelVersion.settingsLabel }

    @ViewBuilder private var speechStatus: some View {
        if case .downloading(let progress) = model.modelStatus.state {
            ProgressView(value: progress).frame(width: 120)
        } else if case .failed = model.modelStatus.state {
            Label(model.modelStatus.label, systemImage: "exclamationmark.triangle.fill")
                .font(Theme.Font.caption).foregroundStyle(Theme.error)
        } else {
            Text(model.modelStatus.label).font(Theme.Font.caption).foregroundStyle(Theme.textSecondary)
        }
    }

    /// Onboarding lives in the main window: close Settings and bring it forward.
    private func replayOnboarding() {
        guard !isSnapshot else { return }
        model.showOnboarding = true
        NSApp.keyWindow?.close()
        model.openWindowHandler?()
        NSApp.activate()
    }

    /// Opens the review. Nothing is removed until the person ticks the box and presses the button there.
    private func openUninstall() {
        guard !isSnapshot else { return }
        let flow = UninstallFlow(dependencies: .live(model: model))
        flow.onClose = { uninstall = nil }
        model.quitAfterUninstall = { [weak flow] in flow?.handleAppQuit() ?? false }
        uninstall = flow
    }
}
