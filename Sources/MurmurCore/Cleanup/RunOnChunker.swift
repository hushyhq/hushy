import Foundation

/// Splits one long, unpunctuated run-on ("so right now the sidebar basically shows every project
/// right and i think that's actually kind of too much because like when you have twenty projects
/// …") into model-sized pieces, so a long dictation with no sentence punctuation still reaches the
/// on-device model instead of being skipped as "too long for model budget". `TextSegmentation`
/// can only split on sentence punctuation; this is what it falls back to for a sentence longer
/// than `hardCapWords`.
///
/// Cuts happen *before* a boundary word, preferring (in order):
/// 1. a strong boundary — a discourse restart ("so", "okay", "anyway", "but", "and then", "then"),
///    or the start of a direct question ("what do you think", "should we", "can you", "is it");
/// 2. a medium boundary — "because", "i think", "maybe";
/// 3. a weak boundary — "and", "or", "when";
/// 4. the hard cap, as a last resort.
/// A cut never lands immediately before a correction cue or within four words after one, so a
/// "12th no wait the 19th" correction always stays in one piece with what it corrects — nor
/// inside a spoken number, date or time ("two hundred and twenty five", "March twenty first",
/// "four fifteen"; see `NumberPhrase`), not even at the hard cap.
///
/// Prefix-stable: each cut is decided from at most `hardCapWords` words after the previous cut
/// plus a two-word lookahead, and a sentence is only cut while more than `hardCapWords` words
/// remain, so as streaming ASR confirms more text, earlier pieces don't change (the one
/// exception: a final stub of fewer than `minTailWords` words is merged into the piece before
/// it). See `RunOnChunkerTests`.
public enum RunOnChunker {
    public static let minPieceWords = 10
    public static let softMaxWords = 18
    /// Matches `TextSegmentation.maxGroupWords`: a piece is a group (see its doc for the sizing).
    public static let hardCapWords = 26
    static let minTailWords = 6
    private static let correctionShadow = 4

    public static func split(_ sentence: String) -> [String] {
        let tokens = sentence.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
        guard tokens.count > hardCapWords else { return [sentence] }
        let keys = tokens.map(LegitDoubles.key)
        var pieces: [String] = []
        var start = 0
        while tokens.count - start > hardCapWords {
            let cut = chooseCut(keys, from: start)
            pieces.append(tokens[start..<cut].joined(separator: " "))
            start = cut
        }
        // A stub tail (a hard-cap cut can leave one or two words) rides along with the piece
        // before it rather than costing a model call of its own.
        if tokens.count - start < minTailWords, let last = pieces.popLast() {
            pieces.append(last + " " + tokens[start...].joined(separator: " "))
        } else {
            pieces.append(tokens[start...].joined(separator: " "))
        }
        return pieces
    }

    /// Index to cut before, in `(start + minPieceWords)...(start + hardCapWords)`.
    static func chooseCut(_ keys: [String], from start: Int) -> Int {
        let lower = start + minPieceWords
        let upper = min(start + hardCapWords, keys.count - 1)
        guard lower <= upper else { return min(start + hardCapWords, keys.count) }
        var best: (index: Int, score: Int)?
        for index in lower...upper {
            let score = boundaryScore(keys, at: index, pieceStart: start)
            guard score > 0 else { continue }
            if score >= 3 { return index }
            // Medium/weak boundaries only win once the piece is already comfortably sized; keep
            // the latest best-scoring one seen so far.
            if best == nil || score >= best!.score { best = (index, score) }
            if index - start >= softMaxWords, let best, best.score >= 2 { return best.index }
        }
        return best?.index ?? hardCapCut(keys, lower: lower, cap: min(start + hardCapWords, keys.count))
    }

    /// The hard-cap cut, moved back (never below `lower`) until it is outside a number phrase.
    static func hardCapCut(_ keys: [String], lower: Int, cap: Int) -> Int {
        stride(from: cap, through: lower, by: -1).first { !NumberPhrase.isInside(keys, cutBefore: $0) } ?? cap
    }

    private static let correctionCues: Set<String> = [
        "no", "nope", "actually", "wait", "sorry", "scratch", "forget", "mean", "meant", "instead",
        "rather", "oops", "correction", "cancel", "skip",
    ]
    /// Words after which a cut would strand a fragment ("the | so-called", "is | so good").
    private static let bindsForward: Set<String> = [
        "the", "a", "an", "is", "was", "are", "were", "be", "been", "not", "very", "and", "or", "to",
        "of", "just", "really", "even", "if", "that", "than", "it's", "i", "we", "you", "they",
        "should", "would", "could", "can", "will", "do", "does", "did", "my", "our", "your",
        "by", "at", "in", "on", "for", "with", "from", "into", "about", "after", "before", "until",
        "since", "like",
    ]
    private static let soFollowersNotDiscourse: Set<String> = [
        "that", "much", "many", "far", "long", "good", "bad", "called", "so", "far", "little", "few",
    ]
    private static let questionAuxiliaries: Set<String> = ["should", "can", "could", "is", "are", "do", "does", "would", "will", "did"]
    private static let questionSubjects: Set<String> = ["we", "you", "i", "it", "they", "that", "there"]

    /// 3 strong, 2 medium, 1 weak, 0 no boundary before `keys[index]`.
    static func boundaryScore(_ keys: [String], at index: Int, pieceStart: Int) -> Int {
        guard index > pieceStart, index < keys.count else { return 0 }
        let word = keys[index]
        let previous = keys[index - 1]
        let next = index + 1 < keys.count ? keys[index + 1] : ""
        let afterNext = index + 2 < keys.count ? keys[index + 2] : ""
        if correctionCues.contains(word) || next == "mean" && word == "i" { return 0 }
        let shadowStart = max(pieceStart, index - correctionShadow)
        if keys[shadowStart..<index].contains(where: correctionCues.contains) { return 0 }
        if bindsForward.contains(previous) { return 0 }
        if NumberPhrase.isInside(keys, cutBefore: index) { return 0 }

        switch word {
        case "so":
            return soFollowersNotDiscourse.contains(next) ? 0 : 3
        case "okay", "anyway", "but":
            return 3
        case "and":
            if next == "then" { return 3 }
            if ["i", "we", "they", "it's", "i'm", "i've"].contains(next) { return 2 }
            return 1
        case "then":
            // "if … then …" keeps the conditional together.
            let window = keys[max(pieceStart, index - 10)..<index]
            return window.contains("if") ? 0 : 3
        case "what":
            return next == "do" && afterNext == "you" ? 3 : 0
        case "because", "maybe":
            return 2
        case "or", "when":
            return 1
        default:
            break
        }
        if word == "i", next == "think" { return 2 }
        if questionAuxiliaries.contains(word), questionSubjects.contains(next), previous != "or",
           !QuestionPunctuation.whWords.contains(previous) {
            return 3
        }
        return 0
    }
}
