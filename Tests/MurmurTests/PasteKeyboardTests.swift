import AppKit
import Carbon.HIToolbox
import MurmurCore
import Testing
@testable import Murmur

/// The paste key on real keyboard layouts, read from the layouts macOS ships (never selected, so
/// nothing about this Mac's keyboard changes), and the paster pressing the key it is given.
/// Whether an app on a Mac set to Dvorak then pastes needs a person with that layout.
@MainActor
@Suite("Paste key — the key the keyboard layout maps to V", .serialized)
struct PasteKeyboardTests {
    /// The layout with this input source ID, whether or not it is enabled on this Mac.
    private func layout(_ id: String) -> TISInputSource? {
        let filter = [kTISPropertyInputSourceID as String: id] as CFDictionary
        let sources = TISCreateInputSourceList(filter, true)?.takeRetainedValue() as? [TISInputSource]
        return sources?.first
    }

    @Test("a layout macOS ships resolves to the key that is V with Command held",
          arguments: [
              ("com.apple.keylayout.US", UInt16(kVK_ANSI_V)),
              ("com.apple.keylayout.British", UInt16(kVK_ANSI_V)),
              ("com.apple.keylayout.French", UInt16(kVK_ANSI_V)),
              ("com.apple.keylayout.German", UInt16(kVK_ANSI_V)),
              ("com.apple.keylayout.Colemak", UInt16(kVK_ANSI_V)),
              ("com.apple.keylayout.Russian", UInt16(kVK_ANSI_V)),
              ("com.apple.keylayout.Dvorak", UInt16(kVK_ANSI_Period)),
              ("com.apple.keylayout.DVORAK-QWERTYCMD", UInt16(kVK_ANSI_V)),
          ])
    func shippedLayouts(id: String, expected: UInt16) throws {
        let source = try #require(layout(id), "macOS no longer ships \(id)")
        #expect(PasteKeyboard.resolve(current: source) == CGKeyCode(expected))
    }

    @Test("a layout that cannot be read hands over to the Latin layout")
    func latinLayoutIsTheSecondChoice() throws {
        let dvorak = try #require(layout("com.apple.keylayout.Dvorak"))
        #expect(PasteKeyboard.resolve(current: nil, latin: dvorak) == CGKeyCode(kVK_ANSI_Period))
        #expect(PasteKeyboard.resolve(current: nil, latin: nil) == CGKeyCode(kVK_ANSI_V))
    }

    @Test("Russian has Latin Command keys of its own, so its key wins over the Latin layout's")
    func currentLayoutWinsWhenItHasAV() throws {
        let russian = try #require(layout("com.apple.keylayout.Russian"))
        let dvorak = try #require(layout("com.apple.keylayout.Dvorak"))
        #expect(PasteKeyboard.resolve(current: russian, latin: dvorak) == CGKeyCode(kVK_ANSI_V))
        #expect(PasteKeyboard.resolve(current: dvorak, latin: russian) == CGKeyCode(kVK_ANSI_Period))
    }

    @Test("a layout has an identifier, which is what the paste asks for each time")
    func identifiers() throws {
        let dvorak = try #require(layout("com.apple.keylayout.Dvorak"))
        #expect(PasteKeyboard.identifier(dvorak) == "com.apple.keylayout.Dvorak")
    }

    @Test("what a paste pays: asking which layout is in use, and (once per layout) working the key out")
    func cost() {
        let clock = ContinuousClock()
        let asks = 500
        let asking = clock.measure {
            for _ in 0..<asks {
                _ = (TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue()).flatMap(PasteKeyboard.identifier)
            }
        }
        let lookups = 50
        let resolving = clock.measure {
            for _ in 0..<lookups { _ = PasteKeyboard.resolve() }
        }
        let perAsk = asking / asks
        let perLookup = resolving / lookups
        print("paste-key cost: ask \(perAsk) each over \(asks), resolve \(perLookup) each over \(lookups)")
        #expect(perAsk < .milliseconds(1), "asked on every paste")
        #expect(perLookup < .milliseconds(20), "once per layout")
    }

    @Test("the current layout resolves to an ordinary key")
    func currentLayout() {
        #expect(PasteKeyboard.resolve() < 128)
    }

    // MARK: The paster presses the key it is given

    private func paster(on pasteboard: NSPasteboard, pasteKey: CGKeyCode?, record: @escaping (CGKeyCode, CGEventFlags) -> Void) -> ClipboardPaster {
        let post: ClipboardPaster.KeyPoster = { key, flags in record(key, flags); return true }
        guard let pasteKey else {
            return ClipboardPaster(pasteboard: pasteboard, postKey: post, restoreDelay: .milliseconds(10))
        }
        return ClipboardPaster(pasteboard: pasteboard, postKey: post, restoreDelay: .milliseconds(10),
                               pasteKey: { pasteKey })
    }

    private func pastedKeys(pasteKey: CGKeyCode?) async -> [(CGKeyCode, CGEventFlags)] {
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("app.hushy.tests.\(UUID().uuidString)"))
        defer { pasteboard.releaseGlobally() }
        var keys: [(CGKeyCode, CGEventFlags)] = []
        let paster = paster(on: pasteboard, pasteKey: pasteKey) { keys.append(($0, $1)) }
        let outcome = await paster.paste("Vela raises the amber sail.", pressReturn: false, awaitLanding: nil, hasFocus: { true })
        await paster.waitForPendingRestore()
        #expect(outcome == .pasted)
        return keys
    }

    @Test("on Dvorak the paster presses Command with the key that types V")
    func pressesTheLayoutsKey() async {
        let keys = await pastedKeys(pasteKey: CGKeyCode(kVK_ANSI_Period))
        #expect(keys.count == 1)
        #expect(keys.first?.0 == CGKeyCode(kVK_ANSI_Period))
        #expect(keys.first?.1 == .maskCommand)
    }

    @Test("a paster given no layout presses the key at QWERTY's V position, as before")
    func defaultIsTheUsualKey() async {
        let keys = await pastedKeys(pasteKey: nil)
        #expect(keys.first?.0 == CGKeyCode(kVK_ANSI_V))
        #expect(keys.first?.1 == .maskCommand)
    }

    @Test("Return is still the Return key whatever the paste key is")
    func returnIsUnchanged() async {
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("app.hushy.tests.\(UUID().uuidString)"))
        defer { pasteboard.releaseGlobally() }
        var keys: [CGKeyCode] = []
        let paster = ClipboardPaster(pasteboard: pasteboard, postKey: { key, _ in keys.append(key); return true },
                                     restoreDelay: .milliseconds(10), returnDelay: .milliseconds(1),
                                     pasteKey: { CGKeyCode(kVK_ANSI_Period) })
        _ = await paster.paste("Send it.", pressReturn: true, awaitLanding: nil, hasFocus: { true })
        await paster.waitForPendingRestore()
        #expect(keys == [CGKeyCode(kVK_ANSI_Period), CGKeyCode(kVK_Return)])
    }
}
