import Foundation

/// What a listed file looks like to a spoken pick: its place in the list, kind, date, folder, name.
public struct FilePickRow: Sendable, Equatable {
    public let name: String
    public let kinds: Set<FileKind>
    public let modified: Date?
    public let folder: String

    public init(name: String, kinds: Set<FileKind>, modified: Date?, folder: String) {
        self.name = name
        self.kinds = kinds
        self.modified = modified
        self.folder = folder
    }
}

/// Picks one file from the list on the card by what the person says next: "the first one", "the
/// PDF", "the one from March", "the newest", "the one in Downloads", "open the second". Closed
/// vocabulary; anything it can't settle is said back, never guessed.
public enum FilePick {
    public enum Result: Sendable, Equatable {
        case picked(index: Int, open: Bool)
        /// A pick, but more than one file fits ("the PDF" with two PDFs).
        case several
        /// A pick, but no listed file fits.
        case noMatch
        /// Not a pick at all: the utterance goes on as an ordinary follow-up.
        case notAPick
    }

    static let ordinals: [String: Int] = [
        "first": 0, "1st": 0, "one": 0, "second": 1, "2nd": 1, "two": 1, "third": 2, "3rd": 2, "three": 2,
        "fourth": 3, "4th": 3, "four": 3, "fifth": 4, "5th": 4, "five": 4,
        "sixth": 5, "seventh": 6, "eighth": 7, "ninth": 8, "tenth": 9,
    ]
    static let newestWords: Set<String> = ["newest", "latest", "newer", "recent", "newest"]
    static let oldestWords: Set<String> = ["oldest", "older", "earliest"]
    static let fillers: Set<String> = [
        "the", "a", "an", "that", "this", "one", "ones", "open", "show", "reveal", "pick", "choose", "take", "use",
        "select", "go", "with", "it", "is", "its", "it's", "i", "mean", "want", "please", "from", "in", "on", "of",
        "number", "file", "my", "me", "um", "uh", "yes", "yeah", "no", "not", "folder",
    ]

    static let questionOpeners: Set<String> = [
        "what", "what's", "how", "why", "who", "when", "where", "is", "are", "do", "does", "can", "tell", "explain",
        "summarize", "summarise", "read", "add", "remind", "ask", "find", "search",
    ]

    public static func resolve(
        _ utterance: String, rows: [FilePickRow], now: Date = Date(), calendar: Calendar = .current
    ) -> Result {
        guard !rows.isEmpty else { return .notAPick }
        var words = FileRouter.prepared(AskRouter.frame(utterance))
        guard let opening = words.first, words.count <= 8, !questionOpeners.contains(opening) else { return .notAPick }
        let opens = words.contains("open")
        var candidates = Array(rows.indices)
        var recognised = false

        if let location = FileRouter.takeLocation(&words) {
            recognised = true
            candidates = candidates.filter { rows[$0].folder.lowercased().contains("/" + location.rawValue) }
        }
        // "newest" and "last" are picks of their own below, not a time hint.
        let beforeTime = words
        if let time = FileRouter.takeTime(&words, now: now, calendar: calendar), time != .recent {
            recognised = true
            candidates = candidates.filter { index in
                rows[index].modified.map { FileRanker.timeMatches(time, date: $0, calendar: calendar) } ?? false
            }
        } else {
            words = beforeTime
        }
        var ordinal: Int?
        var newest = false
        var oldest = false
        var last = false
        var nameTerms: [String] = []
        var kind: FileKind?
        for (position, word) in words.enumerated() {
            if let entry = FileRouter.kindWord(word) {
                kind = entry.kind
                recognised = true
            } else if let value = ordinals[word], !(word == "one" && !isCountingOne(words, at: position)) {
                ordinal = value
                recognised = true
            } else if word == "last" || word == "final" {
                last = true
                recognised = true
            } else if newestWords.contains(word) {
                newest = true
                recognised = true
            } else if oldestWords.contains(word) {
                oldest = true
                recognised = true
            } else if !fillers.contains(word), !FileVocabulary.termStopWords.contains(word) {
                nameTerms.append(word)
            }
        }
        // Other words count only when they appear in a listed name ("the one called budget").
        let named = nameTerms.filter { term in rows.contains { $0.name.lowercased().contains(FileVocabulary.singular(term)) } }
        if !named.isEmpty {
            recognised = true
            candidates = candidates.filter { index in
                named.allSatisfy { rows[index].name.lowercased().contains(FileVocabulary.singular($0)) }
            }
        }
        // One file on the card: "open it", "show it in Finder".
        if !recognised, rows.count == 1, nameTerms.allSatisfy({ $0 == "finder" }),
           opens || words.contains("show") || words.contains("reveal") {
            return .picked(index: 0, open: opens)
        }
        guard recognised else { return .notAPick }
        if let kind {
            candidates = candidates.filter { kind == .any || primaryKind(rows[$0].kinds) == kind }
        }
        if newest || oldest {
            let dated = candidates.filter { rows[$0].modified != nil }
            let pickOne = newest ? dated.max { rows[$0].modified! < rows[$1].modified! } : dated.min { rows[$0].modified! < rows[$1].modified! }
            candidates = pickOne.map { [$0] } ?? []
        }
        if last { candidates = candidates.last.map { [$0] } ?? [] }
        if let ordinal {
            candidates = candidates.indices.contains(ordinal) ? [candidates[ordinal]] : []
        }
        switch candidates.count {
        case 0: return .noMatch
        case 1: return .picked(index: candidates[0], open: opens)
        default: return .several
        }
    }

    /// What a listed file is called when it is several things: a PDF is a PDF here, not "a document".
    static func primaryKind(_ kinds: Set<FileKind>) -> FileKind? {
        [FileKind.folder, .pdf, .presentation, .spreadsheet, .image, .document].first { kinds.contains($0) }
    }

    /// "one" is an ordinal only as in "the one" is not: "number one", "one" alone, or "the first one"
    /// has "first" doing the work. Counts "one" only after "number" or as the lone word.
    private static func isCountingOne(_ words: [String], at position: Int) -> Bool {
        words.count == 1 || (position > 0 && words[position - 1] == "number")
    }
}
