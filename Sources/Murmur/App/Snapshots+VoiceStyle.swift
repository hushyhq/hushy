import MurmurCore
import SwiftUI

/// Voice & style (2026-10-28 restyle): the states of each tab a still cannot reach by itself. A format under the
/// pointer and the person's own format, the format editor, the dictionary mid-search, with no match and empty, a
/// snippet half written and no snippets yet, a coding project scanned, scanning and failed, and a tone lane under the
/// pointer. Rendered against the snapshot defaults suite; nothing reads anyone's real settings or folders.
extension Snapshots {
    static func renderVoiceStyle(model: AppModel, scheme: ColorScheme, size: CGSize, directory: URL) async {
        model.section = .style
        let tall = CGSize(width: size.width, height: 1500)

        func page(_ tab: VoiceAndStyleView.Tab, _ name: String, height: CGFloat = 1500,
                  _ configure: (AnyView) -> AnyView = { $0 }) async {
            let view = MainView().environment(model)
                .environment(\.snapshotVoiceStyleTab, tab)
                .environment(\.installedApps, toneSnapshotApps)
            await capture(configure(AnyView(view)), name: "voice-style-\(name)", scheme: scheme,
                          size: CGSize(width: tall.width, height: height), directory: directory)
        }

        // Formats
        await page(.formats, "formats-hover") { AnyView($0.environment(\.snapshotFormatHovered, Mode.BuiltInID.email)) }
        let own = Mode(name: "Standup update", icon: "person.2", cleanupLevel: .clean,
                       prompt: "Three short lines: yesterday, today, blockers.", appBundleIDs: [], isBuiltIn: false)
        model.settings.upsertMode(own)
        await page(.formats, "formats-own")
        model.settings.deleteMode(id: own.id)
        let email = model.settings.modes.first { $0.id == Mode.BuiltInID.email }
        for (name, mode) in [("email", email), ("automatic", Mode(
            name: "Client reply", icon: "briefcase", cleanupLevel: .clean,
            prompt: "Format as a short, warm reply to a client.", appBundleIDs: ["com.apple.mail"], isBuiltIn: false))] {
            guard let mode else { continue }
            await capture(
                FormatEditorSheet(mode: mode, onSave: { _ in }).environment(model)
                    .clipShape(RoundedRectangle(cornerRadius: 12)),
                name: "format-editor-\(name)", scheme: scheme, size: CGSize(width: 460, height: 560),
                directory: directory, fixedSize: true)
        }

        // Dictionary
        await page(.dictionary, "dictionary-search") { AnyView($0.environment(\.snapshotDictionary, DictionarySnapshot(query: "fig"))) }
        await page(.dictionary, "dictionary-nomatch") {
            AnyView($0.environment(\.snapshotDictionary, DictionarySnapshot(query: "Kubectl", heardAs: "cube control")))
        }
        await page(.dictionary, "dictionary-empty") { AnyView($0.environment(\.snapshotDictionary, DictionarySnapshot(entries: [], hidesLearned: true))) }

        // Snippets
        await page(.snippets, "snippets-draft") {
            AnyView($0.environment(\.snapshotSnippet, SnippetSnapshot(trigger: "my address", expansion: "1 Infinite Loop, Cupertino, CA 95014")))
        }
        await page(.snippets, "snippets-empty") { AnyView($0.environment(\.snapshotSnippet, SnippetSnapshot(showsEmpty: true))) }

        // Coding
        let coding = model.codingProjectVocabulary
        for (name, state) in [
            ("coding-project", ProjectVocabularySettings.ScanState.done(filesScanned: 412, identifiers: 1_284, fileNames: 318)),
            ("coding-scanning", .scanning),
            ("coding-failed", .failed("Couldn't access that folder.")),
        ] {
            coding.pinForSnapshot(projectName: "hushy-web", scanState: state)
            await page(.coding, name, height: 900)
        }
        coding.pinForSnapshot(projectName: nil, scanState: .idle)

        // Style: a lane under the pointer.
        model.settings.toneSettings = .standard
        await capture(
            StyleTabContent().padding(Theme.Space.xl).environment(model)
                .environment(\.installedApps, toneSnapshotApps)
                .environment(\.snapshotToneBoard, ToneBoardSnapshot(hoveredLane: .professional)),
            name: "tones-v2-lane-hover", scheme: scheme, size: CGSize(width: 760 + Theme.Space.xl * 2, height: 400),
            directory: directory)
    }
}
