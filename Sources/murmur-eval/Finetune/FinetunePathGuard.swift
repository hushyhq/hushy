import Foundation

/// Every file the fine-tune pipeline reads or writes goes through here first (M7 data rule,
/// `docs/product/FINETUNE.md`): the blind held-out sets (`Evals/heldout-v2*`, the sealed
/// `actions-heldout*`), Voice Lab recordings and the app's own data directory
/// (`~/Library/Application Support/Hushy`) and the eval-only external benchmarks
/// (`Evals/data/external/`: DisfluencySpeech, Disfl-QA) are refused outright, so nothing from them can leak
/// into training data even by a mistyped path. `scripts/finetune/pathguard.py` is the same rule
/// for the Python side; both are unit-tested.
enum FinetunePathGuard {
    struct Refused: LocalizedError, Equatable {
        let path: String
        let pattern: String
        var errorDescription: String? { "finetune: refusing \(path) (matches forbidden pattern '\(pattern)')" }
    }

    /// Lower-cased substrings that may never appear in a pipeline path (checked on the path as
    /// given and after resolving symlinks). "heldout" covers `heldout-v2*` and `actions-heldout*`.
    static let forbiddenPatterns = [
        "heldout", "held-out", "held_out", "voicelab", "voice-lab", "voice_lab", "voice lab",
        "application support/hushy", "application support/murmur",
        // External public benchmarks are evaluation-only: never training data.
        "data/external", "disfluencyspeech", "disfl_qa", "disfl-qa", "disflqa",
        // The long-meeting digest eval (Evals/meeting-eval): eval-only, never training data.
        "meeting-eval", "/gate/",
        // Sealed by name (.claude/AGENTS.md). Keep in sync with pathguard.FORBIDDEN_PATTERNS.
        "ab-", "eval-long64-b", "longb", "runs/sealed",
    ] + indexOnlyPatterns

    /// Dev sets written by a separate author to measure negative robustness
    /// (`Evals/negatives-fresh-dev.json`): never a fine-tune input. The Python builder reads them
    /// only for its contamination index. Keep in sync with pathguard.INDEX_ONLY_PATTERNS.
    static let indexOnlyPatterns = ["negatives-fresh"]

    /// Sealed families named by a file-name prefix: they match only where a path component starts, so a temp folder
    /// such as `…-9B91E6AB-AD3C…` is not mistaken for `ab-…`.
    static let componentPrefixPatterns: Set<String> = ["ab-", "eval-long64-b", "longb"]

    /// The first forbidden pattern `path` matches, or nil.
    static func violation(_ path: String) -> String? {
        let candidates = [path, URL(fileURLWithPath: path).resolvingSymlinksInPath().path].map { $0.lowercased() }
        for pattern in forbiddenPatterns where candidates.contains(where: { matches($0, pattern) }) {
            return pattern
        }
        return nil
    }

    private static func matches(_ candidate: String, _ pattern: String) -> Bool {
        guard componentPrefixPatterns.contains(pattern) else { return candidate.contains(pattern) }
        return candidate.hasPrefix(pattern) || candidate.contains("/" + pattern)
    }

    /// `path` as a file URL, or throws `Refused`.
    static func checked(_ path: String) throws -> URL {
        if let pattern = violation(path) { throw Refused(path: path, pattern: pattern) }
        return URL(fileURLWithPath: path)
    }
}

/// JSON Lines in and out for the fine-tune subcommands. Rows stay untyped dictionaries so each
/// step adds its own fields and passes the rest through unchanged.
enum FinetuneJSONL {
    typealias Row = [String: Any]

    static func read(_ path: String) throws -> [Row] {
        let url = try FinetunePathGuard.checked(path)
        let text = try String(contentsOf: url, encoding: .utf8)
        return try text.split(separator: "\n", omittingEmptySubsequences: true).enumerated().map { index, line in
            guard let row = try JSONSerialization.jsonObject(with: Data(line.utf8)) as? Row else {
                throw EvalError.missing("\(path):\(index + 1) is not a JSON object")
            }
            return row
        }
    }

    static func write(_ rows: [Row], to path: String) throws {
        let url = try FinetunePathGuard.checked(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let lines = try rows.map { row in
            let data = try JSONSerialization.data(withJSONObject: row, options: [.sortedKeys, .withoutEscapingSlashes])
            return String(decoding: data, as: UTF8.self)
        }
        try (lines.joined(separator: "\n") + (lines.isEmpty ? "" : "\n")).write(to: url, atomically: true, encoding: .utf8)
    }

    static func string(_ row: Row, _ key: String) -> String? {
        row[key] as? String
    }
}
