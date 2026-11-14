import Foundation

/// Keeps a pack name the recogniser already wrote. A pack in the boost list holds many similar names, and the CTC
/// pass can trade a name it heard correctly for a better-known one that shares a word ("Anthony Edwards" for
/// "Anthony Davis", "Amen Thompson" for "Klay Thompson", measured on `murmur-eval lexicon-pack`). After `BoostGuard`,
/// any changed region whose original words named a pack player that the boosted text no longer names goes back
/// to what was heard. A misheard name ("Wembanaima") names no one, so its fix stands.
///
/// Runs only when the vocabulary holds pack terms (`VocabularyTerm.fromPack`). Cost: one Aho–Corasick scan of the
/// transcript per changed region, against matchers built once.
public enum PackNameGuard {
    public static let matchers: [PackMatcher] = DomainPackCatalog.usable.map(PackMatcher.init(pack:))

    public static func keepHeardNames(original: String, boosted: String, matchers: [PackMatcher] = Self.matchers) -> String {
        guard original != boosted, !matchers.isEmpty else { return boosted }
        let heard = names(in: original, matchers)
        guard !heard.isEmpty, !heard.isSubset(of: names(in: boosted, matchers)) else { return boosted }
        let before = original.split(whereSeparator: \.isWhitespace).map(String.init)
        let after = boosted.split(whereSeparator: \.isWhitespace).map(String.init)
        let regions = BoostGuard.align(before.map(BoostGuard.key), after.map(BoostGuard.key))
        // Each region as (words heard, words boosted); `revert` picks the heard words for a changed region.
        var pieces: [(old: [String], new: [String])] = regions.map { region in
            switch region {
            case .same(let range): (Array(after[range]), Array(after[range]))
            case .changed(let old, let new): (Array(before[old]), Array(after[new]))
            }
        }
        var revert = [Bool](repeating: false, count: pieces.count)
        func text() -> String {
            pieces.indices.flatMap { revert[$0] ? pieces[$0].old : pieces[$0].new }.joined(separator: " ")
        }
        var kept = heard.intersection(names(in: text(), matchers)).count
        for index in pieces.indices where pieces[index].old != pieces[index].new {
            revert[index] = true
            let recovered = heard.intersection(names(in: text(), matchers)).count
            if recovered > kept { kept = recovered } else { revert[index] = false }
        }
        pieces = pieces.enumerated().map { revert[$0.offset] ? ($0.element.old, $0.element.old) : $0.element }
        return pieces.flatMap(\.new).joined(separator: " ")
    }

    private static func names(in text: String, _ matchers: [PackMatcher]) -> Set<String> {
        var found = Set<String>()
        for matcher in matchers { for hit in matcher.hits(in: text) { found.insert("\(matcher.packID):\(hit)") } }
        return found
    }
}
