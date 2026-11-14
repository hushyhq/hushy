import Carbon.HIToolbox
import CoreGraphics
import MurmurCore

/// The chord that opens the restyle chips over the selected text (Settings → General). Same family as paste last
/// (⌃⌘V) and copy last (⌃⌘C), which `HotkeyMonitor` already takes: control and command with a letter, so a plain ⌘T
/// (new tab) is never touched. Three or more modifiers are used by no common app, so ⌃⌥⌘T is the fallback for a
/// Mac where an app owns ⌃⌘T. Off stops the tap from taking the chord at all.
enum RestyleShortcut: String, CaseIterable, Identifiable, Codable {
    case controlCommandT
    case controlOptionCommandT
    case off

    static let `default` = RestyleShortcut.controlCommandT

    var id: String { rawValue }

    /// The chord as key caps; Off is placeholder copy.
    var title: String {
        switch self {
        case .controlCommandT: "⌃⌘T"
        case .controlOptionCommandT: "⌃⌥⌘T"
        case .off: RestyleCopy.off
        }
    }

    /// Whether this key-down is the chord. Exact modifiers (no shift, and option only where the chord has it), and
    /// never a held key repeating.
    func matches(keyCode: Int, flags: CGEventFlags, isRepeat: Bool) -> Bool {
        guard self != .off, keyCode == kVK_ANSI_T, !isRepeat,
              flags.contains(.maskControl), flags.contains(.maskCommand), !flags.contains(.maskShift) else { return false }
        return flags.contains(.maskAlternate) == (self == .controlOptionCommandT)
    }
}
