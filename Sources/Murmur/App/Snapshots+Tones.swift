import MurmurCore
import SwiftUI

/// Task 112: the tone choice in each state a person can leave it in. Renders against the snapshot
/// defaults suite, so nothing here touches anyone's real settings.
extension Snapshots {
    /// The apps "installed" in the snapshots, so the list never depends on the machine that renders it.
    /// A realistic mixed set, a crowded Mac whose apps include ones the known table has never heard of
    /// (found by what they declare), and a very small one (a Mac with only Mail and Notes).
    static let toneSnapshotApps = FixedInstalledApps(ids: [
        "com.tinyspeck.slackmacgap", "com.microsoft.teams2", "com.apple.mail", "com.microsoft.Outlook",
        "net.whatsapp.WhatsApp", "com.apple.MobileSMS", "com.hnc.Discord", "com.anthropic.claudefordesktop",
        "com.openai.chat", "com.apple.Notes", "notion.id", "com.todesktop.230313mzl4w4u92", "com.microsoft.VSCode",
        "com.apple.Terminal", "com.example.writer",
    ], names: ["com.example.writer": "Writer"])
    private static let fewApps = FixedInstalledApps(ids: ["com.apple.mail", "com.apple.Notes"])
    private static let crowdedApps = FixedInstalledApps(ids: [
        "com.tinyspeck.slackmacgap", "com.microsoft.teams2", "us.zoom.xos", "Cisco-Systems.Spark", "com.linear",
        "com.apple.mail", "com.microsoft.Outlook", "com.readdle.SparkDesktop", "com.superhuman.electron",
        "net.whatsapp.WhatsApp", "com.apple.MobileSMS", "com.hnc.Discord", "ru.keepcoder.Telegram",
        "org.whispersystems.signal-desktop", "com.anthropic.claudefordesktop", "com.openai.chat",
        "com.apple.Notes", "notion.id", "md.obsidian", "com.todesktop.230313mzl4w4u92", "com.microsoft.VSCode",
        "com.apple.dt.Xcode", "com.apple.Terminal", "com.googlecode.iterm2",
    ], found: [
        InstalledAppInfo(bundleID: "com.example.lumenchat", name: "Lumen Chat", declaredCategory: "public.app-category.social-networking"),
        InstalledAppInfo(bundleID: "com.example.nimbusnotes", name: "Nimbus Notes", declaredCategory: "public.app-category.productivity"),
        InstalledAppInfo(bundleID: "com.example.zephyr", name: "Zephyr Terminal", declaredCategory: "public.app-category.developer-tools"),
        InstalledAppInfo(bundleID: "com.example.relayapi", name: "Relay API Client", declaredCategory: "public.app-category.developer-tools"),
        InstalledAppInfo(bundleID: "com.example.ledgerpro", name: "Ledger Pro", declaredCategory: "public.app-category.finance"),
        InstalledAppInfo(bundleID: "com.example.pipeline", name: "Pipeline CRM", declaredCategory: "public.app-category.business"),
        InstalledAppInfo(bundleID: "com.example.mystery", name: "Mystery Tool", declaredCategory: nil),
    ])
    /// Words dictated per app on the crowded Mac: the order the person's own use gives.
    private static let crowdedUsage: [String: Int] = [
        "us.zoom.xos": 900, "com.microsoft.teams2": 400, "com.example.lumenchat": 700, "net.whatsapp.WhatsApp": 300,
        "com.example.nimbusnotes": 800, "notion.id": 500, "com.example.zephyr": 600,
    ]

