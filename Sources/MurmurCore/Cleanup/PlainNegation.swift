import Foundation

/// A "not", "no" or "never" that negates what the speaker was saying, as against one that opens a correction.
///
/// The dropped-word checks excuse the words before a correction cue, because a speaker who corrects themselves leaves
/// words behind on purpose ("put the red box not the blue box"). A plain negation ("we do not need the bell") is no
/// correction, and reading it as a cue would excuse a noun lost before it.
enum PlainNegation {
    private static let beforeNot: Set<String> = [
        "do", "does", "did", "will", "would", "can", "could", "should", "shall", "may", "might", "must",
        "have", "has", "had", "to", "also", "just", "really", "always",
    ]
    private static let beforeNo: Set<String> = [
        "is", "are", "was", "were", "be", "been", "has", "have", "had", "got", "do", "does", "did", "with", "without",
        "for", "of", "in", "there's", "here's",
    ]

    static func isPlain(_ words: [String], at index: Int) -> Bool {
        guard words.indices.contains(index) else { return false }
        switch words[index] {
        case "not": return index > 0 && beforeNot.contains(words[index - 1])
        case "no": return index > 0 && beforeNo.contains(words[index - 1])
        case "never": return !(index + 1 < words.count && words[index + 1] == "mind")
        default: return false
        }
    }
}
