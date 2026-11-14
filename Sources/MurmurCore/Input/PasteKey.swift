import Foundation

/// Which physical key Hushy presses with Command to paste.
///
/// A synthesized keystroke names a physical key, not a letter, and the app receiving it reads the
/// letter through the current keyboard layout. The key at QWERTY's V position is "v" on QWERTY,
/// AZERTY and many more, but on Dvorak it is "k": Command with it is another shortcut and nothing
/// is pasted. So the key is looked up in the layout. Pure: the layout is a function from a key
/// code (and whether Command is held) to the character it produces, or nil when it cannot be read.
public enum PasteKey {
    /// The key at QWERTY's V position (`kVK_ANSI_V`): the key used when the layout cannot be read.
    public static let qwertyV: UInt16 = 9
    /// The ordinary keys of a keyboard, as virtual key codes.
    static let keyCodes: Range<UInt16> = 0..<128

    /// The paste key across the layouts that may decide it, in order: the layout being typed in,
    /// then the Latin (ASCII-capable) layout the system reads shortcuts through when the first has
    /// no Latin "v" at all. The first layout with an answer wins; with none, the usual key.
    public static func keyCode(layouts: [(_ keyCode: UInt16, _ withCommand: Bool) -> String?]) -> UInt16 {
        for translate in layouts {
            if let key = found(translate: translate) { return key }
        }
        return qwertyV
    }

    /// The paste key on one layout, or the usual key when it has no "v" or cannot be read.
    public static func keyCode(translate: (_ keyCode: UInt16, _ withCommand: Bool) -> String?) -> UInt16 {
        found(translate: translate) ?? qwertyV
    }

    /// In order: the usual key, when the layout makes it "v" while Command is held (QWERTY, a
    /// layout that switches to QWERTY for Command shortcuts such as "Dvorak – QWERTY ⌘", and
    /// non-Latin layouts whose Command keys are Latin); else the lowest key that is "v" with
    /// Command held; else the lowest key that types "v"; else nil.
    static func found(translate: (_ keyCode: UInt16, _ withCommand: Bool) -> String?) -> UInt16? {
        if isV(translate(qwertyV, true)) { return qwertyV }
        if let key = keyCodes.first(where: { isV(translate($0, true)) }) { return key }
        return keyCodes.first(where: { isV(translate($0, false)) })
    }

    private static func isV(_ character: String?) -> Bool {
        character?.lowercased() == "v"
    }
}

/// The paste key, kept for as long as the keyboard layout stays the same. A paste asks with the
/// layout's identifier; the key is worked out again only when that differs from last time, so a
/// layout change is picked up at the next paste whether or not anything announced it.
public struct PasteKeyCache: Sendable {
    private var entry: (layout: String?, key: UInt16)?

    public init() {}

    public mutating func key(forLayout layout: String?, resolve: () -> UInt16) -> UInt16 {
        if let entry, entry.layout == layout { return entry.key }
        let key = resolve()
        entry = (layout, key)
        return key
    }
}
