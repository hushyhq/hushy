import Foundation
import Testing
@testable import MurmurCore

@Suite("The capture log names the microphone")
struct InputDeviceInfoTests {
    /// Core Audio's transport codes are four ASCII characters packed into a number.
    private func code(_ text: String) -> UInt32 { InputTransport.fourCC(text) }

    @Test("a four-character code packs first character highest, as Core Audio stores it")
    func fourCharacterCode() {
        #expect(code("bltn") == 0x626C_746E)
        #expect(code("blue") == 0x626C_7565)
    }

    @Test("each Core Audio transport is one of the kinds the log names",
          arguments: [("bltn", InputTransport.builtIn), ("blue", .bluetooth), ("blea", .bluetooth), ("usb ", .usb),
                      ("virt", .virtual), ("grup", .aggregate), ("thun", .other), ("hdmi", .other), ("ccwl", .other)])
    func transports(text: String, expected: InputTransport) {
        #expect(InputTransport(coreAudioTransportType: code(text)) == expected)
    }

    @Test("an unknown transport is other, never a guess")
    func unknownTransport() {
        #expect(InputTransport(coreAudioTransportType: 0) == .other)
    }

    @Test("the line has the name, the transport, the sample rate and the channel count, and nothing else")
    func line() {
        let headset = InputDeviceInfo(name: "Example Buds Pro", transport: .bluetooth, sampleRate: 16_000, channels: 1)
        #expect(headset.logSummary == "\"Example Buds Pro\" · bluetooth · 16000 Hz · 1 ch")
        let mac = InputDeviceInfo(name: "MacBook Pro Microphone", transport: .builtIn, sampleRate: 48_000, channels: 1)
        #expect(mac.logSummary == "\"MacBook Pro Microphone\" · built-in · 48000 Hz · 1 ch")
        let usb = InputDeviceInfo(name: "Desk Mic", transport: .usb, sampleRate: 44_100, channels: 2)
        #expect(usb.logSummary == "\"Desk Mic\" · usb · 44100 Hz · 2 ch")
    }

    @Test("a device that cannot be named still logs its format")
    func unknownDevice() {
        #expect(InputDeviceInfo.logSummary(name: nil, transport: nil, sampleRate: 48_000, channels: 1)
                == "unknown device · 48000 Hz · 1 ch")
    }

    @Test("a name from a driver is made safe for one line: no line breaks, no runs of spaces, a length limit")
    func cleanName() {
        #expect(InputDeviceInfo.cleanName("Example\nBuds\t  Pro ") == "Example Buds Pro")
        #expect(InputDeviceInfo.cleanName(String(repeating: "x", count: 200)).count == InputDeviceInfo.nameLimit)
        #expect(InputDeviceInfo(name: "A\u{0}B", transport: .usb, sampleRate: 48_000, channels: 1).name == "A B")
        #expect(InputDeviceInfo.cleanName("Zoë’s Buds") == "Zoë’s Buds", "letters outside ASCII are kept")
    }
}
