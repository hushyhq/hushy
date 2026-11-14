import Testing
@testable import MurmurCore

@Suite("FnCaptureDecider")
struct FnCaptureDeciderTests {
    typealias Action = FnCaptureDecider.Action

    // MARK: Solo press / hold (the core problem this feature fixes)

    @Test("solo tap: down then up with no other key are both swallowed")
    func soloTap() {
        var state = FnCaptureDecider.State()
        #expect(state.fnDown() == .swallow)
        #expect(state.fnUp() == .swallow)
    }

    @Test("solo long hold behaves the same as a quick tap: still fully swallowed")
    func soloHold() {
        var state = FnCaptureDecider.State()
        #expect(state.fnDown() == .swallow)
        // No interrupting key at all while held, however long.
        #expect(state.fnUp() == .swallow)
    }

    @Test("double-tap (two solo presses in a row) swallows every down/up")
    func doubleTapSoloPresses() {
        var state = FnCaptureDecider.State()
        #expect(state.fnDown() == .swallow)
        #expect(state.fnUp() == .swallow)
        #expect(state.fnDown() == .swallow)
        #expect(state.fnUp() == .swallow)
    }

    // MARK: Combos: any other key while fn is held must be let through normally

    @Test("fn+arrow: other key press requests a repost, then fn-up passes through for real")
    func fnArrowCombo() {
        var state = FnCaptureDecider.State()
        #expect(state.fnDown() == .swallow)
        let needsRepost = state.otherKeyPressed()
        #expect(needsRepost) // caller must synthesize a fn-down before delivering the arrow keyDown
        #expect(state.fnUp() == .passRelease)
    }

    @Test("fn+F-key combo: same repost-then-real-release shape")
    func fnFKeyCombo() {
        var state = FnCaptureDecider.State()
        #expect(state.fnDown() == .swallow)
        let needsRepost = state.otherKeyPressed()
        #expect(needsRepost)
        #expect(state.fnUp() == .passRelease)
    }

    @Test("fn+Delete (forward delete) combo")
    func fnDeleteCombo() {
        var state = FnCaptureDecider.State()
        #expect(state.fnDown() == .swallow)
        let needsRepost = state.otherKeyPressed()
        #expect(needsRepost)
        #expect(state.fnUp() == .passRelease)
    }

    @Test("fn+E emoji picker combo")
    func fnEEmojiCombo() {
        var state = FnCaptureDecider.State()
        #expect(state.fnDown() == .swallow)
        let needsRepost = state.otherKeyPressed()
        #expect(needsRepost)
        #expect(state.fnUp() == .passRelease)
    }

    @Test("fn+Control voice-action chord is out of scope for this decider: repost still requested")
    func fnControlComboStillReposts() {
        // ActionHotkeyMonitor is fed by HotkeyMonitor's one event tap (`HotkeyMonitor.chord`),
        // which sees every flagsChanged before dictation decides anything — so this decider is
        // unaffected either way — but it must still treat Control like any other interrupting
        // key so fn isn't left swallowed.
        var state = FnCaptureDecider.State()
        #expect(state.fnDown() == .swallow)
        let needsRepost = state.otherKeyPressed()
        #expect(needsRepost)
        #expect(state.fnUp() == .passRelease)
    }

    @Test("multiple keys pressed during one hold only require one repost")
    func multipleKeysOneRepost() {
        var state = FnCaptureDecider.State()
        #expect(state.fnDown() == .swallow)
        let firstRepost = state.otherKeyPressed() // first arrow: needs repost
        #expect(firstRepost)
        let secondRepost = state.otherKeyPressed() // second arrow in the same hold: no further repost
        #expect(!secondRepost)
        let thirdRepost = state.otherKeyPressed()
        #expect(!thirdRepost)
        #expect(state.fnUp() == .passRelease)
    }

    @Test("combo then a fresh solo press after release starts clean and swallows again")
    func comboThenFreshSoloPress() {
        var state = FnCaptureDecider.State()
        #expect(state.fnDown() == .swallow)
        let needsRepost = state.otherKeyPressed()
        #expect(needsRepost)
        #expect(state.fnUp() == .passRelease)

        // A brand-new press afterwards is unrelated and must go back to swallowing solo.
        #expect(state.fnDown() == .swallow)
        #expect(state.fnUp() == .swallow)
    }

    @Test("combo immediately followed by another combo hold")
    func backToBackCombos() {
        var state = FnCaptureDecider.State()
        #expect(state.fnDown() == .swallow)
        let firstRepost = state.otherKeyPressed()
        #expect(firstRepost)
        #expect(state.fnUp() == .passRelease)

        #expect(state.fnDown() == .swallow)
        let secondRepost = state.otherKeyPressed()
        #expect(secondRepost)
        #expect(state.fnUp() == .passRelease)
    }

    // MARK: Edge cases

    @Test("otherKeyPressed with fn not down never requests a repost")
    func otherKeyWithoutFnDown() {
        var state = FnCaptureDecider.State()
        let needsRepost = state.otherKeyPressed()
        #expect(!needsRepost)
        #expect(state.hold == .idle)
    }

    @Test("orphaned fn-up without a preceding down passes through rather than swallowing")
    func orphanedFnUp() {
        var state = FnCaptureDecider.State()
        #expect(state.fnUp() == .pass)
    }

    @Test("state resets to idle after a solo release")
    func stateResetsAfterSoloRelease() {
        var state = FnCaptureDecider.State()
        _ = state.fnDown()
        #expect(state.hold == .swallowingSolo)
        _ = state.fnUp()
        #expect(state.hold == .idle)
    }

    @Test("state resets to idle after a combo release")
    func stateResetsAfterComboRelease() {
        var state = FnCaptureDecider.State()
        _ = state.fnDown()
        _ = state.otherKeyPressed()
        #expect(state.hold == .comboActive)
        _ = state.fnUp()
        #expect(state.hold == .idle)
    }

    @Test("otherKeyPressed after combo already active during same hold doesn't regress state")
    func otherKeyDuringComboActiveStaysComboActive() {
        var state = FnCaptureDecider.State()
        _ = state.fnDown()
        _ = state.otherKeyPressed()
        #expect(state.hold == .comboActive)
        _ = state.otherKeyPressed()
        #expect(state.hold == .comboActive)
    }
}
