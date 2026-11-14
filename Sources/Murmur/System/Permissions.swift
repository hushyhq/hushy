import AppKit
import ApplicationServices
import AVFoundation
import Observation

/// Per-launch decision shared by startup and later permission changes.
@MainActor
struct PermissionRecoveryDecision {
    private(set) var hasOpened = false

    mutating func shouldOpen(onboardingComplete: Bool, microphone: Permissions.Status,
                             accessibility: Permissions.Status) -> Bool {
        guard onboardingComplete, !hasOpened,
              microphone != .granted || accessibility != .granted else { return false }
        hasOpened = true
        return true
    }
}

/// Tracks microphone and Accessibility permission, polling while anything is missing so the
/// UI can advance as soon as the user flips a switch in System Settings.
@MainActor
@Observable
final class Permissions {
    enum Status: Equatable {
        case granted, denied, notDetermined
    }

    private(set) var microphone: Status = .notDetermined
    private(set) var accessibility: Status = .notDetermined
    private var timer: Timer?
    private var pollTick = 0
    /// While everything is granted, `refresh()` runs on every this-many ticks of the 1 s timer.
    static let grantedPollEvery = 5
    /// Called only when a system permission changes, including a later revocation.
    var onChange: ((Status, Status) -> Void)?
    /// Set by `pinForSnapshot`. Once true, `refresh()` (called from `.onAppear` on both
    /// Home's dictation card and Settings' General pane) is a no-op — otherwise it would immediately
    /// overwrite a snapshot's pinned state with this machine's real, snapshot-irrelevant
    /// permission state the moment the pinned view renders.
    private var isPinnedForSnapshot = false

    var allGranted: Bool { microphone == .granted && accessibility == .granted }

    init() {
        refresh()
    }

