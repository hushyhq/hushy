import MurmurCore
import SwiftUI

/// Every pill row on one centre line (`pc-*`, light and dark): the resting pill, the loading row,
/// the failure rows, the done rows, the copied and held rows, an action row and a card, each in
/// the panel it really gets at the bottom edge (`PillPanel.frameSize`, dashed) with the display's
/// centre drawn through it. `pc-sheet` is all of them on one page; `pc-failures` is the failure
/// rows alone, larger, for reading their text and close button. `HUSHY_SNAPSHOT_ONLY=pc-` renders
/// just these. Invented text only.
extension Snapshots {
    private static let centringWords = "Vela toggles the amber beacon before the ferry leaves."

    struct CentringCase {
        let name: String
        let caption: String
        let pill: @MainActor () -> PillModel
    }

    private static func centringPill(_ state: PillState, text: String = "") -> PillModel {
        let pill = PillModel()
        pill.showWhenIdle = true
        if case .failed(let failure) = state {
            // "Try again" needs something to call; in a still it does nothing.
            let nothing: @MainActor () -> Void = {}
            pill.present(failure: failure, retry: failure.canRetry ? nothing : nil)
        } else {
            pill.present(state, text: text)
        }
        return pill
    }

    private static var centringFailures: [CentringCase] {
        [
            CentringCase(name: "fail-no-words", caption: "Recognition returned no words") { centringPill(.failed(.noWords)) },
            CentringCase(name: "fail-nothing-to-write", caption: "Cleanup left nothing to write") { centringPill(.failed(.nothingToWrite)) },
            CentringCase(name: "fail-heard-nothing", caption: "No speech in the recording") { centringPill(.failed(.heardNothing)) },
            CentringCase(name: "fail-mic-silent", caption: "The microphone sent exact silence") { centringPill(.failed(.micSilent)) },
            CentringCase(name: "fail-headset-connecting", caption: "Released while the headset was connecting") {
                centringPill(.failed(.headsetConnecting))
            },
            CentringCase(name: "fail-transcribe-kept", caption: "Recognition failed, audio kept: Try again") {
                centringPill(.failed(.transcription(recordingKept: true)))
            },
            CentringCase(name: "fail-transcribe-gone", caption: "Recognition failed, audio no longer kept") {
                centringPill(.failed(.transcription(recordingKept: false)))
            },
        ]
    }

    private static var centringCases: [CentringCase] {
        let chip = DoneChipState(title: "Added: Call Dana", detail: "Fri 9:00 AM", kind: .createReminder, undoRecordID: 1)
        return [
            CentringCase(name: "rest", caption: "At rest") { centringPill(.idle) },
            CentringCase(name: "loading", caption: "The key pressed while the speech model is still loading") {
                centringPill(.error(SpeechModelStatus.loadingLine))
            },
        ] + centringFailures + [
            CentringCase(name: "done", caption: "Pasted") { centringPill(.done(words: 9)) },
            CentringCase(name: "done-as-heard", caption: "Pasted as heard") { centringPill(.done(words: 142, asHeard: true)) },
            CentringCase(name: "done-return", caption: "Pasted, Return withheld") { centringPill(.done(words: 9, notSent: true)) },
            CentringCase(name: "unchecked", caption: "Pasted, field not readable") { centringPill(.pastedUnchecked, text: centringWords) },
            CentringCase(name: "copied", caption: "Copied: focus moved to another field") { centringPill(.copied(reason: .targetChanged(.field))) },
            CentringCase(name: "held", caption: "A password field") { centringPill(.held(copied: false), text: centringWords) },
            CentringCase(name: "action-done", caption: "A voice action, done") { centringPill(.actionDone(chip)) },
            CentringCase(name: "not-pasted", caption: "Not pasted: the card and its capsule share one left edge, centred together") {
                centringPill(.noField(.notPasted(.targetChanged(.app))), text: centringWords)
            },
        ]
    }

    /// One row in its real bottom-edge panel, with the display's centre drawn through it.
    static func centringStrip(_ item: CentringCase, width: CGFloat, scale: CGFloat = 1) -> some View {
        let pill = item.pill()
        let panel = PillPanel.frameSize(for: pill.state, anchor: .bottom)
        return ZStack(alignment: .bottom) {
            PillView(model: pill)
                .frame(width: panel.width, height: panel.height)
                .overlay(Rectangle().strokeBorder(Theme.textTertiary.opacity(0.35), style: StrokeStyle(lineWidth: 1, dash: [4, 4])))
            Rectangle().fill(Theme.phosphor.opacity(0.55)).frame(width: 1)
        }
        .scaleEffect(scale, anchor: .bottom)
        .frame(width: width, height: panel.height * scale + 12, alignment: .bottom)
    }

    static func centringSheet(_ items: [CentringCase], scheme: ColorScheme, scale: CGFloat = 1) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                HStack(alignment: .bottom, spacing: 12) {
                    Text(item.caption)
                        .font(Theme.Font.caption).foregroundStyle(Theme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(width: 200, alignment: .leading)
                        .padding(.bottom, 10)
                    centringStrip(item, width: PillPanel.centredWidth * scale + 40, scale: scale)
                }
                Divider().opacity(0.4)
            }
        }
        .padding(20)
        .background(Theme.bgSunken)
        .environment(\.colorScheme, scheme)
    }

    static func centringHeight(_ items: [CentringCase], scale: CGFloat = 1) -> CGFloat {
        items.reduce(CGFloat(40)) { $0 + PillPanel.frameSize(for: $1.pill().state, anchor: .bottom).height * scale + 13 }
    }

    static func renderPillCentring(scheme: ColorScheme, directory: URL) async {
        let cases = centringCases
        for item in cases {
            let height = PillPanel.frameSize(for: item.pill().state, anchor: .bottom).height + 12
            await capture(
                centringStrip(item, width: PillPanel.centredWidth + 40).background(Theme.bgSunken).environment(\.colorScheme, scheme),
                name: "pc-\(item.name)", scheme: scheme, size: CGSize(width: PillPanel.centredWidth + 40, height: height),
                directory: directory, fixedSize: true)
        }
        await capture(centringSheet(cases, scheme: scheme), name: "pc-sheet", scheme: scheme,
                      size: CGSize(width: 200 + 12 + PillPanel.centredWidth + 40 + 40, height: centringHeight(cases)),
                      directory: directory, fixedSize: true)
        // The failure rows at twice the size, to read every word and see the ✕ inside the capsule.
        let failures = centringFailures
        await capture(centringSheet(failures, scheme: scheme, scale: 2), name: "pc-failures", scheme: scheme,
                      size: CGSize(width: 200 + 12 + PillPanel.centredWidth * 2 + 40 + 40, height: centringHeight(failures, scale: 2)),
                      directory: directory, fixedSize: true)
    }
}
