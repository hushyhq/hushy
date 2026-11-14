import SwiftUI

/// The relaunch prompt shown after an update downloads in the background (`update-ready-*`):
/// with release notes closed, with them open, and for an update whose notes are only a link.
/// Settings → About carries the "Install updates automatically" switch (`settings-about`).
/// The notes are invented. Each card is cut to the height of its content.
extension Snapshots {
    static func renderUpdateReady(scheme: ColorScheme, directory: URL) async {
        let notes = """
            - Dictation starts faster after you wake your Mac.
            - Fixed text landing in the wrong field in Slack.
            - The pill is calmer while the model loads.
            """
        let cases: [(String, UpdateReadyPrompt, Bool)] = [
            ("closed", UpdateReadyPrompt(notes: .text(notes)), false),
            ("notes", UpdateReadyPrompt(notes: .text(notes)), true),
            ("link", UpdateReadyPrompt(notes: .link(URL(string: "https://tryhushy.com/notes")!)), false),
            ("no-notes", UpdateReadyPrompt(notes: .none), false),
        ]
        for (name, prompt, expanded) in cases {
            let card = UpdateReadyView(prompt: prompt, startsExpanded: expanded, onRelaunch: {}, onLater: {})
                .padding(Theme.Space.xl)
                .background(Theme.bgSunken)
            await capture(
                card, name: "update-ready-\(name)", scheme: scheme,
                size: CGSize(width: UpdateReadyView.width + Theme.Space.xl * 2, height: expanded ? 240 : 176),
                directory: directory, fixedSize: true)
        }
    }
}
