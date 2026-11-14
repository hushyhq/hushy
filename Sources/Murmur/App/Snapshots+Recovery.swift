import MurmurCore
import SwiftUI

/// The recovery states (`rec-*`, light and dark): a dictation that was not pasted, or produced no
/// text, never leaves a person without their words or a next step.
///
/// `rec-card-*` is the not-pasted card with every word (a long dictation scrolls; the snapshot
/// shows the top of it, since `ImageRenderer` draws nothing inside a scroll view), `rec-held` the
/// password row with its History button, `rec-failure-*` the failures that stay, with and without
/// kept audio (`rec-failure-quiet-mic-*` and `rec-failure-mic-switched` are the quiet-microphone row), `rec-anchor-<edge>-*` the two tallest and widest on the mock display, and
/// `rec-sheet` all of them on one page. `HUSHY_SNAPSHOT_ONLY=rec-` renders just these.
extension Snapshots {
    private static let recoveryShort = "Remind me to send Dana the pricing page before Friday."
    /// Invented, 138 words: several times what the card used to cut to three lines.
    private static let recoveryLong = "Thanks for sending the draft over. I read it on the train this morning and I think "
        + "the opening is strong, but the middle section spends too long on the history of the harbour before it gets to "
        + "the ferry timetable, which is the part people actually came for. Could we move the timetable up to the second "
        + "paragraph, keep one short line about the amber lamp at the end of the pier, and cut the story about the old "
        + "lighthouse keeper down to a sentence or two? I would also change the title, because nine words is a lot for a "
        + "sign that people read from a moving bus. If you agree I can make those changes tonight and send it back "
        + "before the meeting on Thursday, so Priya has a day to look at the photographs."
    /// Five lines: the longest a card shows without scrolling.
    private static let recoveryMedium = "I read the draft on the train this morning and I think the opening is strong, but "
        + "the middle spends too long on the history of the harbour before it gets to the ferry timetable. Could we move "
        + "the timetable up, keep one line about the amber lamp, and cut the lighthouse story down to a sentence?"

    private struct RecoveryCase {
        let name: String
        let caption: String
        let pill: @MainActor () -> PillModel
        let height: CGFloat
    }

    private static func card(_ mode: NoFieldMode, _ text: String) -> @MainActor () -> PillModel {
        { recoveryPill { $0.present(.noField(mode), text: text) } }
    }

    private static func failure(_ failure: DictationFailure) -> @MainActor () -> PillModel {
        { recoveryPill { $0.present(failure: failure) } }
    }

    private static func recoveryPill(_ show: (PillModel) -> Void) -> PillModel {
        let pill = PillModel()
        pill.showWhenIdle = true
        show(pill)
        return pill
    }