    static func renderTones(model: AppModel, scheme: ColorScheme, size: CGSize, directory: URL) async {
        let earlier = ToneSettings.Earlier(
            cleanupLevel: "clean", styles: ["personalMessages": "veryCasual", "email": "excited"], isExistingInstall: true)
        let states: [(name: String, tones: ToneSettings, apps: FixedInstalledApps, usage: [String: Int])] = [
            ("folded", .standard, toneSnapshotApps, [:]),
            ("dynamic", ToneSettings.standard
                .settingTone(.casual, for: .personalMessages)
                .settingTone(.professional, for: .workMessages)
                .settingApp(.tone(.casual), bundleIDs: ["com.example.nimbusnotes"]), crowdedApps, crowdedUsage),
            ("sparse", .standard, fewApps, [:]),
            ("kept-layout", ToneSettings.migrated(from: earlier), toneSnapshotApps, [:]),
            ("as-spoken", { var tones = ToneSettings.standard; tones.choice = .asSpoken; return tones }(), toneSnapshotApps, [:]),
        ]
        model.section = .style
        // Tall enough to show every kind and its apps under the picker.
        let tall = CGSize(width: size.width, height: 2400)
        for state in states {
            model.settings.toneSettings = state.tones
            await capture(
                MainView().environment(model)
                    .environment(\.snapshotVoiceStyleTab, .style)
                    .environment(\.installedApps, state.apps).environment(\.snapshotAppUsage, state.usage),
                name: "tones-style-\(state.name)", scheme: scheme, size: tall, directory: directory)
        }
        let appStates: [(String, ToneSettings)] = [
            ("default", .standard),
            ("overridden", .standard.settingApp(.tone(.casual), bundleIDs: ["com.tinyspeck.slackmacgap"])),
            ("moved", .standard.movingApp(to: .email, bundleIDs: ["com.microsoft.teams2", "com.microsoft.teams"])),
        ]
        for (name, tones) in appStates {
            model.settings.toneSettings = tones
            await capture(
                StyleTabContent().environment(model).environment(\.installedApps, toneSnapshotApps),
                name: "apps-tone-\(name)", scheme: scheme, size: CGSize(width: 700, height: 1700), directory: directory)
        }
        await renderToneBoard(model: model, scheme: scheme, directory: directory)
        // The onboarding step, as it appears when the download is still running (the same pin as
        // `onboarding-veryslow-writingStyle`).
        let bytes = SpeechEngine.expectedDownloadBytes(for: model.settings.speechLanguageMode.modelVersion)
        model.permissions.pinForSnapshot(microphone: .granted, accessibility: .granted)
        model.modelStatus.pinForSnapshot(
            .downloading(0.21),
            download: ModelDownloadProgress(
                fraction: 0.21, expectedBytes: bytes, completedFiles: 3, totalFiles: 20, estimatedSecondsRemaining: 390))
        model.downloads.pinForSnapshot()
        let changed = ToneSettings.standard
            .settingTone(.casual, for: .personalMessages)
            .settingApp(.tone(.professional), bundleIDs: ["com.tinyspeck.slackmacgap"])
        let onboarding: [(name: String, tones: ToneSettings, apps: FixedInstalledApps)] = [
            ("sparse", .standard, fewApps), ("crowded", changed, crowdedApps), ("mixed", .standard, toneSnapshotApps),
            ("casual", { var tones = ToneSettings.standard; tones.choice = .casual; return tones }(), toneSnapshotApps),
            ("asSpoken", { var tones = ToneSettings.standard; tones.choice = .asSpoken; return tones }(), toneSnapshotApps),
        ]
        for state in onboarding {
            model.settings.toneSettings = state.tones
            await capture(
                OnboardingView(initialFlow: OnboardingFlow(
                    sequence: [.welcome, .microphone, .accessibility] + OnboardingStep.optionalByValue + [.tryIt, .done],
                    at: .writingStyle)).environment(model).environment(\.installedApps, state.apps)
                    .environment(\.snapshotAppUsage, state.apps.found.isEmpty ? [:] : crowdedUsage),
                name: "tones-onboarding-\(state.name)", scheme: scheme, size: size, directory: directory)
        }
        model.modelStatus.pinForSnapshot(.ready)
        model.downloads.pinForSnapshot()
        model.settings.toneSettings = .standard
        // The navigation and each section at the same measure, in both schemes.
        // At 840 pt, the narrow Style capture has a roughly 510 pt content column
        // after the 248 pt sidebar and 80 pt page padding.
        for tab in VoiceAndStyleView.Tab.allCases {
            await capture(
                MainView().environment(model)
                    .environment(\.snapshotVoiceStyleTab, tab)
                    .environment(\.installedApps, toneSnapshotApps),
                name: "voice-style-\(tab.rawValue)", scheme: scheme,
                size: CGSize(width: size.width, height: tab == .style ? 2400 : 1500), directory: directory)
        }
        await capture(
            MainView().environment(model)
                .environment(\.snapshotVoiceStyleTab, .style)
                .environment(\.installedApps, toneSnapshotApps),
            name: "voice-style-style-narrow", scheme: scheme,
            size: CGSize(width: 840, height: 2400), directory: directory)
        await renderVoiceStyle(model: model, scheme: scheme, size: size, directory: directory)
    }
}
