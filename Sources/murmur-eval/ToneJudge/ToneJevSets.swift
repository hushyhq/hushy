import Foundation

/// The only case files the tone judge may read. The rule (`Evals/JUDGES.md`) is that the remote judge
/// sees only the invented text of our own development sets, so when the judge is on, a case file must
/// be one of the tone dev sets that ship in this repository's `Evals/`, by fixed name, at the real path.
///
/// The folder is the repository's own `Evals/`, found from where this source file sits at compile time.
/// It does not depend on `MURMUR_EVAL_HOME` or on the directory the command is run from, because agents
/// set home variables routinely and a same-named file in a temporary folder must not pass. This is a guard
/// against accidents with paths and environment. It is not a content hash and does not detect a hard link
/// or someone editing the shipped file; that is deliberate.
enum ToneJevSets {
    static let shipped: Set<String> = ["tones-dev.json", "tones-dev-long.json"]

    /// `Sources/murmur-eval/ToneJudge/ToneJevSets.swift` is three folders below the repository root.
    static let repositoryEvals: URL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Evals", isDirectory: true)

    static func isShipped(_ file: URL, evalsFolder: URL = repositoryEvals) -> Bool {
        let resolved = file.resolvingSymlinksInPath().standardizedFileURL
        let folder = evalsFolder.resolvingSymlinksInPath().standardizedFileURL
        return resolved.deletingLastPathComponent().path == folder.path && shipped.contains(resolved.lastPathComponent)
    }

    /// Throws when `file` is not a shipped tone dev set. Call before anything is sent to the judge.
    static func requireShipped(_ file: URL, evalsFolder: URL = repositoryEvals) throws {
        guard isShipped(file, evalsFolder: evalsFolder) else {
            throw EvalError.missing(
                "the tone judge only reads the tone dev sets that ship in Evals/ (\(shipped.sorted().joined(separator: ", "))); "
                    + "refusing \(file.lastPathComponent). Run without --jev / --jev-calibrate to use another file.")
        }
    }
}
