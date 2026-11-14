import AppKit

/// Shown at launch when the database could not be opened and Hushy is running in memory.
/// Nothing is deleted or rewritten; what is dictated or recorded now is not saved.
@MainActor
enum DatabaseFailureAlert {
    static func show(_ detail: String) {
        Task { @MainActor in
            let alert = NSAlert()
            alert.alertStyle = .critical
            alert.messageText = "[placeholder] Hushy could not open its saved data"
            alert.informativeText = "[placeholder] Nothing was deleted. Anything you dictate or record until you quit will not be saved. Quit and reopen Hushy. Details: \(detail)"
            alert.addButton(withTitle: "[placeholder] OK")
            alert.runModal()
        }
    }
}
