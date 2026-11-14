import Foundation
import Testing
@testable import MurmurCore

@Suite("Headset link hold: a key released while the headset was still connecting")
struct HeadsetLinkHoldTests {
    private func held(_ transport: InputTransport? = .bluetooth, recorded: Int, silence: Int?) -> Bool {
        HeadsetLinkHold.linkWasStillConnecting(
            transport: transport, recorded: .milliseconds(recorded), silenceBeforeSound: silence.map { .milliseconds($0) })
    }

    @Test("released before any sound arrived: nothing was heard yet")
    func releasedBeforeAnySound() {
        #expect(held(recorded: 900, silence: nil))
    }

    @Test("released a moment after the link came up: a fragment, not a dictation")
    func releasedJustAfterTheLink() {
        #expect(held(recorded: 1_300, silence: 1_100))
        #expect(held(recorded: 1_399, silence: 1_100))
    }

    @Test("sound for longer than a fragment after the link came up is a dictation")
    func soundAfterTheLinkIsADictation() {
        #expect(!held(recorded: 1_400, silence: 1_100))
        #expect(!held(recorded: 1_900, silence: 1_100), "the founder's shortest recording on a real headset")
    }

    @Test("a headset that was already live is not held, however short the recording")
    func liveHeadsetIsNotHeld() {
        #expect(!held(recorded: 250, silence: 0))
        #expect(!held(recorded: 250, silence: 100))
    }

    @Test("zeros for longer than a link takes to come up is a silent microphone, not a link")
    func longSilenceIsASilentMicrophone() {
        #expect(held(recorded: 1_800, silence: nil))
        #expect(!held(recorded: 1_900, silence: nil))
    }

    @Test("only a Bluetooth input has a link to wait for", arguments: [InputTransport.builtIn, .usb, .virtual, nil])
    func otherInputsAreNeverHeld(_ transport: InputTransport?) {
        #expect(!held(transport, recorded: 900, silence: nil))
        #expect(!held(transport, recorded: 1_300, silence: 1_100))
    }
}
