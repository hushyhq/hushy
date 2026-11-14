import MurmurCore
import SwiftUI

/// Voice edit's pill states (`ve-*`, light and dark): the wait while the selection is rewritten, the
/// edited row with ✕ (put it back, esc) and ✓, the undo states, and each line that says why the
/// selection was left alone. `ve-done` is a plain dictation's Done for size, and `ve-sheet` all of
/// them with captions. `HUSHY_SNAPSHOT_ONLY=ve-` renders just these.
extension Snapshots {
    private struct VoiceEditCase {
        let name: String
        let caption: String
        let state: PillState
    }

    private static var voiceEditCases: [VoiceEditCase] {
        [
            VoiceEditCase(name: "listening", caption: "Text selected, key down: \"make this shorter\"", state: .listening),
            VoiceEditCase(name: "working", caption: "Key up: the selection is being rewritten",
                          state: .processing(modeName: VoiceEditController.processingName)),
            VoiceEditCase(name: "edited", caption: "Replaced in place. ✕ or esc puts it back, ✓ keeps it",
                          state: .voiceEdit(.edited(canUndo: true))),
            VoiceEditCase(name: "edited-settled", caption: "After the undo window: the tick alone", state: .voiceEdit(.edited(canUndo: false))),
            VoiceEditCase(name: "undoing", caption: "Putting the original back", state: .voiceEdit(.undoing)),
            VoiceEditCase(name: "undone", caption: "The original is back", state: .voiceEdit(.undone)),
            VoiceEditCase(name: "undo-failed", caption: "The field moved on: Hushy does not guess",
                          state: .voiceEdit(.undoFailed("Couldn't put it back · use ⌘Z there"))),
            VoiceEditCase(name: "cannot", caption: "Asked for something the text does not have",
                          state: .voiceEdit(.declined(.cannotDo))),
            VoiceEditCase(name: "meaning", caption: "The rewrite changed a number, a name or a \"not\"",
                          state: .voiceEdit(.declined(.wouldChangeMeaning))),
            VoiceEditCase(name: "unchanged", caption: "Nothing needed changing", state: .voiceEdit(.declined(.unchanged))),
            VoiceEditCase(name: "no-answer", caption: "The model did not answer in time", state: .voiceEdit(.declined(.noAnswer))),
            VoiceEditCase(name: "copied-instead", caption: "The selection changed before the paste: the edit is on the clipboard",
                          state: .voiceEdit(.copiedInstead)),
            VoiceEditCase(name: "done", caption: "For size: a plain dictation's Done", state: .done(words: 9)),
        ]
    }

    private static func voiceEditPill(_ state: PillState) -> PillModel {
        let pill = PillModel()
        pill.showWhenIdle = true
        if state == .listening {
            pill.setLevels([0.2, 0.45, 0.7, 0.55, 0.85, 0.6, 0.4, 0.3, 0.2], peaks: [0.3, 0.5, 0.8, 0.6, 0.9, 0.7, 0.5, 0.4, 0.3])
        }
        pill.state = state
        return pill
    }

    static func renderVoiceEdit(scheme: ColorScheme, directory: URL) async {
        let cases = voiceEditCases
        for item in cases {
            await capture(
                PillView(model: voiceEditPill(item.state)).frame(height: 64)
                    .padding(.vertical, 28).background(Theme.bgSunken).environment(\.colorScheme, scheme),
                name: "ve-\(item.name)", scheme: scheme, size: CGSize(width: 600, height: 120),
                directory: directory, fixedSize: true)
        }
        let sheet = VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(cases.enumerated()), id: \.offset) { _, item in
                HStack(alignment: .center, spacing: 16) {
                    Text(item.caption)
                        .font(Theme.Font.caption).foregroundStyle(Theme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(width: 230, alignment: .leading)
                    PillView(model: voiceEditPill(item.state)).frame(width: 540, height: 64)
                }
                .padding(.vertical, 10)
                Divider().opacity(0.4)
            }
        }
        .padding(24)
        .background(Theme.bgSunken)
        .environment(\.colorScheme, scheme)
        await capture(sheet, name: "ve-sheet", scheme: scheme,
                      size: CGSize(width: 850, height: CGFloat(cases.count) * 85 + 48), directory: directory, fixedSize: true)
    }
}
