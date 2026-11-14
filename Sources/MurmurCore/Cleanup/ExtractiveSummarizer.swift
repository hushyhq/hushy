import Foundation

/// A fast, deterministic fallback summarizer used when no on-device language model is available.
///
/// Scores sentences by the frequency of their content words and keeps the best ones in their
/// original order; action items are sentences phrased as commitments or requests.
public enum ExtractiveSummarizer {
    public struct Output: Sendable, Equatable {
        public let title: String
        public let summary: String
        public let actionItems: [String]
        /// The same items as fields, line for line; nil when the summary has only sentences (the
        /// extractive fallback, which cannot tell who owns what). A list of another length is dropped.
        public let actionDetails: [ActionItemDetail]?

        public init(title: String, summary: String, actionItems: [String], actionDetails: [ActionItemDetail]? = nil) {
            self.title = title
            self.summary = summary
            self.actionItems = actionItems
            self.actionDetails = ActionItemDetail.aligned(actionDetails, count: actionItems.count)
        }
    }

    public static func summarize(_ transcript: String, fallbackTitle: String) -> Output {
        let sentences = Sentences.split(transcript.replacingOccurrences(of: "\n", with: " "))
            .filter { TextStats.wordCount($0) >= 3 }
        guard !sentences.isEmpty else {
            return Output(title: shortTitle(transcript) ?? fallbackTitle, summary: "", actionItems: [])
        }
        // A short note is its own summary: repeating it as one bullet adds nothing. Title it
        // with its opening words instead of the date (the date is already in the meta line).
        if TextStats.wordCount(transcript) < minimumWordsToSummarize {
            return Output(title: shortTitle(transcript) ?? fallbackTitle, summary: "",
                          actionItems: actionItems(in: sentences))
        }

        let frequencies = contentWordFrequencies(sentences)
        let scored = sentences.enumerated().map { index, sentence in
            (index: index, sentence: sentence, score: score(sentence, frequencies))
        }
        let keep = min(max(sentences.count / 6, 2), 6)
        let best = scored.sorted { $0.score > $1.score }.prefix(keep).sorted { $0.index < $1.index }
        let summary = best.map { "- " + Punctuation.stripTrailing($0.sentence) }.joined(separator: "\n")

        return Output(
            title: title(from: frequencies, fallback: fallbackTitle),
            summary: summary,
            actionItems: actionItems(in: sentences)
        )
    }

    /// Same threshold `SmartCleaner.summarize` uses before asking the on-device model.
    public static let minimumWordsToSummarize = 25
    static let shortTitleWords = 6

    /// "Hey, is it actually recording?" → "Hey, is it actually recording"; long openings are
    /// cut at `shortTitleWords` with an ellipsis.
    static func shortTitle(_ transcript: String) -> String? {
        let words = transcript.split(whereSeparator: \.isWhitespace)
        guard !words.isEmpty else { return nil }
        let opening = words.prefix(shortTitleWords).joined(separator: " ")
        let trimmed = Punctuation.stripTrailing(opening)
        guard !trimmed.isEmpty else { return nil }
        let title = trimmed.prefix(1).uppercased() + trimmed.dropFirst()
        return words.count > shortTitleWords ? title + "…" : title
    }

    static func actionItems(in sentences: [String]) -> [String] {
        let pattern = "\\b(?:I'll|I will|we'll|we will|we need to|I need to|need to|let's|should|must|have to|" +
            "make sure|follow up|remind me|action item|to-?do|by (?:monday|tuesday|wednesday|thursday|friday|tomorrow|end of (?:day|week)|eod|next week))\\b"
        var seen = Set<String>()
        return sentences.compactMap { sentence in
            guard Regex.firstMatch(sentence, pattern) != nil, TextStats.wordCount(sentence) <= 40 else { return nil }
            let item = Punctuation.stripTrailing(sentence)
            return seen.insert(item.lowercased()).inserted ? item : nil
        }
        .prefix(10)
        .map { $0 }
    }

    private static func contentWordFrequencies(_ sentences: [String]) -> [String: Int] {
        var counts: [String: Int] = [:]
        for sentence in sentences {
            for word in words(sentence) where !stopwords.contains(word) && word.count > 2 {
                counts[word, default: 0] += 1
            }
        }
        return counts
    }

    private static func score(_ sentence: String, _ frequencies: [String: Int]) -> Double {
        let content = words(sentence).filter { !stopwords.contains($0) && $0.count > 2 }
        guard !content.isEmpty else { return 0 }
        let total = content.reduce(0) { $0 + (frequencies[$1] ?? 0) }
        // Normalize by length so long rambling sentences do not always win.
        return Double(total) / sqrt(Double(content.count))
    }

    private static func title(from frequencies: [String: Int], fallback: String) -> String {
        let top = frequencies.filter { $0.value > 1 }.sorted { $0.value == $1.value ? $0.key < $1.key : $0.value > $1.value }
            .prefix(3).map { $0.key.capitalized }
        return top.count >= 2 ? top.joined(separator: ", ") : fallback
    }

    private static func words(_ text: String) -> [String] {
        text.lowercased().components(separatedBy: CharacterSet.letters.inverted).filter { !$0.isEmpty }
    }

    private static let stopwords: Set<String> = [
        "the", "and", "for", "that", "this", "with", "you", "are", "was", "but", "not", "have", "has", "had",
        "they", "them", "then", "there", "their", "what", "when", "where", "which", "who", "will", "would",
        "can", "could", "should", "about", "into", "just", "like", "your", "our", "from", "all", "also",
        "some", "been", "were", "its", "it's", "i'm", "we're", "don't", "yeah", "okay", "really", "very",
        "going", "get", "got", "know", "think", "one", "out", "his", "her", "she", "him", "how", "why",
        "because", "more", "want", "need", "let", "lets", "did", "does", "doing", "said", "say", "so",
        "than", "too", "any", "these", "those", "here", "now", "well", "much", "many", "make", "sure",
    ]
}
