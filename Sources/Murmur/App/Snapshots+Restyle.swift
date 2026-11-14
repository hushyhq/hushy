import MurmurCore
import SwiftUI

/// Restyle selection (`rs-*`, light and dark): the Services submenu as a drawn mock (the real menu belongs to macOS and
/// to the app in front, so it cannot be rendered here), then the pill's states: tone chips, copy-only chips, the wait,
/// the replaced row, the copied row, and the lines that keep the text. `HUSHY_SNAPSHOT_ONLY=rs-` renders just these.
extension Snapshots {
    private struct RestyleCase {
        let name: String
        let caption: String
        let state: PillState
    }

    private static var restyleCases: [RestyleCase] {
        [
            RestyleCase(name: "chips", caption: "Shortcut pressed over editable text", state: .restyle(RestyleChooser())),
            RestyleCase(name: "chips-copy", caption: "Copy toggled on", state: .restyle(RestyleChooser(copy: true))),
            RestyleCase(name: "chips-readonly", caption: "Read-only selection: always copied",
                        state: .restyle(RestyleChooser(copyOnly: true))),
            RestyleCase(name: "working", caption: "A tone is picked", state: .processing(modeName: VoiceEditController.processingName)),
            RestyleCase(name: "replaced", caption: "Replaced in place, with undo", state: .voiceEdit(.edited(canUndo: true))),
            RestyleCase(name: "copied", caption: "Copied, selection untouched", state: .voiceEdit(.restyleCopied)),
            RestyleCase(name: "kept", caption: "The rewrite would change a number, a name or a \"not\"",
                        state: .voiceEdit(.declined(.wouldChangeMeaning))),
            RestyleCase(name: "none", caption: "Nothing selected", state: .voiceEdit(.restyleNote(RestyleCopy.nothingSelected))),
        ]
    }

    private static func restylePill(_ state: PillState) -> PillModel {
        let pill = PillModel()
        pill.showWhenIdle = true
        pill.state = state
        return pill
    }

    private struct ServicesMenuMock: View {
        var body: some View {
            VStack(alignment: .leading, spacing: 0) {
                Text("Mock of the Services submenu (macOS draws the real one)")
                    .font(Theme.Font.caption).foregroundStyle(Theme.textSecondary).padding(.bottom, 10)
                HStack(alignment: .top, spacing: 6) {
                    menu(["Search With Google", "Hushy  ▸"], highlighted: 1)
                    menu(RestyleService.allCases.map { RestyleCopy.serviceItem($0) }, highlighted: 0, separatorAfter: 2)
                }
            }
            .padding(20)
            .background(Theme.bgSunken)
        }

        private func menu(_ items: [String], highlighted: Int, separatorAfter: Int? = nil) -> some View {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(items.enumerated()), id: \.offset) { index, title in
                    Text(title).font(.system(size: 13))
                        .foregroundStyle(index == highlighted ? Color.white : Theme.textPrimary)
                        .padding(.horizontal, 12).padding(.vertical, 4)
                        .frame(width: 200, alignment: .leading)
                        .background(RoundedRectangle(cornerRadius: 4).fill(index == highlighted ? Color.accentColor : .clear))
                    if separatorAfter == index { Divider().padding(.vertical, 3) }
                }
            }
            .padding(6)
            .background(RoundedRectangle(cornerRadius: 8).fill(.regularMaterial))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.primary.opacity(0.15)))
        }
    }

    static func renderRestyle(scheme: ColorScheme, directory: URL) async {
        await capture(ServicesMenuMock().environment(\.colorScheme, scheme), name: "rs-services-menu", scheme: scheme,
                      size: CGSize(width: 520, height: 200), directory: directory, fixedSize: true)
        let cases = restyleCases
        for item in cases {
            await capture(
                PillView(model: restylePill(item.state)).frame(height: 64)
                    .padding(.vertical, 28).background(Theme.bgSunken).environment(\.colorScheme, scheme),
                name: "rs-\(item.name)", scheme: scheme, size: CGSize(width: 600, height: 120),
                directory: directory, fixedSize: true)
        }
    }
}
