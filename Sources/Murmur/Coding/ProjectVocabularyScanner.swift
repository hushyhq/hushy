import Foundation
import MurmurCore

/// Scans a user-picked project folder for identifiers and file names, off the main thread, for
/// the optional "project vocabulary" feature (see `ProjectVocabulary` in MurmurCore and the
/// "Coding" settings card). This is the only piece of the feature that touches the file system;
/// everything downstream (matching, boosting, file tagging) is pure `MurmurCore` code.
///
/// Deliberately simple and conservative: this is a *hint source* for ASR boosting and file
/// tagging, not a real parser. A regex-based token scan over source-looking files is enough to
/// catch the identifiers and file names a developer actually says out loud ("get user by id",
/// "index dot tsx") without pulling in a language-specific parser per ecosystem.
enum ProjectVocabularyScanner {
    /// Hard cap on files scanned, per the feature's contract — protects against scanning into a
    /// huge monorepo by accident and keeps a scan bounded in time even on a slow disk.
    static let maxFiles = 20_000

    /// Directories never worth descending into: dependency trees, VCS metadata and build output.
    /// Matched by exact directory name at any depth, not by path prefix, so this also skips a
    /// nested "node_modules" inside a workspace package.
    private static let skippedDirectoryNames: Set<String> = [
        "node_modules", ".git", "build", "dist", ".build", "DerivedData", ".svn", ".hg",
        "vendor", "Pods", ".venv", "venv", "__pycache__", "target", ".next", ".turbo",
        ".cache", "coverage", "out",
    ]

    /// Extensions worth reading for identifiers — ordinary source/config/markup files. A file
    /// outside this list still counts for `fileNames` (so "@readme.md" tagging works) but its
    /// contents are never read.
    private static let sourceExtensions: Set<String> = [
        "swift", "ts", "tsx", "js", "jsx", "mjs", "cjs", "py", "rb", "go", "rs", "java", "kt",
        "kts", "c", "h", "cpp", "cc", "hpp", "cs", "php", "m", "mm", "scala", "sh", "zsh",
        "json", "yaml", "yml", "toml", "sql", "graphql", "proto",
    ]

    /// Extensions that are unambiguously binary/media — never opened for identifier text even if
    /// something upstream miscategorized them, since reading a binary as UTF-8 text wastes time
    /// and can never produce a usable identifier.
    private static let binaryExtensions: Set<String> = [
        "png", "jpg", "jpeg", "gif", "webp", "svg", "ico", "icns", "pdf", "zip", "gz", "tar",
        "woff", "woff2", "ttf", "otf", "mp3", "mp4", "mov", "wav", "exe", "dylib", "so", "a",
        "o", "class", "jar", "db", "sqlite", "lock",
    ]

    /// Identifier token shapes worth keeping: camelCase, PascalCase, snake_case, SCREAMING_SNAKE,
    /// or kebab-case, at least 3 characters, so a scan doesn't fill up with noise like loop
    /// counters (`i`, `x`) or language keywords that happen to be short.
    private static let identifierPattern =
        "\\b[A-Za-z][A-Za-z0-9]*(?:[_-][A-Za-z0-9]+)*\\b"

    /// Common keywords/builtins excluded from the identifier list — they are real words a
    /// developer might dictate in prose too, so boosting them adds noise without helping ASR or
    /// file-tag matching (an identifier list is only useful for names ASR tends to mishear).
    private static let stopWords: Set<String> = [
        "const", "let", "var", "func", "function", "return", "import", "export", "default",
        "class", "struct", "enum", "interface", "extends", "implements", "public", "private",
        "protected", "static", "final", "async", "await", "true", "false", "null", "nil", "self",
        "this", "void", "int", "string", "bool", "float", "double", "if", "else", "for", "while",
        "switch", "case", "break", "continue", "throw", "throws", "try", "catch", "new",
    ]

    struct Result: Sendable {
        let vocabulary: ProjectVocabulary
        let filesScanned: Int
    }

    /// Scans `root` for identifiers and file names. Runs entirely off the calling thread's
    /// isolation via `Task.detached` at the call site (see `ProjectVocabularySettings`) — this
    /// function itself is synchronous and safe to call from a background thread.
    static func scan(root: URL) -> Result {
        let fileManager = FileManager.default
        guard let enumerator = fileManager.enumerator(
            at: root, includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles], errorHandler: nil
        ) else {
            return Result(vocabulary: .empty, filesScanned: 0)
        }

        var identifiers = Set<String>()
        var fileNames = Set<String>()
        var filesScanned = 0

        for case let url as URL in enumerator {
            guard filesScanned < maxFiles else { break }
            let isDirectory = (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
            if isDirectory {
                if skippedDirectoryNames.contains(url.lastPathComponent) {
                    enumerator.skipDescendants()
                }
                continue
            }

            filesScanned += 1
            let name = url.lastPathComponent
            fileNames.insert(name)

            let ext = url.pathExtension.lowercased()
            guard !ext.isEmpty, sourceExtensions.contains(ext), !binaryExtensions.contains(ext) else { continue }
            guard let data = try? Data(contentsOf: url, options: .mappedIfSafe), !data.isEmpty else { continue }
            // A source file large enough that scanning it for identifiers isn't worth the time
            // (a bundled/vendored single-file library, a generated lockfile misclassified by
            // extension) — 2 MB comfortably covers ordinary hand-written source files.
            guard data.count < 2_000_000, let text = String(data: data, encoding: .utf8) else { continue }
            for identifier in extractIdentifiers(from: text) {
                identifiers.insert(identifier)
            }
        }

        return Result(
            vocabulary: ProjectVocabulary(identifiers: Array(identifiers), fileNames: Array(fileNames)),
            filesScanned: filesScanned)
    }

    static func extractIdentifiers(from text: String) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: identifierPattern) else { return [] }
        let ns = text as NSString
        var found = Set<String>()
        regex.enumerateMatches(in: text, range: NSRange(location: 0, length: ns.length)) { match, _, _ in
            guard let match else { return }
            let token = ns.substring(with: match.range)
            guard token.count >= 3, !stopWords.contains(token.lowercased()) else { return }
            // Keep only tokens that actually look like an identifier a developer would dictate:
            // mixed case (camelCase/PascalCase) or containing a separator (snake_case/kebab-case).
            // A plain lowercase or plain uppercase word with no separator is almost certainly
            // ordinary text inside a string literal/comment, not a name worth boosting.
            let hasMixedCase = token.contains { $0.isUppercase } && token.contains { $0.isLowercase }
            let hasSeparator = token.contains("_") || token.contains("-")
            guard hasMixedCase || hasSeparator else { return }
            found.insert(token)
        }
        return Array(found)
    }
}
