import Foundation

/// One whitespace-delimited run of text, split into surrounding punctuation and a core.
/// Only plain words (letters with at most one inner apostrophe) are `isWord`; everything else
/// (URLs, paths, identifiers, numbers, masked literals) is kept whole and never rewritten.
struct ToneChunk: Equatable {
    var lead: String
    var core: String
    var trail: String
    var gap: String
    var isWord: Bool

    var rendered: String { lead + core + trail + gap }
    var lowered: String { ToneText.normalised(core).lowercased() }
    var gapHasNewline: Bool { gap.contains { $0.isNewline } }
    /// Punctuation or a line break follows this chunk: the clause stops here.
    var endsClause: Bool { !trail.isEmpty || gapHasNewline }
    /// The next chunk continues the same clause after plain spaces.
    var joinsNext: Bool { trail.isEmpty && !gap.isEmpty && gap.allSatisfy { $0 == " " || $0 == "\t" } }

    func replacingCore(_ newCore: String) -> ToneChunk {
        ToneChunk(lead: lead, core: newCore, trail: trail, gap: gap, isWord: isWord)
    }
}

enum ToneText {
    private static let leadMarks: Set<Character> = ["(", "[", "\u{201C}"]
    private static let trailMarks: Set<Character> = [",", ".", ";", ":", "!", "?", ")", "]", "\u{201D}", "\u{2026}"]

    static func normalised(_ text: String) -> String { text.replacingOccurrences(of: "\u{2019}", with: "'") }

    /// Curly when the text already uses curly apostrophes and no straight ones.
    static func apostrophe(for text: String) -> String {
        text.contains("\u{2019}") && !text.contains("'") ? "\u{2019}" : "'"
    }

    static func capitalisingFirst(_ text: String) -> String {
        guard let first = text.first else { return text }
        return first.uppercased() + text.dropFirst()
    }

    /// Gives the replacement the first-letter case of the word it replaces.
    static func matchCase(_ replacement: String, like source: String) -> String {
        source.first?.isUppercase == true ? capitalisingFirst(replacement) : replacement
    }

    /// All lowercase or first letter capital only. "GONNA" and "It Is" are left to the speaker.
    static func hasPlainCase(_ core: String) -> Bool {
        let lower = normalised(core).lowercased()
        let norm = normalised(core)
        return norm == lower || norm == capitalisingFirst(lower)
    }

    static func isPlainWord(_ text: String) -> Bool {
        let chars = Array(text)
        guard !chars.isEmpty else { return false }
        var apostrophes = 0
        for (index, char) in chars.enumerated() {
            if char.isLetter { continue }
            let isApostrophe = char == "'" || char == "\u{2019}"
            guard isApostrophe, index > 0, index < chars.count - 1,
                  chars[index - 1].isLetter, chars[index + 1].isLetter else { return false }
            apostrophes += 1
        }
        return apostrophes <= 1
    }

    static func chunks(of text: String) -> (prefix: String, chunks: [ToneChunk]) {
        let chars = Array(text)
        var cursor = 0
        var prefix = ""
        while cursor < chars.count, chars[cursor].isWhitespace { prefix.append(chars[cursor]); cursor += 1 }
        var result: [ToneChunk] = []
        while cursor < chars.count {
            var run = ""
            while cursor < chars.count, !chars[cursor].isWhitespace { run.append(chars[cursor]); cursor += 1 }
            var gap = ""
            while cursor < chars.count, chars[cursor].isWhitespace { gap.append(chars[cursor]); cursor += 1 }
            result.append(classify(run, gap: gap))
        }
        return (prefix, result)
    }

    static func render(prefix: String, chunks: [ToneChunk]) -> String {
        prefix + chunks.map(\.rendered).joined()
    }

    private static func classify(_ run: String, gap: String) -> ToneChunk {
        var core = Array(run)
        var lead = ""
        var trail = ""
        while let first = core.first, leadMarks.contains(first) { lead.append(first); core.removeFirst() }
        while let last = core.last, trailMarks.contains(last) { trail.insert(last, at: trail.startIndex); core.removeLast() }
        let coreText = String(core)
        guard isPlainWord(coreText) else {
            return ToneChunk(lead: "", core: run, trail: "", gap: gap, isWord: false)
        }
        return ToneChunk(lead: lead, core: coreText, trail: trail, gap: gap, isWord: true)
    }
}
