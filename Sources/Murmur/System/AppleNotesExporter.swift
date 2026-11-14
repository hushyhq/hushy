import AppKit
import MurmurCore

/// Saves a finished note into Apple Notes (folder "Hushy") so it syncs to iPhone via iCloud.
/// Uses Apple Events; macOS asks the user once for permission to control Notes.
///
/// Pre-rename installs exported into a folder named "Murmur"; that folder and its notes are
/// left alone (Apple Notes folders aren't something we move via Apple Events without risking
/// the user's other Notes data), so new exports start a fresh "Hushy" folder alongside it.
@MainActor
enum AppleNotesExporter {
    static let folder = "Hushy"

    /// A failed export, with the AppleScript error number so the screen can say what happened.
    struct ExportError: LocalizedError, Equatable {
        let number: Int
        let message: String

        var result: AppleNotesAccessResult { .from(errorNumber: number) }
        var errorDescription: String? { result.message }
    }

    /// The real scripter for the app; tests and snapshots pass a fake.
    static let defaultScripter: any AppleNotesScripting = NSAppleScriptRunner()

    /// Asks macOS for permission to add notes (the one-time Automation prompt) right when the
    /// user turns the option on, instead of surprising them after their first recording. The
    /// script only counts folders; it never writes. Says what happened, not just yes or no.
    static func requestAccess(using scripter: any AppleNotesScripting = defaultScripter) -> AppleNotesAccessResult {
        let error = scripter.run("tell application \"Notes\" to count folders")
        return .from(errorNumber: error?.number)
    }

    /// `done` are the note's checked-off action-item indexes (kept apart from the note); `transcript` is the
    /// note's turns (both sides of a call), else the stored cache of them.
    static func export(
        _ note: Note, transcript: NoteTranscript? = nil, done: Set<Int> = [],
        using scripter: any AppleNotesScripting = defaultScripter
    ) throws {
        let source = """
            tell application "Notes"
                if not (exists folder "\(folder)") then make new folder with properties {name:"\(folder)"}
                make new note at folder "\(folder)" with properties {name:\(quoted(note.title)), body:\(quoted(html(note, transcript: transcript, done: done)))}
            end tell
            """
        if let error = scripter.run(source) {
            throw ExportError(number: error.number, message: error.message)
        }
    }

    /// Notes stores HTML; keep structure (headings, lists) and escape user text.
    /// Action items are the same one-line form the note, the recap and the Markdown export use
    /// ("Priya: Send the deck — by Friday"), with " (done)" after a checked-off item.
    static func html(_ note: Note, transcript: NoteTranscript? = nil, done: Set<Int> = []) -> String {
        var parts = ["<h1>\(escape(note.title))</h1>"]
        if !note.summary.isEmpty {
            let items = note.summary.components(separatedBy: "\n").filter { !$0.isEmpty }
                .map { "<li>\(escape($0.hasPrefix("- ") ? String($0.dropFirst(2)) : $0))</li>" }
            parts.append("<h2>Summary</h2><ul>\(items.joined())</ul>")
        }
        if !note.actionItems.isEmpty {
            let items = note.actionItems.enumerated().map { "<li>\(escape($0.element))\(done.contains($0.offset) ? " (done)" : "")</li>" }
            parts.append("<h2>Action items</h2><ul>\(items.joined())</ul>")
        }
        parts.append("<h2>Transcript</h2><p>\(escape(transcript?.rendered ?? note.transcript))</p>")
        return parts.joined()
    }

    private static func escape(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\n", with: "<br>")
    }

    /// An AppleScript string literal.
    private static func quoted(_ text: String) -> String {
        "\"" + text.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }
}

/// The one place AppleScript actually runs.
@MainActor
struct NSAppleScriptRunner: AppleNotesScripting {
    func run(_ source: String) -> AppleNotesScriptError? {
        var error: NSDictionary?
        NSAppleScript(source: source)?.executeAndReturnError(&error)
        guard let error else { return nil }
        return AppleNotesScriptError(
            number: error[NSAppleScript.errorNumber] as? Int ?? 0,
            message: error[NSAppleScript.errorMessage] as? String ?? "unknown error")
    }
}
