import MurmurCore
import SwiftUI

/// The "Did you mean…" card for a spoken app name with no sure match: three close apps stacked
/// (`pill-appChoice-three`), and the single closest one on the pill itself (`pill-appChoice-one`).
extension Snapshots {
    static func renderAppChoice(scheme: ColorScheme, directory: URL) async {
        let cards: [(String, ActionConfirmationCardState)] = [
            ("pill-appChoice-three", ActionConfirmationCardState(
                choosingAmong: ["Slack", "Flush", "Notion"], heard: "flask", sourceText: "open flask")),
            ("pill-appChoice-one", ActionConfirmationCardState(
                choosingAmong: ["Wendy"], heard: "wen", sourceText: "open wen")),
        ]
        for (name, card) in cards {
            let pill = PillModel()
            pill.state = .actionConfirm(card)
            let view = PillView(model: pill)
                .padding(40)
                .background(Theme.bgSunken)
                .environment(\.colorScheme, scheme)
            await capture(view, name: name, scheme: scheme, size: CGSize(width: 560, height: 360),
                          directory: directory, fixedSize: true)
        }
    }
}
