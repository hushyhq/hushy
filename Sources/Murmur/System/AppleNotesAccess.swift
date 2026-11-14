import Foundation

/// What happened when Hushy tried to talk to Apple Notes. Pure data: the mapping from an
/// AppleScript error number is unit-tested, and the words the user reads live here too, so a
/// screen never has to guess why a call failed.
enum AppleNotesAccessResult: Equatable, Sendable {
    case granted
    /// macOS refused: Hushy isn't allowed to control Notes (error -1743).
    case notPermitted
    /// Notes couldn't be reached: not running, can't launch, or the folder/object wasn't found.
    case notesUnavailable
    /// Notes didn't answer in time (error -1712).
    case timedOut
    /// Any other AppleScript error, with its number so it can be looked up.
    case other(Int)

    /// -1743 errAEEventNotPermitted. -1712 errAETimeout.
    /// -600 procNotFound, -609 connectionInvalid, -1728 errAENoSuchObject, -10810 launch failed,
    /// -10814 no application can open it.
    static let notPermittedCodes: Set<Int> = [-1743]
    static let timedOutCodes: Set<Int> = [-1712]
    static let notesUnavailableCodes: Set<Int> = [-600, -609, -1728, -10810, -10814]

    /// `nil` means the script ran without error.
    static func from(errorNumber: Int?) -> AppleNotesAccessResult {
        guard let code = errorNumber else { return .granted }
        if notPermittedCodes.contains(code) { return .notPermitted }
        if timedOutCodes.contains(code) { return .timedOut }
        if notesUnavailableCodes.contains(code) { return .notesUnavailable }
        return .other(code)
    }

    var isGranted: Bool { self == .granted }

    /// Only a refusal can be fixed in System Settings.
    var canOpenSettings: Bool { self == .notPermitted }

    /// The Automation pane of Privacy & Security.
    static let automationSettingsURL = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation")!

    /// Plain words for what happened. "Blocked" appears only when macOS said so.
    var message: String {
        switch self {
        case .granted:
            "Hushy can save to Apple Notes."
        case .notPermitted:
            "macOS blocked it: Hushy isn't allowed to control Notes. You can allow it in System Settings → Privacy & Security → Automation."
        case .notesUnavailable:
            "Hushy couldn't reach the Notes app. Open Notes once, then try again."
        case .timedOut:
            "Notes took too long to answer. Try again."
        case .other(let code):
            "Notes returned an error (code \(code)). Try again."
        }
    }
}

/// The error half of an AppleScript run.
struct AppleNotesScriptError: Equatable, Sendable {
    let number: Int
    let message: String
}

/// Runs AppleScript source for Apple Notes. The real one is `NSAppleScriptRunner`; tests and
/// snapshots use a fake, so nothing in them can trigger the Automation prompt or write to Notes.
@MainActor
protocol AppleNotesScripting {
    /// Returns `nil` when the script ran cleanly.
    func run(_ source: String) -> AppleNotesScriptError?
}
