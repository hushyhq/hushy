import Testing
@testable import MurmurCore

@Suite("Entitlements.voiceActions")
struct EntitlementsVoiceActionsTests {
    @Test("voice actions are free whether or not the DEBUG override is on")
    func freeEitherWay() {
        let original = Entitlements.debugUnlocked
        defer { Entitlements.debugUnlocked = original }
        Entitlements.debugUnlocked = true
        #expect(Entitlements.has(.voiceActions))
        Entitlements.debugUnlocked = false
        #expect(Entitlements.has(.voiceActions))
    }
}
