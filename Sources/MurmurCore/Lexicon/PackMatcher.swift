import Foundation

/// Finds a pack's names in a piece of text in one pass (Aho–Corasick, `PhraseAutomaton`), case- and accent-blind,
/// on word boundaries. A full name counts ("Victor Wembanyama", "Luka Doncic"), and so does a surname alone when it
/// is long and no English word ("Wembanyama", "Antetokounmpo"): "Green" or "Holiday" never does.
///
/// Build: O(total pattern length). Scan: O(text length + hits), however many names the pack has.
public struct PackMatcher: Sendable {
    public let packID: String
    private let automaton: PhraseAutomaton
    /// For each pattern, the index of the pack term it stands for.
    private let termOfPattern: [Int]

    static let minSurnameLength = 5

    public init(pack: DomainPack) {
        packID = pack.id
        var patterns: [[UInt32]] = []
        var owners: [Int] = []
        var seen = Set<String>()
        var surnameOwners: [String: Int] = [:]
        for (index, term) in pack.terms.enumerated() {
            for form in [term.surface] + term.aliases {
                let folded = Self.fold(form)
                guard !folded.isEmpty, seen.insert(folded).inserted else { continue }
                patterns.append(Self.symbols(folded))
                owners.append(index)
            }
            if term.kind == .person, let last = Self.surname(of: term.surface), surnameOwners[last] == nil {
                surnameOwners[last] = index
            }
        }
        for (surname, index) in surnameOwners.sorted(by: { $0.key < $1.key }) where seen.insert(surname).inserted {
            patterns.append(Self.symbols(surname))
            owners.append(index)
        }
        automaton = PhraseAutomaton(patterns: patterns)
        termOfPattern = owners
    }

    /// Indices of the pack terms named in `text`, each once.
    public func hits(in text: String) -> Set<Int> {
        guard !automaton.isEmpty, !text.isEmpty else { return [] }
        let symbols = Self.symbols(Self.fold(text))
        var found = Set<Int>()
        automaton.scan(symbols) { pattern, end in
            let start = end - Int(automaton.patternLengths[pattern])
            let before = start > 0 ? symbols[start - 1] : 32
            let after = end < symbols.count ? symbols[end] : 32
            if !Self.isWordSymbol(before), !Self.isWordSymbol(after) { found.insert(termOfPattern[pattern]) }
        }
        return found
    }

    /// The last word of a person's name when it is distinctive enough to count alone.
    static func surname(of name: String) -> String? {
        let words = fold(name).split(separator: " ").map(String.init)
            .filter { !LexiconTermShape.nameSuffixes.contains($0) }
        guard words.count >= 2, let last = words.last, last.count >= minSurnameLength,
              last.allSatisfy({ $0.isLetter }), !WordFrequency.shared.isKnown(last) else { return nil }
        return last
    }

    static func fold(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
            .replacingOccurrences(of: "\u{2019}", with: "'")
            .split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    private static func symbols(_ folded: String) -> [UInt32] { folded.unicodeScalars.map(\.value) }

    private static func isWordSymbol(_ value: UInt32) -> Bool {
        guard let scalar = Unicode.Scalar(value) else { return false }
        return PhraseFolding.isWord(scalar)
    }
}
