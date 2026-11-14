import Foundation

/// How common a word is in written English, on the Zipf scale (log10 of occurrences per billion words:
/// "the" about 7.7, "email" 5.3, "podcast" 4.2, a name or a brand under 2.5, nothing known 0).
///
/// It replaces the system dictionary as the answer to "is this an ordinary word?" in the boost guards, the
/// learner and the drift guard. The dictionary said yes or no, and it was wrong both ways: "email", "website"
/// and "podcast" were not in it, and "codex" and "anthropic" were. A grade lets each caller pick its own line
/// (`ordinaryThreshold`, `knownThreshold`) and lets a later step weigh the grade instead of a yes or no.
///
/// The data is `WordFrequencyData`: about 87,000 lowercase word forms and their grades, from word counts over
/// 250 million words of C4 (ODC-By 1.0); `docs/engineering/WORD-FREQUENCY.md` has the source, the licence and
/// the attribution. It lives in the binary as one string; nothing is read from disk, parsed or copied: the first
/// lookup indexes where each entry starts (about a millisecond), every lookup after that is a binary search.
public struct WordFrequency {
    /// A word at or above this grade is an ordinary English word: protected from boosts, never learned as a name.
    /// Chosen on the vocabulary lists in `Evals/lexicon-b3a.json` (see DECISIONS 2026-10-28).
    public static let ordinaryThreshold = 2.5
    /// The line for words of one or two letters, where the table is full of abbreviations.
    public static let shortOrdinaryThreshold = 5.5
    /// A word at or above this grade is English at all, however rare: what the drift guard counts as a known word.
    public static let knownThreshold = 1.75

    /// The table as it ships.
    public static let shared = WordFrequency(table: WordFrequencyData.table)

    private let bytes: UnsafeBufferPointer<UInt8>
    /// Where each entry starts, plus the end of the table.
    private let starts: [Int32]

    /// An index over any table in the shipped format (the shipped one, or a small one in a test).
    init(table: StaticString) {
        bytes = UnsafeBufferPointer(start: table.utf8Start, count: table.utf8CodeUnitCount)
        var found: [Int32] = [0]
        found.reserveCapacity(WordFrequencyData.entryCount + 1)
        for (offset, byte) in bytes.enumerated() where byte >= 0x41 && byte <= 0x5A { found.append(Int32(offset + 1)) }
        starts = found
    }

    public var entryCount: Int { starts.count - 1 }
    /// Size of the table in the binary.
    public var tableByteCount: Int { bytes.count }

    /// The grade of `word` as written or, failing that, of its stem for a regular inflection ("voices", "invited",
    /// "stopped", "quickly"): the larger of the two, so a form missing from the table is not worse than its base.
    /// 0 when neither is known. A form that grades 5.5 or more stands as it is (no line is above that).
    public func zipf(_ word: String) -> Double {
        let key = Self.normalized(word)
        guard !key.isEmpty else { return 0 }
        var best = exact(key)
        if best >= 5.5 { return best }
        for stem in Self.stems(of: key) { best = max(best, exact(stem)) }
        return best
    }

    /// A two-letter token is an ordinary word only if it is one of the few real ones, all of which grade 5.75 or more
    /// ("to", "go", "am"); "vs", "pm", "tv" and "id" grade 4 to 4.75 and are abbreviations, not words people mishear.
    public func isOrdinary(_ word: String) -> Bool {
        zipf(word) >= (word.count <= 2 ? Self.shortOrdinaryThreshold : Self.ordinaryThreshold)
    }
    public func isKnown(_ word: String) -> Bool { zipf(word) >= Self.knownThreshold }

    /// Grade of this exact form, 0 if absent.
    func exact(_ key: String) -> Double {
        var key = key
        return key.withUTF8 { lookup($0) }
    }

    private func lookup(_ needle: UnsafeBufferPointer<UInt8>) -> Double {
        guard !needle.isEmpty, needle.allSatisfy({ $0 == 0x27 || ($0 >= 0x61 && $0 <= 0x7A) }) else { return 0 }
        var low = 0, high = entryCount - 1
        while low <= high {
            let middle = (low + high) / 2
            let start = Int(starts[middle]), end = Int(starts[middle + 1]) - 1
            let order = compare(needle, withWordAt: start, upTo: end)
            if order == 0 { return 1.5 + 0.25 * Double(bytes[end] - 0x41) }
            if order < 0 { high = middle - 1 } else { low = middle + 1 }
        }
        return 0
    }

    /// Order of the needle against the word in `bytes[start..<end]`.
    private func compare(_ needle: UnsafeBufferPointer<UInt8>, withWordAt start: Int, upTo end: Int) -> Int {
        let length = end - start
        for index in 0..<min(needle.count, length) {
            let a = needle[index], b = bytes[start + index]
            if a != b { return a < b ? -1 : 1 }
        }
        return needle.count == length ? 0 : (needle.count < length ? -1 : 1)
    }

    static func normalized(_ word: String) -> String {
        let lowered = word.lowercased()
        return lowered.contains("\u{2019}") ? lowered.replacingOccurrences(of: "\u{2019}", with: "'") : lowered
    }

    /// Candidate base forms of a regular inflection, the same rules the system-dictionary check used.
    static func stems(of word: String) -> [String] {
        let suffixes: [(String, [String])] = [
            ("ies", ["y"]), ("ied", ["y"]), ("es", ["", "e"]), ("s", [""]), ("ed", ["", "e"]),
            ("d", [""]), ("ing", ["", "e"]), ("ly", [""]), ("'s", [""]),
        ]
        var result: [String] = []
        for (suffix, replacements) in suffixes where word.hasSuffix(suffix) && word.count > suffix.count + 2 {
            let stem = String(word.dropLast(suffix.count))
            result += replacements.map { stem + $0 }
            // Doubled consonant: "stopped" -> "stop".
            if suffix == "ed" || suffix == "ing", let last = stem.last, stem.dropLast().last == last { result.append(String(stem.dropLast())) }
        }
        return result
    }
}

/// The bytes are an immutable string literal in the binary and `starts` is never changed after `init`.
extension WordFrequency: @unchecked Sendable {}
