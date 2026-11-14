import AppKit
import Carbon.HIToolbox
import MurmurCore
import os

/// The key Hushy presses with Command to paste, for the keyboard layout in use (`PasteKey`).
///
/// The key is kept for as long as the layout stays the same. A paste asks which layout is in use
/// (one cheap lookup of its identifier) and works the key out again only when that has changed,
/// so a layout change is picked up at the next paste without relying on a notification. A layout
/// that cannot be read leaves the key at QWERTY's V position, as before.
@MainActor
final class PasteKeyboard {
    static let shared = PasteKeyboard()

    private var cache = PasteKeyCache()
    private static let log = Logger(subsystem: "app.hushy", category: "clipboard")

    private init() {}

    /// The paste key for the keyboard layout in use now.
    var pasteKeyCode: CGKeyCode {
        let source = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue()
        return CGKeyCode(cache.key(forLayout: source.flatMap(Self.identifier)) {
            let key = Self.resolve(current: source, latin: TISCopyCurrentASCIICapableKeyboardLayoutInputSource()?.takeRetainedValue())
            Self.log.notice("paste-key code=\(key, privacy: .public)")
            return UInt16(key)
        })
    }

    /// The identifier of a keyboard layout (`com.apple.keylayout.Dvorak`), or nil when it has none.
    static func identifier(_ source: TISInputSource) -> String? {
        guard let property = TISGetInputSourceProperty(source, kTISPropertyInputSourceID) else { return nil }
        return Unmanaged<CFString>.fromOpaque(property).takeUnretainedValue() as String
    }

    /// The paste key for the current keyboard layout.
    static func resolve() -> CGKeyCode {
        resolve(current: TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue(),
                latin: TISCopyCurrentASCIICapableKeyboardLayoutInputSource()?.takeRetainedValue())
    }

    /// The paste key for the layout being typed in; when that layout has no Latin "v" at all, for
    /// the Latin (ASCII-capable) layout the system reads shortcuts through. Reads the layouts'
    /// own tables; changes nothing.
    static func resolve(current: TISInputSource?, latin: TISInputSource? = nil) -> CGKeyCode {
        let tables = [current, latin].compactMap { $0 }.compactMap(layoutData)
        return CGKeyCode(withLayouts(tables, found: []) { PasteKey.keyCode(layouts: $0) })
    }

    /// Calls `body` with one translate function per layout, each valid only inside the call.
    private static func withLayouts(
        _ tables: [Data], found: [(UInt16, Bool) -> String?], _ body: ([(UInt16, Bool) -> String?]) -> UInt16
    ) -> UInt16 {
        guard let table = tables.first else { return body(found) }
        return table.withUnsafeBytes { bytes -> UInt16 in
            guard let layout = bytes.bindMemory(to: UCKeyboardLayout.self).baseAddress else {
                return withLayouts(Array(tables.dropFirst()), found: found, body)
            }
            let translate: (UInt16, Bool) -> String? = { key, withCommand in
                character(layout: layout, keyCode: key, withCommand: withCommand)
            }
            return withLayouts(Array(tables.dropFirst()), found: found + [translate], body)
        }
    }

    private static func layoutData(_ source: TISInputSource) -> Data? {
        guard let property = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData) else { return nil }
        return Unmanaged<CFData>.fromOpaque(property).takeUnretainedValue() as Data
    }

    /// The character a physical key produces on a layout, alone or with Command held.
    private static func character(layout: UnsafePointer<UCKeyboardLayout>, keyCode: UInt16, withCommand: Bool) -> String? {
        var deadKeys: UInt32 = 0
        var length = 0
        var characters = [UniChar](repeating: 0, count: 4)
        let modifiers = withCommand ? UInt32((cmdKey >> 8) & 0xFF) : 0
        let status = UCKeyTranslate(
            layout, keyCode, UInt16(kUCKeyActionDown), modifiers, UInt32(LMGetKbdType()),
            OptionBits(kUCKeyTranslateNoDeadKeysMask), &deadKeys, characters.count, &length, &characters)
        guard status == noErr, length > 0 else { return nil }
        return String(utf16CodeUnits: characters, count: length)
    }
}