    func refresh() {
        guard !isPinnedForSnapshot else { return }
        let previous = (microphone, accessibility)
        microphone = switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: .granted
        case .notDetermined: .notDetermined
        default: .denied
        }
        accessibility = AXIsProcessTrusted() ? .granted : .denied
        if previous.0 != microphone || previous.1 != accessibility {
            onChange?(microphone, accessibility)
        }
    }

    func startPolling() {
        guard timer == nil else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                // Keep watching after a grant (either switch can later be turned off), but only
                // every few seconds then: a missing permission is checked each second.
                self.pollTick += 1
                if self.allGranted, self.pollTick % Self.grantedPollEvery != 0 { return }
                self.refresh()
            }
        }
    }

    func stopPolling() {
        timer?.invalidate()
        timer = nil
    }

    /// Snapshot rendering only: pins microphone/Accessibility state without touching the real
    /// system permissions, the same pattern as `SpeechModelStatus.pinForSnapshot`. Omitted
    /// parameters keep their current value, so a caller can flip just one axis (e.g. only
    /// `microphone`) without restating the other. Also latches out `refresh()` (see
    /// `isPinnedForSnapshot`) so a page's own `.onAppear` refresh can't clobber the pin.
    func pinForSnapshot(microphone: Status? = nil, accessibility: Status? = nil) {
        isPinnedForSnapshot = true
        if let microphone { self.microphone = microphone }
        if let accessibility { self.accessibility = accessibility }
    }

    func requestMicrophone() async {
        if microphone == .notDetermined {
            _ = await AVCaptureDevice.requestAccess(for: .audio)
            refresh()
        } else if microphone == .denied {
            Self.openSettings(pane: "Privacy_Microphone")
        }
    }

    func requestAccessibility() {
        // Shows the system prompt once; afterwards we deep-link to the pane.
        let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        if !AXIsProcessTrustedWithOptions(options) {
            Self.openSettings(pane: "Privacy_Accessibility")
        }
        startPolling()
    }

    static func openSettings(pane: String) {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)") {
            NSWorkspace.shared.open(url)
        }
    }

    /// Privacy & Security → Calendars. Opens the pane only; the user makes the change.
    static func openCalendarSettings() {
        openSettings(pane: "Privacy_Calendars")
    }

    /// Deep-links to System Settings → Privacy & Security → Screen & System Audio Recording,
    /// which is where macOS surfaces the permission Core Audio process taps (and the
    /// ScreenCaptureKit fallback) piggyback on. Used by the "Record call audio" toggle's denied
    /// state — Hushy never flips this switch itself, only opens the pane so the user can.
    /// Privacy & Security → Screen & System Audio Recording (where "System Audio Recording
    /// Only" lives). Opens the pane only; the user makes the change.
    static func openScreenRecordingSettings() {
        openSettings(pane: "Privacy_ScreenCapture")
    }

    static func openKeyboardSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.Keyboard-Settings.extension") {
            NSWorkspace.shared.open(url)
        }
    }

    /// What the Globe/fn key does system-wide. Anything but "do nothing" can fight with fn dictation.
    enum GlobeKeyAction: Int {
        case doNothing = 0, changeInputSource = 1, emoji = 2, dictation = 3

        var conflicts: Bool { self != .doNothing }

        var title: String {
            switch self {
            case .doNothing: "Do Nothing"
            case .changeInputSource: "Change Input Source"
            case .emoji: "Show Emoji & Symbols"
            case .dictation: "Start Dictation"
            }
        }
    }

    /// macOS's own Dictation. When it's on, its shortcut (often "press 🌐 twice") can fire
    /// together with Murmur's fn / double-tap, so both type and the text appears twice.
    static var macDictationEnabled: Bool {
        UserDefaults(suiteName: "com.apple.assistant.support")?.bool(forKey: "Dictation Enabled") ?? false
    }

    /// The modifier flags of macOS Dictation's "press twice" shortcut (symbolic hotkey 164),
    /// or nil when Dictation is off or its shortcut isn't a double-press of a modifier.
    /// Read-only; Hushy never changes it.
    static var macDictationShortcutModifiers: CGEventFlags? {
        guard macDictationEnabled,
              let hotkeys = UserDefaults(suiteName: "com.apple.symbolichotkeys")?
                .dictionary(forKey: "AppleSymbolicHotKeys"),
              let entry = hotkeys["164"] as? [String: Any],
              (entry["enabled"] as? Bool ?? (entry["enabled"] as? Int == 1)),
              let value = entry["value"] as? [String: Any],
              value["type"] as? String == "modifier",
              let parameters = value["parameters"] as? [Int], let flags = parameters.first
        else { return nil }
        return CGEventFlags(rawValue: UInt64(flags))
    }

    /// Whether macOS Dictation's shortcut is a double-press of Hushy's own trigger key, so a
    /// hands-free double-tap would start both.
    static func macDictationClashes(with trigger: TriggerKey) -> Bool {
        guard let flags = macDictationShortcutModifiers else { return false }
        let triggerFlag: CGEventFlags = switch trigger {
        case .fn: .maskSecondaryFn
        case .rightOption: .maskAlternate
        case .rightCommand: .maskCommand
        case .controlOption: .maskControl
        }
        return flags.contains(triggerFlag)
    }

    /// Whether macOS Dictation's shortcut is a double press of the key voice actions use, so one
    /// double tap would start both. Readable without any permission (symbolic hotkey 164, the same
    /// source `macDictationClashes(with:)` uses); false when Dictation is off or its shortcut is
    /// not a double press of a modifier.
    static func macDictationClashes(with key: ActionTriggerKey) -> Bool {
        macDictationClashes(shortcut: macDictationShortcutModifiers, with: key)
    }

    /// Pure: `shortcut` is Dictation's double-press modifier (nil when off or not a double press).
    static func macDictationClashes(shortcut: CGEventFlags?, with key: ActionTriggerKey) -> Bool {
        guard let shortcut else { return false }
        return shortcut.contains(key.flag)
    }

    static var globeKeyAction: GlobeKeyAction {
        let value = UserDefaults(suiteName: "com.apple.HIToolbox")?.object(forKey: "AppleFnUsageType") as? Int
        return GlobeKeyAction(rawValue: value ?? GlobeKeyAction.emoji.rawValue) ?? .emoji
    }
}
