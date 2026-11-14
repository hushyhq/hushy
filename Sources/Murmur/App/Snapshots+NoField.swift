import MurmurCore
import SwiftUI

/// Founder review set for the no-field result card and copy-last (2026-10-05):
/// `nofield-<short|long|pressed|old|unconfirmed>` close up, `nofield-anchor-<edge>-short` on the mock display,
/// `nofield-copylast` (the pill's "Copied" after ⌃⌘C), `nofield-nothing` (the quiet "Nothing to
/// copy yet") and `nofield-shortcuts` (where the new shortcut is listed in Settings).
extension Snapshots {
    private static let noFieldShort = "Remind me to send Dana the pricing page before Friday."
    private static let noFieldLong = "So the plan for the launch is to move everything to the sixteenth, "
        + "which gives us time to finish the pricing page, run the voice actions eval one more time, "
        + "and get the new onboarding copy reviewed by Dana and the rest of the team before we "
        + "send anything to the people on the waiting list, and then we can talk about the rollout."

    static func renderNoField(scheme: ColorScheme, directory: URL) async {
        let cards: [(String, NoFieldMode, String)] = [
            ("short", .offerCopy, noFieldShort),
            ("long", .offerCopy, noFieldLong),
            ("pressed", .copied, noFieldShort),
            ("old", .copiedAutomatically, noFieldShort),
            ("moved", .notPasted(.targetChanged(.app)), noFieldShort),
            ("unconfirmed", .copiedAutomaticallyUnconfirmed, noFieldShort),
        ]
        for (name, mode, text) in cards {
            let pill = noFieldPill(.noField(mode), text: text)
            // A long dictation's card is taller: it shows six lines and scrolls the rest.
            await capture(closeUp(pill, scheme: scheme), name: "nofield-\(name)", scheme: scheme,
                          size: CGSize(width: 560, height: name == "long" ? 340 : 280), directory: directory, fixedSize: true)
        }
        for anchor in [PillAnchor.bottom, .left, .right] {
            let pill = noFieldPill(.noField(.offerCopy), text: noFieldShort)
            pill.anchor = anchor
            await capture(anchoredPill(pill, at: anchor).environment(\.colorScheme, scheme),
                          name: "nofield-anchor-\(anchor.rawValue)-short", scheme: scheme,
                          size: mockDisplay.size, directory: directory, fixedSize: true)
        }
        await capture(closeUp(noFieldPill(.held(copied: true), text: ""), scheme: scheme),
                      name: "nofield-copylast", scheme: scheme, size: CGSize(width: 560, height: 120),
                      directory: directory, fixedSize: true)
        for (name, state) in [("uncertain-unconfirmed", PillState.noField(.copiedAutomaticallyUnconfirmed)),
                              ("uncertain-confirmed", .done(words: 5))] {
            await capture(closeUp(noFieldPill(state, text: "Vela toggles the amber beacon."), scheme: scheme),
                          name: name, scheme: scheme, size: CGSize(width: 560, height: 280),
                          directory: directory, fixedSize: true)
        }
        await capture(closeUp(noFieldPill(.error(CopyLast.nothingMessage), text: ""), scheme: scheme),
                      name: "nofield-nothing", scheme: scheme, size: CGSize(width: 560, height: 120),
                      directory: directory, fixedSize: true)
        let shortcuts = SettingsGroup {
            SettingsRow(title: "Shortcuts", detail: ShortcutHelp.settingsLine(actionKey: .control)) { EmptyView() }
        }
        .padding(24)
        .background(Theme.bgBase)
        .environment(\.colorScheme, scheme)
        await capture(shortcuts, name: "nofield-shortcuts", scheme: scheme,
                      size: CGSize(width: 720, height: 140), directory: directory, fixedSize: true)
    }

    /// The founder's rule of 2026-10-10 (`np-*`, light and dark): a pasted dictation leaves no words
    /// on the pill; one that could not be pasted opens the pill to show them, says in the smallest
    /// way when they are already on the clipboard, and offers a copy. `np-sheet` is all of them on
    /// one page. `HUSHY_SNAPSHOT_ONLY=np-` renders just these.
    static func renderNotPasted(scheme: ColorScheme, directory: URL) async {
        let cases: [(name: String, caption: String, state: PillState, text: String, height: CGFloat)] = [
            ("pasted-short", "Pasted into a text box: a tick, no words", .done(words: 9), noFieldShort, 64),
            ("pasted-long", "Pasted, a long one: the count, no words", .done(words: 142), noFieldLong, 64),
            ("switched-apps-short", "Not pasted, you switched apps: the pill opens",
             .noField(.notPasted(.targetChanged(.app))), noFieldShort, 170),
            ("switched-apps-long", "Not pasted, a long dictation: every word, scrolling; Copy takes all of it",
             .noField(.notPasted(.targetChanged(.app))), noFieldLong, 260),
            ("paste-failed", "Not pasted, the app refused the paste", .noField(.notPasted(.pasteFailed)), noFieldShort, 170),
            ("copy-again-pressed", "Copy again pressed: closes after a moment",
             .noField(.notPastedCopiedAgain(.targetChanged(.app))), noFieldShort, 170),
            ("nofield-on-clipboard", "No text box, text already on the clipboard",
             .noField(.copiedAutomatically), noFieldShort, 170),
            ("nofield-on-clipboard-long", "No text box, a long dictation", .noField(.copiedAutomatically), noFieldLong, 260),
            ("nofield-clipboard-untouched", "No text box, clipboard left alone (today's default)",
             .noField(.offerCopy), noFieldShort, 170),
            ("unconfirmed", "The paste could not be confirmed: still on the clipboard, Copy again",
             .noField(.copiedAutomaticallyUnconfirmed), noFieldShort, 170 + NoFieldCard.hintLineHeight),
            ("unconfirmed-copy-again-pressed", "Unconfirmed, Copy again pressed: closes after a moment",
             .noField(.copiedUnconfirmed), noFieldShort, 170 + NoFieldCard.hintLineHeight),
        ]
        for item in cases {
            await capture(
                PillView(model: noFieldPill(item.state, text: item.text)).frame(height: item.height)
                    .padding(.vertical, 28).background(Theme.bgSunken).environment(\.colorScheme, scheme),
                name: "np-\(item.name)", scheme: scheme, size: CGSize(width: 560, height: item.height + 56),
                directory: directory, fixedSize: true)
        }
        let sheet = VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(cases.enumerated()), id: \.offset) { _, item in
                HStack(alignment: .bottom, spacing: 16) {
                    Text(item.caption)
                        .font(Theme.Font.caption).foregroundStyle(Theme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(width: 230, alignment: .leading)
                        .padding(.bottom, 8)
                    PillView(model: noFieldPill(item.state, text: item.text)).frame(width: 520, height: item.height)
                }
                .padding(.vertical, 10)
                Divider().opacity(0.4)
            }
        }
        .padding(24)
        .background(Theme.bgSunken)
        .environment(\.colorScheme, scheme)
        let height = cases.reduce(CGFloat(48)) { $0 + $1.height + 21 }
        await capture(sheet, name: "np-sheet", scheme: scheme, size: CGSize(width: 830, height: height),
                      directory: directory, fixedSize: true)
    }

    private static func noFieldPill(_ state: PillState, text: String) -> PillModel {
        let pill = PillModel()
        pill.showWhenIdle = true
        pill.present(state, text: text)
        return pill
    }

    private static func closeUp(_ pill: PillModel, scheme: ColorScheme) -> some View {
        PillView(model: pill)
            .padding(40)
            .background(Theme.bgSunken)
            .environment(\.colorScheme, scheme)
    }
}
