import MurmurCore
import SwiftUI

/// The quiet row for a paste that was sent but could not be read back (`pu-*`, light and dark),
/// and what one click on it opens.
///
/// `pu-row` is the row, `pu-confirmed` the confirmed Done row in the same frame, and `pu-compare`
/// the two (and "Pasted · Return not pressed") one under the other with captions, so the grey tick
/// and the open control can be told from the lime tick at a glance. `pu-opened`, `pu-opened-long`
/// and `pu-opened-copied` are the card the click opens and its Copy again. `pu-anchor-<edge>-row`
/// is the row on the mock display at every edge (the control points where the card opens), and
/// `pu-sheet` is all of them on one page. `HUSHY_SNAPSHOT_ONLY=pu-` renders just these.
extension Snapshots {
    private static let uncheckedShort = "Vela toggles the amber beacon before the ferry leaves."
    /// Invented, long enough to scroll inside the card.
    private static let uncheckedLong = "I read the draft on the train this morning and I think the opening is strong, "
        + "but the middle spends too long on the history of the harbour before it gets to the ferry timetable, which is "
        + "the part people came for. Could we move the timetable up to the second paragraph, keep one short line about "
        + "the amber lamp at the end of the pier, and cut the story about the old lighthouse keeper down to a sentence "
        + "or two? I would also change the title, because nine words is a lot for a sign people read from a moving bus. "
        + "If you agree I can make those changes tonight and send it back before Thursday."

    private struct UncheckedCase {
        let name: String
        let caption: String
        let state: PillState
        let text: String
        let height: CGFloat
    }

    private static var uncheckedCases: [UncheckedCase] {
        [
            UncheckedCase(name: "row", caption: "Sent, could not be read back, nothing wrong seen: grey tick, one word, a control to open it",
                          state: .pastedUnchecked, text: uncheckedShort, height: 64),
            UncheckedCase(name: "confirmed", caption: "For comparison, a confirmed paste: the lime tick alone",
                          state: .done(words: 9), text: uncheckedShort, height: 64),
            UncheckedCase(name: "confirmed-return", caption: "For comparison, confirmed with Return withheld",
                          state: .done(words: 9, notSent: true), text: uncheckedShort, height: 64),
            UncheckedCase(name: "opened", caption: "One click on the row: the words, Copy again, and where the text is",
                          state: .noField(.copiedAutomaticallyUnconfirmed), text: uncheckedShort,
                          height: 170 + NoFieldCard.hintLineHeight),
            UncheckedCase(name: "opened-long", caption: "The same card for a long dictation",
                          state: .noField(.copiedAutomaticallyUnconfirmed), text: uncheckedLong,
                          height: 270 + NoFieldCard.hintLineHeight),
            UncheckedCase(name: "opened-copied", caption: "Copy again pressed: closes after a moment",
                          state: .noField(.copiedUnconfirmed), text: uncheckedShort,
                          height: 170 + NoFieldCard.hintLineHeight),
        ]
    }

    private static func uncheckedPill(_ item: UncheckedCase) -> PillModel {
        let pill = PillModel()
        pill.showWhenIdle = true
        pill.present(item.state, text: item.text)
        return pill
    }

    private static func captioned(_ items: [UncheckedCase], scheme: ColorScheme) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                HStack(alignment: .bottom, spacing: 16) {
                    Text(item.caption)
                        .font(Theme.Font.caption).foregroundStyle(Theme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(width: 230, alignment: .leading)
                        .padding(.bottom, 8)
                    PillView(model: uncheckedPill(item)).frame(width: 540, height: item.height)
                }
                .padding(.vertical, 10)
                Divider().opacity(0.4)
            }
        }
        .padding(24)
        .background(Theme.bgSunken)
        .environment(\.colorScheme, scheme)
    }

    private static func sheetHeight(_ items: [UncheckedCase]) -> CGFloat {
        items.reduce(CGFloat(48)) { $0 + $1.height + 21 }
    }

    static func renderPastedUnchecked(scheme: ColorScheme, directory: URL) async {
        let cases = uncheckedCases
        for item in cases {
            await capture(
                PillView(model: uncheckedPill(item)).frame(height: item.height)
                    .padding(.vertical, 28).background(Theme.bgSunken).environment(\.colorScheme, scheme),
                name: "pu-\(item.name)", scheme: scheme, size: CGSize(width: 600, height: item.height + 56),
                directory: directory, fixedSize: true)
        }
        let compared = Array(cases.prefix(3))
        await capture(captioned(compared, scheme: scheme), name: "pu-compare", scheme: scheme,
                      size: CGSize(width: 850, height: sheetHeight(compared)), directory: directory, fixedSize: true)
        for anchor in [PillAnchor.bottom, .top, .left, .right] {
            await capture(anchoredPill(uncheckedPill(cases[0]), at: anchor).environment(\.colorScheme, scheme),
                          name: "pu-anchor-\(anchor.rawValue)-row", scheme: scheme,
                          size: mockDisplay.size, directory: directory, fixedSize: true)
        }
        await capture(captioned(cases, scheme: scheme), name: "pu-sheet", scheme: scheme,
                      size: CGSize(width: 850, height: sheetHeight(cases)), directory: directory, fixedSize: true)
    }
}
