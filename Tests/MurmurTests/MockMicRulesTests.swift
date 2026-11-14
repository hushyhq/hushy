#if DEBUG
import Foundation
import Testing
@testable import Murmur

@Suite("Mock microphone: home and device rules")
struct MockMicRulesTests {
    private let real = URL(fileURLWithPath: "/Users/someone/Library/Application Support/Hushy", isDirectory: true)

    @Test("refuses when neither home variable is set")
    func noHome() {
        #expect(isRefused(MockMicHome.evaluate(environment: [:], realSupport: real)))
        #expect(isRefused(MockMicHome.evaluate(environment: ["HUSHY_HOME": ""], realSupport: real)))
    }

    @Test("refuses the real support folder, a folder inside it, and one that contains it")
    func realFolder() {
        for path in [real.path, real.path + "/", real.path + "/sub/dir", "/Users/someone/Library/Application Support",
                     "/Users/someone/Library", "/Users/someone", "/Users", "/"] {
            #expect(isRefused(MockMicHome.evaluate(environment: ["HUSHY_HOME": path], realSupport: real)), "\(path)")
        }
    }

    @Test("refuses when either variable points at the real folder, whichever one the app would read")
    func eitherVariable() {
        #expect(isRefused(MockMicHome.evaluate(
            environment: ["HUSHY_HOME": "/private/tmp/x", "MURMUR_HOME": real.path], realSupport: real)))
        #expect(isRefused(MockMicHome.evaluate(
            environment: ["MURMUR_HOME": "/private/tmp/../../Users/someone/Library/Application Support/Hushy"],
            realSupport: real)))
    }

    @Test("allows a disposable folder from either variable")
    func disposable() {
        #expect(MockMicHome.evaluate(environment: ["HUSHY_HOME": "/private/tmp/abc"], realSupport: real)
                == .allowed("/private/tmp/abc"))
        #expect(MockMicHome.evaluate(environment: ["MURMUR_HOME": "/var/folders/zz/T/def"], realSupport: real)
                == .allowed("/var/folders/zz/T/def"))
    }

    @Test("a sibling whose name only starts with the same letters is not the real folder")
    func siblingName() {
        let sibling = real.path + "-scratch"
        #expect(MockMicHome.evaluate(environment: ["HUSHY_HOME": sibling], realSupport: real) == .allowed(sibling))
    }

    private func device(_ name: String, virtual: Bool = true, channels: Int = 2, id: UInt32 = 1) -> MockMicDevice {
        MockMicDevice(id: id, name: name, isVirtual: virtual, inputChannels: channels)
    }

    @Test("uses BlackHole 2ch when it is present and virtual")
    func picksBlackHole() {
        let devices = [device("MacBook Pro Microphone", virtual: false, id: 1), device("BlackHole 2ch", id: 2)]
        #expect(MockMicDeviceRule.decide(devices) == .use(device("BlackHole 2ch", id: 2)))
    }

    @Test("skips, never falls back, when only physical microphones exist")
    func noBlackHole() {
        let decision = MockMicDeviceRule.decide([device("MacBook Pro Microphone", virtual: false), device("USB Mic", virtual: false)])
        guard case .skip(let reason) = decision else { Issue.record("expected skip"); return }
        #expect(reason.contains("BlackHole"))
        #expect(MockMicDeviceRule.decide([]) != .use(device("x")))
    }

    @Test("a device named like BlackHole but not virtual is not used")
    func impostor() {
        guard case .skip = MockMicDeviceRule.decide([device("BlackHole 2ch", virtual: false)]) else {
            Issue.record("a non-virtual device must not be used"); return
        }
    }

    @Test("a BlackHole with no input channels is not used")
    func noInput() {
        guard case .skip = MockMicDeviceRule.decide([device("BlackHole 2ch", channels: 0)]) else {
            Issue.record("a device with no input must not be used"); return
        }
    }

    @Test("another BlackHole variant is skipped because the player can only play into the 2ch one")
    func otherVariant() {
        guard case .skip(let reason) = MockMicDeviceRule.decide([device("BlackHole 16ch", channels: 16)]) else {
            Issue.record("expected skip"); return
        }
        #expect(reason.contains("2ch"))
    }

    @Test("exit codes are distinct, and only success is zero")
    func exitCodes() {
        let codes = [MockMicExit.ok, MockMicExit.failed, MockMicExit.usage, MockMicExit.refused, MockMicExit.blocked, MockMicExit.skipped]
        #expect(Set(codes).count == codes.count)
        #expect(MockMicExit.ok == 0)
        #expect(codes.dropFirst().allSatisfy { $0 != 0 })
    }

    private func isRefused(_ verdict: MockMicHome.Verdict) -> Bool {
        if case .refused = verdict { return true }
        return false
    }
}
#endif