    private static var recoveryCases: [RecoveryCase] {
        let tall: CGFloat = 270
        let hint = NoFieldCard.hintLineHeight
        return [
            RecoveryCase(name: "card-short", caption: "Not pasted, a short dictation: every word, and how to get it back later",
                         pill: card(.copiedAutomatically, recoveryShort), height: 170),
            RecoveryCase(name: "card-medium", caption: "Five lines: still drawn whole, nothing to scroll",
                         pill: card(.copiedAutomatically, recoveryMedium), height: 230),
            RecoveryCase(name: "card-long", caption: "A long dictation: the card scrolls and says how many words there are",
                         pill: card(.copiedAutomatically, recoveryLong), height: tall),
            RecoveryCase(name: "card-long-moved", caption: "Long, after switching apps",
                         pill: card(.notPasted(.targetChanged(.app)), recoveryLong), height: tall),
            RecoveryCase(name: "card-long-unconfirmed", caption: "Long, the paste could not be confirmed",
                         pill: card(.copiedAutomaticallyUnconfirmed, recoveryLong), height: tall + hint),
            RecoveryCase(name: "card-long-untouched", caption: "Long, clipboard left alone (not today's default)",
                         pill: card(.offerCopy, recoveryLong), height: tall),
            RecoveryCase(name: "card-plain", caption: "A paste that gave way, or paste last could not paste: Copy, clipboard untouched",
                         pill: card(.plainNotPasted, recoveryShort), height: 170),
            RecoveryCase(name: "card-plain-copied", caption: "Copy pressed on that card: closes after a moment",
                         pill: card(.plainNotPastedCopied, recoveryShort), height: 170),
            RecoveryCase(name: "held", caption: "A password field: no words, Copy, and History to read them",
                         pill: { recoveryPill { $0.present(.held(copied: false), text: recoveryShort) } }, height: 64),
            RecoveryCase(name: "failure-audio", caption: "Recognition failed, the audio is still held: Try again",
                         pill: failure(.transcription(recordingKept: true)), height: 64),
            RecoveryCase(name: "failure-no-audio", caption: "Recognition failed and there is no audio to run again",
                         pill: failure(.transcription(recordingKept: false)), height: 64),
            RecoveryCase(name: "failure-no-words", caption: "Recognition ran and found no words",
                         pill: failure(.noWords), height: 64),
            RecoveryCase(name: "failure-missed-words", caption: "Speech, but no words: one quiet line that leaves after 2 s, no ✕",
                         pill: failure(.missedWords(heardSpeech: true)), height: 64),
            RecoveryCase(name: "failure-missed-words-noise", caption: "A real hold the microphone heard, no speech: the same quiet line",
                         pill: failure(.missedWords(heardSpeech: false)), height: 64),
            RecoveryCase(name: "failure-nothing-to-write", caption: "Words were heard, cleanup left nothing",
                         pill: failure(.nothingToWrite), height: 64),
            RecoveryCase(name: "failure-heard-nothing", caption: "Sound, but no speech",
                         pill: failure(.heardNothing), height: 64),
            RecoveryCase(name: "failure-mic-silent", caption: "The microphone sent exact silence",
                         pill: failure(.micSilent), height: 64),
            RecoveryCase(name: "failure-headset-connecting", caption: "The key was released while the headset was still connecting",
                         pill: failure(.headsetConnecting), height: 64),
            RecoveryCase(name: "failure-quiet-mic-offer", caption: "Hardly any sound from a headset, the Mac's microphone is there: one tap to use it",
                         pill: failure(.quietMic(QuietMic(micName: "Dana's AirPods Pro", isSilent: false, betterInput: "MacBook Pro Microphone"))),
                         height: 64),
            RecoveryCase(name: "failure-quiet-mic-silent", caption: "No sound at all from a headset: the same offer",
                         pill: failure(.quietMic(QuietMic(micName: "Dana's AirPods Pro", isSilent: true, betterInput: "MacBook Pro Microphone",
                                                          headsetSilence: true))),
                         height: 64),
            RecoveryCase(name: "failure-quiet-mic-long-name", caption: "A long device name is cut in the middle",
                         pill: failure(.quietMic(QuietMic(micName: "Alexandria's Example Buds Pro Max (2nd generation)", isSilent: false,
                                                          betterInput: "MacBook Pro Microphone"))),
                         height: 64),
            RecoveryCase(name: "failure-quiet-mic-check", caption: "Hardly any sound on the Mac's own microphone: nothing better to offer",
                         pill: failure(.quietMic(QuietMic(micName: "MacBook Pro Microphone", isSilent: false, betterInput: nil))), height: 64),
            RecoveryCase(name: "failure-mic-switched", caption: "After Use Mac mic: which microphone is in use now",
                         pill: failure(.micSwitched(to: "MacBook Pro Microphone")), height: 64),
            RecoveryCase(name: "failure-quiet-mic-automatic", caption: "A picked microphone sent no sound and the Mac's sound input is another one: one tap back to Automatic",
                         pill: failure(.quietMic(QuietMic(micName: "MacBook Pro Microphone", isSilent: true, betterInput: nil,
                                                          offersAutomatic: true))), height: 64),
            RecoveryCase(name: "failure-pick-undone", caption: "The microphone taken from the offer sent no sound either: Hushy put the setting back",
                         pill: failure(.pickUndone(mic: "MacBook Pro Microphone", backTo: nil)), height: 64),
            RecoveryCase(name: "failure-mic-unreadable", caption: "A picked microphone's audio could not be read: nothing was recognised, one tap back",
                         pill: failure(.micUnreadable(mic: "MacBook Pro Microphone", next: .offerAutomatic)), height: 64),
            RecoveryCase(name: "failure-using-automatic", caption: "After Use Automatic",
                         pill: failure(.usingAutomatic), height: 64),
            RecoveryCase(name: "failure-mic-start", caption: "The microphone did not start",
                         pill: failure(.didNotStart(PillModel.microphoneFailedMessage)), height: 64),
            RecoveryCase(name: "failure-mic-access", caption: "No microphone access",
                         pill: failure(.didNotStart("Microphone access needed")), height: 64),
        ]
    }

    static func renderRecovery(scheme: ColorScheme, directory: URL) async {
        let cases = recoveryCases
        for item in cases {
            await capture(
                PillView(model: item.pill()).frame(height: item.height)
                    .padding(.vertical, 28).background(Theme.bgSunken).environment(\.colorScheme, scheme),
                name: "rec-\(item.name)", scheme: scheme, size: CGSize(width: 600, height: item.height + 56),
                directory: directory, fixedSize: true)
        }
        // On the mock display at every edge: the tallest card and the widest row stay inside their panels.
        for anchor in [PillAnchor.bottom, .top, .left, .right] {
            let placed: [(String, PillModel)] = [
                ("card-long", card(.copiedAutomaticallyUnconfirmed, recoveryLong)()),
                ("failure-audio", failure(.transcription(recordingKept: true))()),
            ]
            for (name, pill) in placed {
                await capture(anchoredPill(pill, at: anchor).environment(\.colorScheme, scheme),
                              name: "rec-anchor-\(anchor.rawValue)-\(name)", scheme: scheme,
                              size: mockDisplay.size, directory: directory, fixedSize: true)
            }
        }
        let sheet = VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(cases.enumerated()), id: \.offset) { _, item in
                HStack(alignment: .bottom, spacing: 16) {
                    Text(item.caption)
                        .font(Theme.Font.caption).foregroundStyle(Theme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(width: 230, alignment: .leading)
                        .padding(.bottom, 8)
                    PillView(model: item.pill()).frame(width: 540, height: item.height)
                }
                .padding(.vertical, 10)
                Divider().opacity(0.4)
            }
        }
        .padding(24)
        .background(Theme.bgSunken)
        .environment(\.colorScheme, scheme)
        let height = cases.reduce(CGFloat(48)) { $0 + $1.height + 21 }
        await capture(sheet, name: "rec-sheet", scheme: scheme, size: CGSize(width: 850, height: height),
                      directory: directory, fixedSize: true)
    }
}
