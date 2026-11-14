import AppKit
import ApplicationServices
import CoreAudio
import Foundation
import MurmurCore
import os

/// Polls Core Audio for "is some other process actively using the microphone, and which app is
/// it" — the input to "Ask to record when a call starts" (see `CallDetectionState`, which owns
/// every actual decision this drives).
///
/// Core Audio is always the call signal. In DEBUG, the meeting integration flag also permits
/// reading titles of a mic-using browser's windows to refine the service label. Page contents,
/// pixels and participant lists are not inspected (see `.claude/DECISIONS.md`).
///
/// - `kAudioDevicePropertyDeviceIsRunningSomewhere` on the default input device is checked first
///   as a cheap short-circuit: if nothing is using *any* input device, there's no need to walk
///   the process list at all.
/// - `kAudioHardwarePropertyProcessObjectList` + `kAudioProcessPropertyIsRunningInput` (macOS
///   14.4+) finds which specific process that is, and `kAudioProcessPropertyBundleID` maps it to
///   a `MeetingApp`.
///
/// On macOS below 14.4 (no per-process Core Audio properties), this degrades to "unsupported":
/// `pollActiveMeetingApp()` always returns `nil`, so the whole call-detection feature is silently
/// off rather than guessing from the coarser device-wide signal (which can't tell Hushy's own mic
/// capture apart from a genuine call and would misfire constantly).
enum CallDetector {
    private static let log = Logger(subsystem: "app.hushy", category: "call-detection")

    /// Whether this Mac can support call detection at all.
    static var isSupported: Bool {
        if #available(macOS 14.4, *) { true } else { false }
    }

    /// Returns the `MeetingApp` currently using the microphone, or `nil` if no recognized calling
    /// app is. Cheap enough to poll every second or two (a handful of Core Audio property reads,
    /// no allocation beyond one small array) but not so cheap it should run on every audio buffer.
    static func pollActiveMeetingApp() -> MeetingApp? {
        guard #available(macOS 14.4, *) else { return nil }
        guard defaultInputDeviceIsRunningSomewhere() else { return nil }
        return processObjectList().lazy.compactMap { objectID -> MeetingApp? in
            guard isRunningInput(objectID) else { return nil }
            guard let bundleID = bundleID(of: objectID) else { return nil }
            // Exclude Hushy's own process: its mic capture would otherwise look identical to a
            // genuine call and the prompt would fire on every dictation/note the user starts.
            guard bundleID != Bundle.main.bundleIdentifier else { return nil }
            guard let app = MeetingApp.matching(bundleID: bundleID) else { return nil }
            guard app == .browserMeeting, FeatureFlags.meetingAppIntegration else { return app }
            return browserMeeting(bundleID: bundleID) ?? app
        }.first(where: { _ in true })
    }

    /// Read window titles only after Core Audio confirms that this browser is using the mic.
    /// No page contents or screen pixels are requested. A failed AX read keeps the generic label.
    private static func browserMeeting(bundleID: String) -> MeetingApp? {
        guard AXIsProcessTrusted() else { return nil }
        for app in NSWorkspace.shared.runningApplications where app.bundleIdentifier?.caseInsensitiveCompare(bundleID) == .orderedSame {
            let element = AXUIElementCreateApplication(app.processIdentifier)
            AXUIElementSetMessagingTimeout(element, 0.1)
            var windows: CFTypeRef?
            guard AXUIElementCopyAttributeValue(element, kAXWindowsAttribute as CFString, &windows) == .success,
                  let windows = windows as? [AXUIElement] else { continue }
            for window in windows.prefix(12) {
                var value: CFTypeRef?
                guard AXUIElementCopyAttributeValue(window, kAXTitleAttribute as CFString, &value) == .success,
                      let title = value as? String,
                      let meeting = MeetingApp.browserMeeting(windowTitle: title) else { continue }
                return meeting
            }
        }
        return nil
    }

    /// Cheap short-circuit: is the system's default input device running in *any* process right
    /// now? When false, no process (Hushy included) is actively pulling mic samples, so there's
    /// no reason to walk the process list.
    private static func defaultInputDeviceIsRunningSomewhere() -> Bool {
        var deviceAddress = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var deviceID = AudioObjectID(kAudioObjectUnknown)
        var deviceIDSize = UInt32(MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &deviceAddress, 0, nil, &deviceIDSize, &deviceID) == noErr,
            deviceID != kAudioObjectUnknown
        else { return false }

        var runningAddress = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceIsRunningSomewhere,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var isRunning: UInt32 = 0
        var runningSize = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(deviceID, &runningAddress, 0, nil, &runningSize, &isRunning) == noErr
        else { return false }
        return isRunning != 0
    }

    @available(macOS 14.4, *)
    private static func processObjectList() -> [AudioObjectID] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyProcessObjectList,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size) == noErr
        else { return [] }
        var ids = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &ids) == noErr
        else { return [] }
        return ids
    }

    @available(macOS 14.4, *)
    private static func isRunningInput(_ objectID: AudioObjectID) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioProcessPropertyIsRunningInput,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(objectID, &address, 0, nil, &size, &value) == noErr else { return false }
        return value != 0
    }

    @available(macOS 14.4, *)
    private static func bundleID(of objectID: AudioObjectID) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioProcessPropertyBundleID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var size = UInt32(MemoryLayout<CFString?>.size)
        var cfString: CFString?
        let status = withUnsafeMutablePointer(to: &cfString) { pointer -> OSStatus in
            AudioObjectGetPropertyData(objectID, &address, 0, nil, &size, pointer)
        }
        guard status == noErr, let cfString else { return nil }
        return cfString as String
    }
}
