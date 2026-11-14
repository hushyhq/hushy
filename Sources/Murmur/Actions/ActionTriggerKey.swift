import Carbon.HIToolbox
import CoreGraphics

/// The key a person presses twice to start a voice action (Settings → Voice actions). Control is
/// the default. Only keys that are safe to double-tap during ordinary typing are offered, and
/// never a letter key.
///
/// Left out on purpose:
/// - **fn / Globe.** Every solo press already does something in macOS (the emoji picker, an input
///   source switch, or Apple's Dictation, whose own default shortcut is fn twice), and fn is
///   Hushy's own dictation key by default, where a double tap latches hands-free dictation.
/// - **Left Command.** A bare tap is part of too many menu and app-switching habits.
/// - **Shift and Caps Lock.** They change what is typed, or are pressed in the middle of a word.
///
/// Control, Option and right Command do nothing on their own, so a bare double tap is free.
enum ActionTriggerKey: String, CaseIterable, Identifiable, Codable {
    case control
    case option
    case rightCommand

    static let `default` = ActionTriggerKey.control

    var id: String { rawValue }

    /// The key as a readable cap, in words (the founder read ⌃ as an up arrow).
    var keyCap: String {
        switch self {
        case .control: "control"
        case .option: "option"
        case .rightCommand: "right command"
        }
    }

    /// "control twice", for a sentence.
    var phrase: String { "\(keyCap) twice" }

    /// The picker's row title.
    var title: String {
        switch self {
        case .control: "Control, twice"
        case .option: "Option, twice"
        case .rightCommand: "Right Command, twice"
        }
    }

    /// The physical keys that count as this one (left and right Control or Option).
    var keyCodes: Set<Int> {
        switch self {
        case .control: [kVK_Control, kVK_RightControl]
        case .option: [kVK_Option, kVK_RightOption]
        case .rightCommand: [kVK_RightCommand]
        }
    }

    /// The modifier flag that is up while this key is down.
    var flag: CGEventFlags {
        switch self {
        case .control: .maskControl
        case .option: .maskAlternate
        case .rightCommand: .maskCommand
        }
    }

    /// The left-Command device bit (`NX_DEVICELCMDKEYMASK`), which tells right from left Command.
    private static let leftCommandBit: UInt64 = 0x08

    /// Whether any modifier other than this key is down in `flags`. A tap with another modifier
    /// held is part of a shortcut, never a trigger.
    func othersDown(in flags: CGEventFlags) -> Bool {
        let modifiers: [CGEventFlags] = [.maskControl, .maskAlternate, .maskCommand, .maskShift, .maskSecondaryFn]
        let others = modifiers.filter { $0 != flag }
        if others.contains(where: { flags.contains($0) }) { return true }
        return self == .rightCommand && flags.rawValue & Self.leftCommandBit != 0
    }

    /// Whether this key would collide with Hushy's own dictation key. Option twice on the right
    /// Option key, and right Command twice on the right Command key, are dictation's double-tap
    /// latch already.
    func conflicts(with dictation: TriggerKey) -> Bool {
        switch (self, dictation) {
        case (.option, .rightOption), (.rightCommand, .rightCommand): true
        default: false
        }
    }

    /// The key voice actions really use: the choice, unless it collides with the dictation key
    /// (then Control, which never does). The Settings row says so when that happens.
    static func effective(_ chosen: ActionTriggerKey, dictation: TriggerKey) -> ActionTriggerKey {
        chosen.conflicts(with: dictation) ? .default : chosen
    }

    /// The keys the picker offers next to this dictation key.
    static func choices(dictation: TriggerKey) -> [ActionTriggerKey] {
        allCases.filter { !$0.conflicts(with: dictation) }
    }
}
