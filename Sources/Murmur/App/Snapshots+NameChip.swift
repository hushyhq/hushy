import MurmurCore
import SwiftUI

/// The pill's name offer (`nc-*`, light and dark), each state in the panel it really gets at the
/// bottom edge with the display's centre drawn through it, at twice the size so every word can
/// be read: Done with no offer (for comparison), the offer, the offer under a long dictation's
/// word count, the row opened for its spelling, the spelling corrected, and the word added.
/// `nc-sheet` is all of them in the order a person meets them. `HUSHY_SNAPSHOT_ONLY=nc-` renders
/// just these. The name is invented.
extension Snapshots {
    private static let offeredName = "Pria"

    private static func namePill(words: Int = 6, _ then: @MainActor (PillModel) -> Void = { _ in }) -> PillModel {
        let pill = PillModel()
        pill.showWhenIdle = true
        pill.present(nameOffer: offeredName, words: words, usedContext: false) { _ in }
        then(pill)
        return pill
    }

    private static var nameChipCases: [CentringCase] {
        [
            CentringCase(name: "done", caption: "Done with no offer: most dictations") {
                let pill = PillModel()
                pill.present(.done(words: 6), text: "")
                return pill
            },
            CentringCase(name: "offer", caption: "Done with an offer: a new name Hushy was unsure of") { namePill() },
            CentringCase(name: "offer-long", caption: "The same after a long dictation: the word count stays") { namePill(words: 142) },
            CentringCase(name: "open", caption: "The arrow: the row opens with the word in a field") {
                namePill { $0.openNameOffer() }
            },
            CentringCase(name: "open-corrected", caption: "The spelling corrected: what Hushy wrote is kept as heard") {
                namePill { pill in
                    pill.openNameOffer()
                    pill.nameOffer?.spelling = "Priya"
                }
            },
            CentringCase(name: "added", caption: "The tick: added, then the pill rests") {
                namePill { pill in
                    pill.openNameOffer()
                    pill.nameOffer?.spelling = "Priya"
                    pill.acceptNameOffer()
                }
            },
        ]
    }

    static func renderNameChip(scheme: ColorScheme, directory: URL) async {
        let cases = nameChipCases
        let scale: CGFloat = 2
        let width = PillPanel.centredWidth * scale + 40
        for item in cases {
            let height = PillPanel.frameSize(for: item.pill().state, anchor: .bottom).height * scale + 12
            await capture(
                centringStrip(item, width: width, scale: scale).background(Theme.bgSunken).environment(\.colorScheme, scheme),
                name: "nc-\(item.name)", scheme: scheme, size: CGSize(width: width, height: height),
                directory: directory, fixedSize: true)
        }
        await capture(centringSheet(cases, scheme: scheme, scale: scale), name: "nc-sheet", scheme: scheme,
                      size: CGSize(width: 200 + 12 + width + 40, height: centringHeight(cases, scale: scale)),
                      directory: directory, fixedSize: true)
    }
}
