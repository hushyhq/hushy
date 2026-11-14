import Foundation
@testable import Murmur
import MurmurCore
import Testing

@MainActor
@Suite("Voice edit pill")
struct VoiceEditPillTests {
    @Test("esc puts the selection back while Undo is offered, and is the app's after")
    func escUndoes() {
        let pill = PillModel()
        var undone = 0
        pill.onVoiceEditUndo = { undone += 1 }
        pill.state = .voiceEdit(.edited(canUndo: true))
        #expect(pill.keyScope(now: Date(), ownTextFieldFocused: false) == .dismiss)
        pill.answer(.dismiss)
        #expect(undone == 1)
        pill.state = .voiceEdit(.edited(canUndo: false))
        #expect(pill.keyScope(now: Date(), ownTextFieldFocused: false) == .none)
        pill.state = .voiceEdit(.declined(.cannotDo))
        #expect(pill.keyScope(now: Date(), ownTextFieldFocused: false) == .none)
    }

    @Test("every voice-edit row clears itself and is the dictation pill's size")
    func rowLifetimes() {
        let chips: [VoiceEditChip] = [.edited(canUndo: true), .edited(canUndo: false), .undoing, .undone,
                                      .undoFailed("x"), .declined(.noAnswer)]
        for chip in chips {
            #expect(PillState.voiceEdit(chip).selfDismissDelay != nil)
            #expect(PillPanel.size(for: .voiceEdit(chip)) == PillPanel.size(for: .actionDone(DoneChipState(title: "x", kind: .openLink))))
        }
        #expect(PillState.voiceEdit(.edited(canUndo: true)).isInteractive)
        #expect(!PillState.voiceEdit(.declined(.cannotDo)).isInteractive)
    }

    @Test("a decline says the text was kept")
    func declineLines() {
        for why in VoiceEditDecline.allCases where why != .unchanged {
            #expect(why.line.contains("text kept"))
        }
    }
}
