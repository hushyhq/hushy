import Observation

/// The shared "turn on → check access → notice or keep" step behind every Apple Notes toggle:
/// the setup choice, the Notes sidebar row, Settings → Meetings, Settings → Voice actions and the
/// answer card's "Search Apple Notes?" offer.
/// Turning on checks access first and writes the setting only if it was granted, so a setting
/// never claims something that doesn't work; otherwise `problem` says what happened and the view
/// shows `AppleNotesAccessNotice`. Turning off never touches Notes. The scripter is injected:
/// tests and snapshots pass a fake, so no AppleScript runs and no Automation prompt appears.
@MainActor
@Observable
final class AppleNotesToggle {
    private(set) var problem: AppleNotesAccessResult?

    /// `apply` receives the value to store (`true` only when access was granted).
    func turn(
        _ on: Bool,
        using scripter: any AppleNotesScripting = AppleNotesExporter.defaultScripter,
        apply: (Bool) -> Void
    ) {
        guard on else {
            problem = nil
            apply(false)
            return
        }
        turnOn(using: scripter, apply: apply)
    }

    /// Turning on, for callers that need the verdict too (the answer card's "Search Apple Notes?"
    /// offer shows the refusal in the card itself rather than a notice under a row).
    @discardableResult
    func turnOn(
        using scripter: any AppleNotesScripting = AppleNotesExporter.defaultScripter,
        apply: (Bool) -> Void
    ) -> AppleNotesAccessResult {
        let result = AppleNotesExporter.requestAccess(using: scripter)
        problem = result.isGranted ? nil : result
        apply(result.isGranted)
        return result
    }
}
