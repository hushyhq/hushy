import Foundation

/// Optional per-project vocabulary for the code style: identifiers and file names scanned from
/// a folder the user picked (see `CleanupOptions.isCodeContext`, `CodeFileTags`, and the
/// project-scanning code in the app target). Pure data + matching here so it can be built,
/// tested and applied without any file-system access — the actual folder scan lives in the app
/// target (`ProjectVocabularyScanner`) since `MurmurCore` has no Foundation file-enumeration
/// dependency policy to keep it testable without a real disk.
public struct ProjectVocabulary: Sendable, Equatable, Codable {
    /// Source code identifiers found in the project (function/type/variable names), used to
    /// boost ASR and to map a spoken near-miss to its exact spelling.
    public let identifiers: [String]
    /// File names found in the project (basename only, e.g. "index.tsx"), used for "@name.ext"
    /// tagging (see `CodeFileTags`).
    public let fileNames: [String]

    public init(identifiers: [String] = [], fileNames: [String] = []) {
        self.identifiers = identifiers
        self.fileNames = fileNames
    }

    public static let empty = ProjectVocabulary()

    public var isEmpty: Bool { identifiers.isEmpty && fileNames.isEmpty }

    /// Terms to bias ASR towards, same shape `VocabularyContext` already consumes for the
    /// user's Dictionary — see `VocabularyContext.from(dictionary:)`. Project vocabulary carries
    /// no `soundsLike` aliases (those come only from the user's explicit Dictionary entries);
    /// it boosts by exact/near-exact spelling match instead (see `matchIdentifier`/`matchFile`).
    public var vocabularyTerms: [VocabularyTerm] {
        (identifiers + fileNames).map { VocabularyTerm(text: $0) }
    }

    /// Finds the identifier that best matches `spoken` (case-insensitive), only when the match
    /// is exact or near-exact (edit distance <= 1 for words of 4+ characters, exact for
    /// shorter words) — a loose match risks silently substituting the wrong identifier, which
    /// costs far more than leaving a slightly-off spoken word alone.
    public func matchIdentifier(_ spoken: String) -> String? {
        Self.bestMatch(spoken, in: identifiers)
    }

    /// Same matching rule as `matchIdentifier`, but scoped to file names and matched against a
    /// spoken "name.ext" or "name dot ext" candidate — see `CodeFileTags`.
    public func matchFile(_ spoken: String) -> String? {
        Self.bestMatch(spoken, in: fileNames)
    }

    static func bestMatch(_ spoken: String, in candidates: [String]) -> String? {
        let needle = spoken.lowercased()
        guard !needle.isEmpty else { return nil }
        if let exact = candidates.first(where: { $0.lowercased() == needle }) { return exact }
        // Near-exact only: short words (<=3 chars) require an exact match, since edit distance 1
        // on a 3-letter word is really a different word ("cat" vs "car"). Longer words tolerate
        // one insertion/deletion/substitution — enough to cover a dropped/misheard letter without
        // opening the door to unrelated identifiers matching by coincidence.
        guard needle.count > 3 else { return nil }
        var best: (candidate: String, distance: Int)?
        for candidate in candidates {
            let lower = candidate.lowercased()
            guard abs(lower.count - needle.count) <= 1 else { continue }
            let distance = levenshtein(needle, lower)
            if distance <= 1, best == nil || distance < best!.distance {
                best = (candidate, distance)
            }
        }
        return best?.candidate
    }

    /// Standard edit distance (insert/delete/substitute), used only for short near-miss checks
    /// above — identifiers and file names are short enough that the O(n*m) table is negligible.
    static func levenshtein(_ a: String, _ b: String) -> Int {
        let aChars = Array(a), bChars = Array(b)
        if aChars.isEmpty { return bChars.count }
        if bChars.isEmpty { return aChars.count }
        var previous = Array(0...bChars.count)
        var current = [Int](repeating: 0, count: bChars.count + 1)
        for i in 1...aChars.count {
            current[0] = i
            for j in 1...bChars.count {
                if aChars[i - 1] == bChars[j - 1] {
                    current[j] = previous[j - 1]
                } else {
                    current[j] = 1 + min(previous[j - 1], previous[j], current[j - 1])
                }
            }
            previous = current
        }
        return previous[bChars.count]
    }
}
