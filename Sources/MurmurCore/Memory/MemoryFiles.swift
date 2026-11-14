import Foundation

/// The memory folder's files: which one holds each kind of entry, and what a new one starts
/// with. Every file Hushy creates opens with a short note, in plain words, on how to edit it.
enum MemoryFiles {
    static let profile = "profile.md"
    static let terms = "terms.md"
    static let corrections = "corrections.md"
    static let styleFolder = "style"
    private static let unknownApp = "unknown"

    static func path(for entry: MemoryEntry) -> String {
        switch entry.kind {
        case .profile: return profile
        case .term, .forgotten: return terms
        case .correction: return corrections
        case .style:
            let app = entry.appBundleID ?? unknownApp
            let safe = !app.isEmpty && app != "." && app != ".." && app.unicodeScalars.allSatisfy {
                CharacterSet.alphanumerics.contains($0) || $0 == "." || $0 == "-" || $0 == "_"
            }
            return "\(styleFolder)/\(safe ? app : unknownApp).md"
        }
    }

    static func file(at path: String) -> MemoryDocument.File {
        switch path {
        case profile: return .profile
        case terms: return .terms
        case corrections: return .corrections
        default:
            let app = String(path.dropFirst(styleFolder.count + 1).dropLast(3))
            return .style(app: app == unknownApp ? nil : app)
        }
    }

    /// What a file holds before its first entry.
    static func starter(for path: String) -> String {
        switch file(at: path) {
        case .terms:
            return """
            # Words Hushy knows

            > The names and terms you use, so Hushy spells them your way.
            > Each line that starts with a dash and a space is one word or name.
            > To add your own, type a new line like that under "Words".
            > A word under "Forgotten" is never learned again. Delete its line there to let Hushy use it again.
            > The part of a line between <!-- and --> is Hushy's own note (the date, how the word was misheard,
            > and whether Hushy learned the word or you typed it). Leave it as it is. A line you type yourself needs none.
            > "Delete learning data" in Settings removes the words Hushy learned. A word you typed or changed stays.

            ## Words

            ## Forgotten
            """
        case .profile:
            return starter(title: "How I write", lead: "Notes on how you write, used for every dictation.",
                           extra: "Keep them short: Hushy reads about the first 1,500 characters.")
        case .style(let app):
            return starter(title: "How I write in \(app ?? "one app")",
                           lead: "Notes on how you write in this one app. The file's name says which app.", extra: nil)
        case .corrections:
            return """
            # Changes I made

            > What Hushy wrote and what you changed it to, one pair on each line.
            > Hushy writes these lines. You can delete any of them.

            ## Changes
            """
        }
    }

    private static func starter(title: String, lead: String, extra: String?) -> String {
        var note = [
            "> " + lead,
            "> Each line that starts with a dash and a space is one note.",
            "> To add your own, type a new line like that under \"Notes\".",
        ]
        if let extra { note.append("> " + extra) }
        note.append("> The part of a line between <!-- and --> is Hushy's own note (the date). Leave it as it is.")
        note.append("> A line you type yourself needs none.")
        return (["# " + title, ""] + note + ["", "## Notes"]).joined(separator: "\n")
    }
}
