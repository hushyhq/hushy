import Foundation

/// Paragraph breaks for a long dictation that came out as one block.
///
/// Why it exists: nothing else in the app puts a break into text that has none. The intent model is asked for
/// paragraphs (`IntentCleanupPrompt`) but often answers a 90 to 110 word dictation in one block, and when a guard
/// refuses its answer the rules draft is pasted (`SmartCleaner.rulesFallback`), and the rules only break for a spoken
/// "new paragraph" (`VoiceCommands.applyLineBreaks`). The app log showed both: model answers with no breaks, and answers
/// with breaks thrown away by a guard for a reason that had nothing to do with layout.
///
/// What it does, in three steps:
/// 1. Split the text into sentences. A boundary needs a full stop, question mark or exclamation mark, then a space, then a
///    capital letter or a digit; titles, "p.m.", initials and list numbers do not count.
/// 2. Choose boundaries where a person typing would start a new paragraph: a sentence that opens with a discourse marker
///    ("Also,", "The other thing is", "Anyway,", "Second,", "After that,", a request such as "Can you", a sign-off). A
///    stronger marker wins over a weaker one.
/// 3. Where a stretch still runs longer than `longParagraphWords`, split it at the boundary where the vocabulary changes
///    most (cosine distance between the content words of the sentences on either side, TextTiling style), pulled towards
///    the middle, and never in front of a sentence that leans on the one before it ("It", "This", "And", "Because").
///
/// A break only ever replaces the space between two sentences, so no word, number or mark changes and a break can never
/// fall inside a sentence. Every paragraph keeps at least `minimumParagraphSentences` sentences and
/// `minimumParagraphWords` words, and there is at most one break per `wordsPerBreak` words. Text with any line break in it
/// (a list, a spoken "new paragraph", the model's own paragraphs) is never touched, and neither is a dictation under
/// `minimumWords`, As spoken, code, or a language other than English. English-only because the markers are English words.
///
/// Chat apps where Return sends are safe: the text is delivered by paste (`ClipboardPaster`), and Return is posted only
/// for a spoken "press enter", so a blank line inside a pasted message never sends it.
///
/// Complexity: one pass for the sentences, one pass for the markers, and the long-stretch split looks at each boundary of the
/// stretch once per break chosen, so the whole thing is O(sentences x breaks) with both numbers small.
enum ParagraphLayout {
    /// Under this many words a dictation stays as it is.
    static let minimumWords = 100
    static let minimumParagraphWords = 22
    static let minimumParagraphSentences = 2
    /// A stretch longer than this is split even when no marker is in it.
    static let longParagraphWords = 90
    static let wordsPerBreak = 45
    /// Sentences either side of a candidate boundary that the vocabulary comparison looks at.
    private static let windowSentences = 3
    private static let minimumSentences = 4

    static func apply(_ text: String, options: CleanupOptions) -> String {
        guard options.level != .verbatim, !options.isCodeContext, options.isEnglishOrUnknown else { return text }
        return apply(text)
    }

    static func apply(_ text: String) -> String {
        guard !text.contains("\n"), wordCount(text) >= minimumWords else { return text }
        let found = sentences(in: text)
        guard found.count >= minimumSentences else { return text }
        let breaks = chooseBreaks(found)
        guard !breaks.isEmpty else { return text }
        return render(found, breaks: breaks)
    }

    // MARK: - Sentences

    /// The sentences of `text` in order, each with the whitespace that followed it in the original.
    struct Sentence: Equatable {
        let text: String
        let gapAfter: String
        var words: Int { ParagraphLayout.wordCount(text) }
    }

    static func sentences(in text: String) -> [Sentence] {
        let chars = Array(text)
        var result: [Sentence] = []
        var start = 0
        var index = 0
        while index < chars.count {
            guard ".!?".contains(chars[index]) else { index += 1; continue }
            var end = index
            while end + 1 < chars.count, ".!?".contains(chars[end + 1]) { end += 1 }
            while end + 1 < chars.count, closers.contains(chars[end + 1]) { end += 1 }
            var next = end + 1
            while next < chars.count, chars[next] == " " { next += 1 }
            guard next > end + 1, next < chars.count, opensSentence(chars, at: next),
                  !endsWithAbbreviation(chars, from: start, period: index) else { index = end + 1; continue }
            result.append(Sentence(text: String(chars[start...end]), gapAfter: String(chars[(end + 1)..<next])))
            start = next
            index = next
        }
        if start < chars.count { result.append(Sentence(text: String(chars[start...]), gapAfter: "")) }
        return result
    }

