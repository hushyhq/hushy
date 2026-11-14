import Foundation

/// What, if anything, the Mac is asked to do once a search ends. Decided in one place, in code,
/// so the rule is testable: only ONE clear name match acts (Show in Finder, or Open when the
/// person said open); a list, a text-only match, nothing found and every failure act on nothing;
/// a file that runs when opened is shown, never opened.
public enum FileEffect: Sendable, Equatable {
    case none
    /// Show in Finder. `instead` is true when Open was asked for but the file runs when opened.
    case reveal(path: String, instead: Bool)
    case open(path: String)

    /// The effect of a finished search for a request that asked for `action`.
    public static func forOutcome(_ outcome: FileFindOutcome, action: FileAction) -> FileEffect {
        guard case .foundOne(let file, .name) = outcome else { return .none }
        return forChoice(path: file.path, open: action == .open)
    }

    /// The effect of a person's own pick (a click, or "open the second one").
    public static func forChoice(path: String, open: Bool) -> FileEffect {
        guard open else { return .reveal(path: path, instead: false) }
        return FileScope.runsWhenOpened(path: path) ? .reveal(path: path, instead: true) : .open(path: path)
    }
}
