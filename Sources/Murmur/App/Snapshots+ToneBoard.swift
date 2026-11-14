import MurmurCore
import SwiftUI

/// TRY-93: the tone page organised by tone, in the states a person meets: a model that writes register lines (Prompt
/// offered, rewrite examples) and one that does not (Prompt coming, word-level examples), a chip under the pointer,
/// a chip being dragged onto another tone, a kind of app dragged, the move menu (an app, a website, a kind), As
/// spoken on for every app, a Mac with two apps, and the narrow window.
/// Rendered against the snapshot defaults suite; nothing reads anyone's real settings.
extension Snapshots {
    /// Words dictated per app: the order the person's own use gives.
    private static let boardUsage: [String: Int] = [
        "com.tinyspeck.slackmacgap": 2400, "com.apple.mail": 1500, "com.anthropic.claudefordesktop": 1300,
        "com.apple.MobileSMS": 900, "com.apple.Notes": 700, "net.whatsapp.WhatsApp": 500,
    ]

    /// A Mac where the person has placed a few apps: Messages and WhatsApp on Casual (the demo setting), Teams on
    /// Professional, an unknown writing app added by hand to Refined, and Notes and Google Docs (a website) on As
    /// spoken, the founder's own case.
    private static var placedTones: ToneSettings {
        let apps = ToneSettings.standard
            .settingApp(.tone(.casual), bundleIDs: ["com.apple.MobileSMS"])
            .settingApp(.tone(.casual), bundleIDs: ["net.whatsapp.WhatsApp"])
            .settingApp(.tone(.professional), bundleIDs: ["com.microsoft.teams2", "com.microsoft.teams"])
            .settingApp(.asSpoken, bundleIDs: ["com.apple.Notes"])
            .addingApp("com.example.writer", to: .everythingElse)
        return ToneBoard.addingSite("google-docs", to: .asSpoken, in: apps, promptAvailable: true)
            .addingSite("gmail")
    }

    static func renderToneBoard(model: AppModel, scheme: ColorScheme, directory: URL) async {
        let width: CGFloat = 760
        let states: [(name: String, tones: ToneSettings, board: ToneBoardSnapshot, apps: FixedInstalledApps, width: CGFloat)] = [
            ("tones-v2-board", placedTones, ToneBoardSnapshot(), toneSnapshotApps, width),
            ("tones-v2-board-noregister", placedTones, ToneBoardSnapshot(registerLines: false), toneSnapshotApps, width),
            ("tones-v2-hover", placedTones, ToneBoardSnapshot(hovered: "com.tinyspeck.slackmacgap"), toneSnapshotApps, width),
            ("tones-v2-drag", placedTones,
             ToneBoardSnapshot(dragging: "com.tinyspeck.slackmacgap", target: .professional), toneSnapshotApps, width),
            ("tones-v2-drag-kind", placedTones,
             ToneBoardSnapshot(dragging: ToneBoard.kindChipID(.email), target: .casual), toneSnapshotApps, width),
            ("tones-v2-drag-empty", ToneSettings.standard,
             ToneBoardSnapshot(dragging: "com.apple.MobileSMS", target: .casual), toneSnapshotApps, width),
            ("tones-v2-as-spoken", { var tones = placedTones; tones.isAsSpoken = true; return tones }(),
             ToneBoardSnapshot(), toneSnapshotApps, width),
            ("tones-v2-sparse", ToneSettings.standard, ToneBoardSnapshot(),
             FixedInstalledApps(ids: ["com.apple.mail", "com.apple.Notes"]), width),
            ("tones-v2-narrow", placedTones, ToneBoardSnapshot(), toneSnapshotApps, 520),
        ]
        for state in states {
            model.settings.toneSettings = state.tones
            await capture(
                StyleTabContent().padding(Theme.Space.xl).environment(model)
                    .environment(\.installedApps, state.apps).environment(\.snapshotAppUsage, boardUsage)
                    .environment(\.snapshotToneBoard, state.board),
                name: state.name, scheme: scheme, size: CGSize(width: state.width + Theme.Space.xl * 2, height: 400),
                directory: directory)
        }
        // The move menu a click on Slack opens, as the popover draws it.
        model.settings.toneSettings = placedTones
        let board = ToneBoard.make(settings: placedTones, installed: toneSnapshotApps, promptAvailable: true)
        for id in ["com.tinyspeck.slackmacgap", "com.microsoft.teams2", ToneBoard.siteChipID("google-docs"),
                   ToneBoard.kindChipID(.email)] {
            if let app = board.app(id: id) {
                await capture(
                    ToneMoveMenu(app: app, destinations: board.destinations(for: app), pick: { _ in },
                                 remove: app.isSite ? {} : nil)
                        .background(RoundedRectangle(cornerRadius: 10).fill(Theme.bgRaised))
                        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Theme.hairline, lineWidth: 0.5))
                        .shadow(color: .black.opacity(0.18), radius: 16, y: 6)
                        .padding(28),
                    name: "tones-v2-menu-\(app.name.lowercased().replacingOccurrences(of: " ", with: "-"))",
                    scheme: scheme, size: CGSize(width: 300, height: 290), directory: directory, fixedSize: true)
            }
        }
        // The whole page in the window, as a person finds it.
        model.section = .style
        await capture(
            MainView().environment(model)
                .environment(\.snapshotVoiceStyleTab, .style)
                .environment(\.installedApps, toneSnapshotApps).environment(\.snapshotAppUsage, boardUsage)
                .environment(\.snapshotToneBoard, ToneBoardSnapshot()),
            name: "tones-v2-page", scheme: scheme, size: CGSize(width: 1320, height: 2300), directory: directory)
        model.settings.toneSettings = .standard
    }
}