    private static let closers: Set<Character> = ["\"", "'", "\u{201D}", "\u{2019}", ")", "]"]
    private static let openers: Set<Character> = ["\"", "'", "\u{201C}", "\u{2018}", "(", "["]

    private static func opensSentence(_ chars: [Character], at index: Int) -> Bool {
        var position = index
        if openers.contains(chars[position]), position + 1 < chars.count { position += 1 }
        return chars[position].isUppercase || chars[position].isNumber
    }

    /// Words whose full stop is not a sentence end: titles, initials, "p.m.", "etc.", and the number of a list item.
    private static let abbreviations: Set<String> = [
        "mr", "mrs", "ms", "mx", "dr", "prof", "sr", "jr", "st", "vs", "etc", "inc", "ltd", "co", "approx", "dept", "fig",
        "e.g", "i.e", "a.m", "p.m", "u.s", "u.k",
    ]

    private static func endsWithAbbreviation(_ chars: [Character], from start: Int, period: Int) -> Bool {
        guard chars[period] == "." else { return false }
        var begin = period
        while begin > start, !chars[begin - 1].isWhitespace { begin -= 1 }
        let token = String(chars[begin..<period]).lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "\"'(\u{201C}"))
        if token.isEmpty { return true }
        if abbreviations.contains(token) { return true }
        if token.count == 1, token.first?.isLetter == true { return true }
        if token.allSatisfy(\.isNumber) { return period - begin <= 2 }
        return token.contains(".") && token.split(separator: ".").allSatisfy { $0.count == 1 }
    }

    // MARK: - Choosing the breaks

    /// Indices of the sentences that start a new paragraph.
    private static func chooseBreaks(_ sentences: [Sentence]) -> [Int] {
        let counts = sentences.map(\.words)
        let total = counts.reduce(0, +)
        let cap = max(1, total / wordsPerBreak)
        let tokens = sentences.map { contentWords($0.text) }
        var chosen: [Int] = []

        let marked = (1..<sentences.count)
            .map { (strength: markerStrength(sentences[$0].text), index: $0) }
            .filter { $0.strength > 0 }
            .sorted { $0.strength != $1.strength ? $0.strength > $1.strength : $0.index < $1.index }
        for candidate in marked where chosen.count < cap && isValid(chosen + [candidate.index], counts: counts) {
            chosen.append(candidate.index)
        }
        while chosen.count < cap, let next = splitLongestStretch(chosen, counts: counts, tokens: tokens, sentences: sentences) {
            chosen.append(next)
        }
        return chosen.sorted()
    }

    /// Every paragraph the breaks leave has enough sentences and enough words.
    private static func isValid(_ breaks: [Int], counts: [Int]) -> Bool {
        let edges = [0] + breaks.sorted() + [counts.count]
        return zip(edges, edges.dropFirst()).allSatisfy { from, to in
            to - from >= minimumParagraphSentences && counts[from..<to].reduce(0, +) >= minimumParagraphWords
        }
    }

    private static func splitLongestStretch(
        _ chosen: [Int], counts: [Int], tokens: [[String]], sentences: [Sentence]
    ) -> Int? {
        let edges = [0] + chosen.sorted() + [counts.count]
        let stretches = zip(edges, edges.dropFirst())
            .map { (from: $0, to: $1, words: counts[$0..<$1].reduce(0, +)) }
            .filter { $0.words > longParagraphWords }
            .sorted { $0.words > $1.words }
        for stretch in stretches {
            var best: (score: Double, index: Int)?
            for index in (stretch.from + 1)..<stretch.to where isValid(chosen + [index], counts: counts) {
                guard !leansOnPrevious(sentences[index].text) else { continue }
                let left = tokens[max(stretch.from, index - windowSentences)..<index].flatMap { $0 }
                let right = tokens[index..<min(stretch.to, index + windowSentences)].flatMap { $0 }
                let before = counts[stretch.from..<index].reduce(0, +)
                let balance = 1 - abs(Double(before) - Double(stretch.words) / 2) / Double(stretch.words)
                let score = (1 - cosine(left, right)) * 0.5 + balance
                if best == nil || score > best!.score { best = (score, index) }
            }
            if let best { return best.index }
        }
        return nil
    }

    // MARK: - Markers

    /// 2 for a marker that announces a new point, 1 for one that only suggests it, 0 for none. Both are sentence openers.
    static func markerStrength(_ sentence: String) -> Int {
        if strongMarkers.contains(where: { Regex.firstMatch(sentence, $0) != nil }) { return 2 }
        if weakMarkers.contains(where: { Regex.firstMatch(sentence, $0) != nil }) { return 1 }
        return 0
    }

    private static let strongMarkers: [String] = [
        "^(?:also|anyway|anyways|separately|meanwhile|finally|lastly|besides|moreover|furthermore|secondly|thirdly)\\b",
        "^(?:second|third|fourth|fifth),",
        "^(?:the )?(?:other|second|third|fourth|fifth|next|last|final|one more|one last|one other)(?: (?:big|main|important))? (?:thing|point|issue|question|item|topic|step)\\b",
        "^(?:another|one more|one other|one last) (?:thing|point|question|topic)\\b",
        "^(?:on another|on a different) (?:note|topic)\\b",
        "^(?:by the way|as for|moving on|speaking of|in addition|that said|oh,? and|and also|okay,? so|alright,? so)\\b",
        "^(?:thanks|thank you|talk soon|let me know|cheers|regards)\\b",
    ]

    private static let weakMarkers: [String] = [
        "^(?:then|after that|before that|next|now|afterwards|later|first|firstly),?\\s",
        "^(?:on|by|for) (?:monday|tuesday|wednesday|thursday|friday|saturday|sunday|tomorrow|tonight)\\b",
        "^(?:can|could|would|will) you\\b",
        "^please\\b",
        "^(?:do you want|do you think|what do you think)\\b",
    ]

    /// A sentence that continues the one before it: a split in front of it would strand it.
    private static func leansOnPrevious(_ sentence: String) -> Bool {
        Regex.firstMatch(
            sentence,
            "^(?:and|but|or|so|because|which|who|since|though|although|it|its|this|that|these|those|they|their|them|he|she|his|her|there)\\b"
        ) != nil
    }

    // MARK: - Vocabulary comparison

    private static let stopWords: Set<String> = [
        "the", "and", "but", "for", "with", "from", "that", "this", "those", "these", "are", "was", "were", "been", "not",
        "can", "could", "would", "should", "will", "just", "really", "very", "also", "about", "there", "here", "what",
        "when", "which", "who", "how", "why", "into", "over", "one", "some", "any", "all", "more", "most", "like", "get",
        "got", "going", "let", "say", "said", "know", "think", "want", "need", "make", "made", "take", "you", "your",
        "our", "their", "his", "her", "its", "they", "them", "she", "has", "had", "have", "does", "did", "then", "than",
    ]

    static func contentWords(_ sentence: String) -> [String] {
        sentence.lowercased()
            .split(whereSeparator: { !($0.isLetter || $0.isNumber || $0 == "'") })
            .map(String.init)
            .filter { $0.count > 2 && !stopWords.contains($0) }
            .map(stem)
    }

    private static func stem(_ word: String) -> String {
        for suffix in ["ing", "ed", "es", "s"] where word.hasSuffix(suffix) && word.count - suffix.count >= 3 {
            return String(word.dropLast(suffix.count))
        }
        return word
    }

    private static func cosine(_ left: [String], _ right: [String]) -> Double {
        let a = Dictionary(left.map { ($0, 1.0) }, uniquingKeysWith: +)
        let b = Dictionary(right.map { ($0, 1.0) }, uniquingKeysWith: +)
        let dot = a.reduce(0.0) { $0 + $1.value * (b[$1.key] ?? 0) }
        let norm = (a.values.reduce(0) { $0 + $1 * $1 }).squareRoot() * (b.values.reduce(0) { $0 + $1 * $1 }).squareRoot()
        return norm == 0 ? 0 : dot / norm
    }

    // MARK: - Output

    private static func render(_ sentences: [Sentence], breaks: [Int]) -> String {
        let starts = Set(breaks)
        var result = ""
        for (index, sentence) in sentences.enumerated() {
            result += sentence.text
            guard index + 1 < sentences.count else { result += sentence.gapAfter; break }
            result += starts.contains(index + 1) ? "\n\n" : sentence.gapAfter
        }
        return result
    }

    static func wordCount(_ text: String) -> Int {
        text.split(whereSeparator: \.isWhitespace).count
    }
}
