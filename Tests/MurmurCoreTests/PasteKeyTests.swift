import XCTest
@testable import MurmurCore

/// Which physical key Hushy presses with Command to paste. The key at QWERTY's V position is only
/// "v" on some layouts; on Dvorak it is "k", and Command with it pastes nothing.
final class PasteKeyTests: XCTestCase {
    /// A layout as two tables, physical key code → character: plain, and with Command held.
    private struct Layout {
        var plain: [UInt16: String]
        var command: [UInt16: String]?

        func translate(_ key: UInt16, _ withCommand: Bool) -> String? {
            withCommand ? (command ?? plain)[key] : plain[key]
        }
    }

    private let qwerty = Layout(plain: [9: "v", 40: "k", 47: ".", 11: "b"])
    /// Dvorak: the V position types "k"; "v" is where QWERTY has the full stop.
    private let dvorak = Layout(plain: [9: "k", 40: "t", 47: "v", 11: "x"])

    private func key(_ layout: Layout) -> UInt16 {
        PasteKey.keyCode(translate: layout.translate)
    }

    func testQwertyKeepsTheUsualKey() {
        XCTAssertEqual(key(qwerty), PasteKey.qwertyV)
        XCTAssertEqual(PasteKey.qwertyV, 9)
    }

    func testDvorakUsesTheKeyThatTypesV() {
        XCTAssertEqual(key(dvorak), 47)
    }

    func testALayoutThatSwitchesToQwertyWithCommandKeepsTheUsualKey() {
        // "Dvorak – QWERTY ⌘": Dvorak for typing, QWERTY positions while Command is held.
        let layout = Layout(plain: dvorak.plain, command: qwerty.plain)
        XCTAssertEqual(key(layout), PasteKey.qwertyV)
    }

    func testANonLatinLayoutWhoseCommandKeysAreLatinKeepsTheUsualKey() {
        let russian = Layout(plain: [9: "м", 40: "л", 47: "ю"], command: qwerty.plain)
        XCTAssertEqual(key(russian), PasteKey.qwertyV)
    }

    func testTheCommandTableWinsOverThePlainOne() {
        // Command moves "v" to key 30; plain typing has it on 47. The shortcut is what is pressed.
        let layout = Layout(plain: [9: "k", 47: "v"], command: [9: "k", 30: "v", 47: "z"])
        XCTAssertEqual(key(layout), 30)
    }

    func testAPlainVIsUsedWhenTheCommandTableHasNone() {
        let layout = Layout(plain: [9: "k", 47: "v"], command: [9: "k"])
        XCTAssertEqual(key(layout), 47)
    }

    func testAnUpperCaseVCounts() {
        XCTAssertEqual(key(Layout(plain: [9: "k", 47: "V"])), 47)
    }

    func testTheLowestKeyIsChosenWhenTwoTypeV() {
        XCTAssertEqual(key(Layout(plain: [9: "k", 47: "v", 60: "v"])), 47)
    }

    func testALayoutThatCannotBeReadFallsBackToTheUsualKey() {
        XCTAssertEqual(PasteKey.keyCode(translate: { _, _ in nil }), PasteKey.qwertyV)
    }

    func testALayoutWithNoVAtAllFallsBackToTheUsualKey() {
        XCTAssertEqual(key(Layout(plain: [9: "м", 47: "ю"])), PasteKey.qwertyV)
    }

    // MARK: More than one layout

    func testALayoutWithNoVHandsOverToTheLatinLayout() {
        // Typing in a layout with no Latin V at all, with Dvorak as the Latin layout: the system
        // reads shortcuts through the Latin one, so the key is Dvorak's.
        let noV = Layout(plain: [9: "м", 47: "ю"])
        XCTAssertEqual(PasteKey.keyCode(layouts: [noV.translate, dvorak.translate]), 47)
    }

    func testTheCurrentLayoutWinsWhenItHasAV() {
        XCTAssertEqual(PasteKey.keyCode(layouts: [qwerty.translate, dvorak.translate]), PasteKey.qwertyV)
        XCTAssertEqual(PasteKey.keyCode(layouts: [dvorak.translate, qwerty.translate]), 47)
    }

    func testNoLayoutWithAVOrNoLayoutAtAllIsTheUsualKey() {
        let noV = Layout(plain: [9: "м"])
        XCTAssertEqual(PasteKey.keyCode(layouts: [noV.translate, noV.translate]), PasteKey.qwertyV)
        XCTAssertEqual(PasteKey.keyCode(layouts: []), PasteKey.qwertyV)
    }

    func testALayoutIsFoundOrNot() {
        XCTAssertEqual(PasteKey.found(translate: dvorak.translate), 47)
        XCTAssertNil(PasteKey.found(translate: { _, _ in nil }))
    }

    // MARK: Kept until the layout changes

    func testTheKeyIsWorkedOutOncePerLayout() {
        var cache = PasteKeyCache()
        var lookups = 0
        let look: () -> UInt16 = { lookups += 1; return 47 }
        XCTAssertEqual(cache.key(forLayout: "dvorak", resolve: look), 47)
        XCTAssertEqual(cache.key(forLayout: "dvorak", resolve: look), 47)
        XCTAssertEqual(lookups, 1)
    }

    func testAChangedLayoutIsWorkedOutAgainAtTheNextPaste() {
        var cache = PasteKeyCache()
        XCTAssertEqual(cache.key(forLayout: "dvorak") { 47 }, 47)
        XCTAssertEqual(cache.key(forLayout: "us") { 9 }, 9, "no notification is needed for this")
        XCTAssertEqual(cache.key(forLayout: "dvorak") { 47 }, 47)
    }

    func testALayoutWhoseNameCannotBeReadIsStillKept() {
        var cache = PasteKeyCache()
        var lookups = 0
        XCTAssertEqual(cache.key(forLayout: nil) { lookups += 1; return 9 }, 9)
        XCTAssertEqual(cache.key(forLayout: nil) { lookups += 1; return 9 }, 9)
        XCTAssertEqual(lookups, 1)
        XCTAssertEqual(cache.key(forLayout: "us") { lookups += 1; return 9 }, 9)
        XCTAssertEqual(lookups, 2)
    }

    func testOnlyOrdinaryKeysAreAsked() {
        var asked: Set<UInt16> = []
        _ = PasteKey.keyCode(translate: { key, _ in asked.insert(key); return nil })
        XCTAssertEqual(asked, Set(0..<128))
    }

    func testAKeyThatTypesMoreThanVIsNotV() {
        XCTAssertEqual(key(Layout(plain: [9: "k", 47: "vv", 50: "v"])), 50)
    }
}
