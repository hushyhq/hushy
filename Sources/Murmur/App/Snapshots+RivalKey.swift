import SwiftUI

/// The card for a dictation key another app may share (`rival-key`), in the shipped placeholder
/// words, which name no app.
extension Snapshots {
    static func renderRivalKey(scheme: ColorScheme, directory: URL) async {
        let rivals = RivalDictationApps.table.filter { ["wispr-flow", "granola"].contains($0.id) }
        let offer = RivalKeyOffer(rivals: rivals, current: .fn, suggested: .rightOption)
        let card = RivalKeyView(offer: offer, onSwitch: {}, onKeep: {})
            .padding(Theme.Space.xl)
            .background(Theme.bgSunken)
        await capture(
            card, name: "rival-key", scheme: scheme,
            size: CGSize(width: RivalKeyView.width + Theme.Space.xl * 2, height: 220),
            directory: directory, fixedSize: true)
    }
}
