import Foundation

/// Capitalized names in the same bounded screen read. Unlike recognizer vocabulary, this
/// only corroborates a correction the person types; it never proposes a replacement.
public enum ScreenTermEvidence {
    public static func extract(from text: String) -> [String] {
        let window = String(text.suffix(ContextExtractor.maxWindowLength))
        var seen = Set<String>()
        return ContextExtractor.capitalizedWords(in: window).filter { word in
            let key = word.lowercased()
            return word.count <= 64 && !ContextExtractor.commonWordDenylist.contains(key)
                && !ScreenBoostPolicy.uiLabelDenylist.contains(key) && seen.insert(key).inserted
        }.prefix(ContextExtractor.maxTerms).map { $0 }
    }
}
