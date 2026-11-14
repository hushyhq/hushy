import Foundation
import MurmurCore
import Testing
@testable import Murmur

/// The saved per-display anchor, and the one-time migration from the old free-form position.
@Suite("Pill anchor store — per-display anchors, legacy migration")
struct PillAnchorStoreTests {
    private func defaults() -> UserDefaults {
        let name = "app.hushy.tests.pillAnchors.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        return defaults
    }

    @Test("nothing saved: every display rests at the bottom and the pill follows the pointer")
    func empty() {
        let prefs = PillAnchorStore.load(from: defaults())
        #expect(prefs.anchor(forScreen: 1) == .bottom)
        #expect(prefs.screenID == nil)
    }

    @Test("a saved anchor round-trips")
    func roundTrip() {
        let store = defaults()
        var prefs = PillAnchorPrefs()
        prefs.set(.right, forScreen: 4)
        PillAnchorStore.save(prefs, to: store)
        #expect(PillAnchorStore.load(from: store) == prefs)
    }

    @Test("an old free-form position becomes the nearest anchor on its display, once")
    func migratesLegacyPlacement() throws {
        let store = defaults()
        let legacy = PillPlacement(screenID: 7, fractionX: 0.03, fractionY: 0.55)
        store.set(try JSONEncoder().encode(legacy), forKey: PillAnchorStore.legacyKey)
        let prefs = PillAnchorStore.load(from: store)
        #expect(prefs.anchor(forScreen: 7) == .left)
        #expect(prefs.screenID == 7)
        #expect(store.data(forKey: PillAnchorStore.legacyKey) == nil, "the old key is removed")
        #expect(PillAnchorStore.load(from: store) == prefs, "the migration is saved")
    }

    @Test("an unreadable old position is dropped, not guessed")
    func corruptLegacy() {
        let store = defaults()
        store.set(Data("nope".utf8), forKey: PillAnchorStore.legacyKey)
        #expect(PillAnchorStore.load(from: store) == PillAnchorPrefs())
        #expect(store.data(forKey: PillAnchorStore.legacyKey) == nil)
    }
}
