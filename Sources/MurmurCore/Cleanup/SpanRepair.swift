import Foundation

/// Keeps the part of a model answer a check accepts and puts back only the span it objects to.
///
/// A guard that objects to one word used to throw away the whole answer, including the disfluency
/// and grammar fixes around it. The answer is compared with the rules draft word by word; each place
/// where they differ is a hunk (a stretch of draft words and the stretch the model wrote instead).
/// A hunk is applied on its own to the draft and judged by the same check that objected. A hunk that
/// trips it alone is put back; the others stay.
///
/// What makes this safe, and where it stops:
/// - It only runs for a check whose objection belongs to a place in the text (a changed number, name,
///   negation, connective or protected term, a dropped or replaced content word), never for a check
///   about the answer as a whole (length, layout, list structure, a retraction the answer kept).
/// - A hunk is reverted only when that hunk alone makes the same check fire on an otherwise untouched
///   draft, and only when the draft itself passes that check. So it never blames a hunk for a problem
///   the draft already has, and never reverts one that is innocent.
/// - If no single hunk trips the check (the objection is collective, like a count of added words), or every
///   hunk trips it, there is no repair: nothing of the model's would be kept, so the person would get the rules
///   draft under the label of a model pass. The answer then goes to the guided retry and, failing that, falls back
///   to the plain text with the check's code named, as it always did.
/// - The repaired text then goes back through every check. A repair that fails any of them is not used.
///
/// A hunk can hold more than the piece a check wants kept: when the model dropped a small protected piece and
/// reworded the words next to it in the same breath, the two changes are one hunk, and putting the hunk back would
/// undo the rewording too. For the checks in `restorableCodes` the piece alone is put back into the model's words
/// instead (see `restoring`); where the piece cannot be found or placed with certainty the whole hunk goes back as before.
struct SpanRepair {
    /// One difference: draft words `[draftStart, draftEnd)` become `answer`. A pure insertion has an
    /// empty draft range; a pure deletion has an empty answer.
    struct Hunk: Equatable {
        let draftStart: Int
        let draftEnd: Int
        let answer: [String]
    }

    /// The guard families whose objection is attributable to one hunk.
    static let localCodes: Set<GuardCode> = [
        .changedDigits, .droppedNumber, .changedName, .addedNegation, .droppedNegation, .changedConnective,
        .changedProtectedTerm, .changedUnmarkedWord, .droppedContentWords, .replacedContentWords,
        .droppedStanceWord, .droppedHedge, .changedAddress, .droppedContrastiveActually,
        .droppedIdentifier, .droppedPurposePhrase, .droppedTrailOff,
        // One word or one short span the answer lost or changed: the leading request, a clause before a hedge, an
        // admission or clarification lead-in, a marked word, a doubled word, a modal, a question mark, a trailing
        // clause, a grammar word. Each is put back alone and the rest of the answer stays.
        .droppedLeadingRequest, .droppedClauseBeforeHedge, .collapsedDoubledWord, .droppedAdmission,
        .droppedClarificationLeadIn, .droppedMarkedWord, .changedModalOrQuantifier, .changedQuestionOrEmphasis,
        .droppedTrailingClause, .changedLocalGrammarWord,
        // A code-shaped token or a quoted string the answer changed (see `CodeContextGuard`): put back alone.
        .changedCodeText,
    ]

    /// The checks whose objection is a short piece of the speaker's own words the answer lost, and for which the piece
    /// can be put back into the model's wording with the words around it kept (see `restoring`).
    ///
    /// Why these: the piece is a stance or lead-in word or phrase ("actually", a hedge, a purpose phrase, an admission,
    /// a clarification lead-in, a marked word, a stutter-free identifier letter). Put back next to the word it stood
    /// beside, it is the speaker's own word in the speaker's own order, and it does not bind to a value.
    ///
    /// Why not the others: a number or a negation (`droppedNumber`, `droppedNegation`) decides what a sentence says, and
    /// beside reworded words it could be paired with the wrong noun, so the whole span goes back to the speaker's words.
    /// A clause (`droppedLeadingRequest`, `droppedClauseBeforeHedge`, `droppedTrailingClause`) is too long to place by its
    /// neighbours. `droppedContentWords` names scattered words and `droppedTooMuch` is a count over the whole answer, so
    /// neither points at one place. A doubled word or a trail-off is a single token and goes back alone already.
    static let restorableCodes: Set<GuardCode> = [
        .droppedContrastiveActually, .droppedHedge, .droppedStanceWord, .droppedPurposePhrase, .droppedAdmission,
        .droppedClarificationLeadIn, .droppedMarkedWord, .droppedIdentifier,
    ]
    /// The longest piece put back, in words ("what I mean is that" is the longest lead-in a check names).
    static let maximumRestoredWords = 5
    /// A hunk that reaches over more draft words than this has been reworded too much to place a piece in it.
    static let maximumRestoredHunkWords = 10

    let draftWords: [String]
    let hunks: [Hunk]

    init(draft: String, answer: String) {
        draftWords = Self.tokens(draft)
        hunks = Self.hunks(from: draftWords, to: Self.tokens(answer))
    }

    /// The draft with exactly the hunks at `kept` applied.
    /// A hunk in `replacing` is applied with those words in place of the model's.
    func text(applying kept: Set<Int>, replacing: [Int: [String]] = [:]) -> String {
        var out: [String] = []
        var cursor = 0
        for (index, hunk) in hunks.enumerated() {
            out += draftWords[cursor..<hunk.draftStart]
            if kept.contains(index) { out += replacing[index] ?? hunk.answer } else { out += draftWords[hunk.draftStart..<hunk.draftEnd] }
            cursor = hunk.draftEnd
        }
        out += draftWords[cursor...]
        return out.joined(separator: " ")
    }

    /// What a repair attempt came to.
    enum Attempt {
        /// Some spans went back and something of the model's stayed.
        case repaired(text: String, reverted: Int)
        /// Every change the model made is one the check objects to: nothing of its work would be kept.
        case allGuilty
        /// No repair applies (layout, a draft that already trips the check, or no single span to blame).
        case none
    }

    /// The repaired answer, or nil when no repair applies. `objects` is the check that fired on the
    /// whole answer, asked about a candidate text.
    static func repair(draft: String, answer: String, restoring: Bool = false, objects: (String) -> Bool) -> (text: String, reverted: Int)? {
        if case .repaired(let text, let reverted) = attempt(draft: draft, answer: answer, restoring: restoring, objects: objects) {
            return (text, reverted)
        }
        return nil
    }

    /// `restoring` says the check's objection is a piece that can be put back alone (`restorableCodes`): a hunk that
    /// trips it and holds more than the piece keeps the model's words and gets the piece back, where it would otherwise
    /// go back whole. `narrowing` says a hunk that trips the check goes back as the shortest run of its own draft words
    /// the check accepts (see `narrowing(hunk:objects:)`), which keeps the model's deletion of a filler next to it; it is
    /// for the whole-transcript model, whose hunks run against the unedited words. `reverted` counts every kind of repair.
    ///
    /// `keepingLineBreaks` is for the whole-transcript model, whose answer lays a long dictation out in paragraphs or a list:
    /// each line break (of the answer and of the draft) is a word of its own while the spans are compared, so it stays where
    /// the model put it and is judged with the text around it.
    static func attempt(
        draft: String, answer: String, restoring: Bool = false, narrowing: Bool = false, keepingLineBreaks: Bool = false,
        objects: (String) -> Bool
    ) -> Attempt {
        if keepingLineBreaks, draft.contains("\n") || answer.contains("\n") {
            let result = attempt(
                draft: LineBreakWords.encode(draft), answer: LineBreakWords.encode(answer), restoring: restoring, narrowing: narrowing,
                objects: { objects(LineBreakWords.decode($0)) })
            guard case .repaired(let text, let reverted) = result else { return result }
            return .repaired(text: LineBreakWords.decode(text), reverted: reverted)
        }
        // Line breaks are layout the checks guard on their own; a text with any is left whole.
        guard !draft.contains("\n"), !answer.contains("\n") else { return .none }
        let diff = SpanRepair(draft: draft, answer: answer)
        guard !diff.hunks.isEmpty, !objects(draft) else { return .none }
        var kept = Set<Int>()
        var replacing: [Int: [String]] = [:]
        var reverted = 0
        for index in diff.hunks.indices {
            guard objects(diff.text(applying: [index])) else { kept.insert(index); continue }
            reverted += 1
            if restoring, let restored = diff.restoring(hunk: index, objects: objects) {
                kept.insert(index)
                replacing[index] = restored
            } else if narrowing, let narrowed = diff.narrowing(hunk: index, objects: objects) {
                kept.insert(index)
                replacing[index] = narrowed
            }
        }
        guard reverted > 0 else { return .none }
        return kept.isEmpty ? .allGuilty : .repaired(text: diff.text(applying: kept, replacing: replacing), reverted: reverted)
    }

    // MARK: Putting a dropped piece back into the model's words

    /// The model's words for hunk `index` with the piece the check objects to put back, or nil when that cannot be done
    /// with certainty. The caller has found that this hunk alone trips the check.
    ///
    /// The piece is found with the check itself, not with a list: every run of up to `maximumRestoredWords` draft words
    /// inside the hunk is put back in turn, and the shortest runs that quiet the check are the piece. It is placed only
    /// when
    /// - exactly one run of that length does it (more than one is ambiguous);
    /// - the run is the first or the last words of what the hunk replaced, so its place is fixed by a neighbour: the word
    ///   before the hunk (run first, put back in front of the model's words) or the word after it (run last, put
    ///   behind them). A run in the middle has reworded words on both sides and no certain place, even when it would
    ///   quiet the check;
    /// - that neighbour is untouched by the model and the model's words do not end a sentence there, so the piece
    ///   does not land across a sentence break or change the capital letter the sentence opens with.
    /// The text is then judged again by the caller with every other check.
    func restoring(hunk index: Int, objects: (String) -> Bool) -> [String]? {
        let hunk = hunks[index]
        let width = hunk.draftEnd - hunk.draftStart
        guard !hunk.answer.isEmpty, width > 1, width <= Self.maximumRestoredHunkWords else { return nil }
        func quiets(_ words: [String]) -> Bool { !objects(text(applying: [index], replacing: [index: words])) }
        for size in 1..<min(width, Self.maximumRestoredWords + 1) {
            var passing: [(start: Int, words: [String])] = []
            for start in hunk.draftStart...(hunk.draftEnd - size) {
                let run = Array(draftWords[start..<(start + size)])
                // Where the run sits decides where it can be tried: in front of the model's words, behind them, or both.
                let atFront = start == hunk.draftStart, atBack = start + size == hunk.draftEnd
                let tried = (atFront ? [run + hunk.answer] : []) + (atBack ? [hunk.answer + run] : [])
                    + (atFront || atBack ? [] : [run + hunk.answer, hunk.answer + run])
                if tried.contains(where: quiets) { passing.append((start, run)) }
            }
            guard !passing.isEmpty else { continue }
            guard passing.count == 1, let found = passing.first else { return nil }
            let atFront = found.start == hunk.draftStart, atBack = found.start + size == hunk.draftEnd
            if atFront, canAnchor(before: hunk), !endsSentence(draftWords[hunk.draftStart - 1]) {
                let words = found.words + hunk.answer
                return quiets(words) ? words : nil
            }
            if atBack, canAnchor(after: hunk), let last = hunk.answer.last, !endsSentence(last) {
                let words = hunk.answer + found.words
                return quiets(words) ? words : nil
            }
            return nil
        }
        return nil
    }

    /// The speaker's own words for hunk `index` with the model's rewording of them left out, or nil.
    ///
    /// A hunk can join a change the check objects to with a deletion next to it ("uh wispr" became "Whisper": the filler
    /// went and the term was respelled, in one breath). Putting the whole hunk back would bring the filler back with the
    /// term. Instead the shortest run of the hunk's own draft words that the check no longer objects to goes in place of the
    /// model's words, so the filler stays gone and the term is the speaker's. Only draft words are ever used, in their own
    /// order. When more than one run of the smallest size passes, nothing points at one place and the whole hunk goes back.
    func narrowing(hunk index: Int, objects: (String) -> Bool) -> [String]? {
        let hunk = hunks[index]
        let width = hunk.draftEnd - hunk.draftStart
        guard !hunk.answer.isEmpty, width > 1, width <= Self.maximumRestoredHunkWords else { return nil }
        for size in 1..<width {
            var passing: [[String]] = []
            for start in hunk.draftStart...(hunk.draftEnd - size) {
                let run = Array(draftWords[start..<(start + size)])
                if !objects(text(applying: [index], replacing: [index: run])) { passing.append(run) }
            }
            if !passing.isEmpty { return passing.count == 1 ? passing.first : nil }
        }
        return nil
    }

    /// The draft word before the hunk exists and is outside every hunk, so the model left it exactly as it was.
    private func canAnchor(before hunk: Hunk) -> Bool {
        hunk.draftStart > 0 && !hunks.contains { $0.draftStart <= hunk.draftStart - 1 && hunk.draftStart - 1 < $0.draftEnd }
    }

    /// The draft word after the hunk exists and is outside every hunk.
    private func canAnchor(after hunk: Hunk) -> Bool {
        hunk.draftEnd < draftWords.count && !hunks.contains { $0.draftStart <= hunk.draftEnd && hunk.draftEnd < $0.draftEnd }
    }

    private func endsSentence(_ token: String) -> Bool {
        guard let last = token.last else { return false }
        return ".!?;:".contains(last)
    }

    // MARK: Diff

    /// Words with their punctuation attached, so the text can be put back together as it was.
    static func tokens(_ text: String) -> [String] {
        text.split(whereSeparator: { $0 == " " || $0 == "\t" || $0 == "\n" }).map(String.init)
    }

    private static func key(_ token: String) -> String {
        token.lowercased().filter { $0.isLetter || $0.isNumber || $0 == "'" || $0 == "\u{2019}" }
    }

    /// Longest-common-subsequence diff on lower-cased words without punctuation, grouped into hunks.
    private static func hunks(from draft: [String], to answer: [String]) -> [Hunk] {
        let a = draft.map(key), b = answer.map(key)
        let n = a.count, m = b.count
        guard n * m <= 250_000 else { return [] }
        var table = [[Int]](repeating: [Int](repeating: 0, count: m + 1), count: n + 1)
        for i in stride(from: n - 1, through: 0, by: -1) {
            for j in stride(from: m - 1, through: 0, by: -1) {
                table[i][j] = a[i] == b[j] ? table[i + 1][j + 1] + 1 : max(table[i + 1][j], table[i][j + 1])
            }
        }
        var result: [Hunk] = []
        var i = 0, j = 0
        var open: (start: Int, answerStart: Int)?
        func close(at draftEnd: Int, answerEnd: Int) {
            guard let current = open else { return }
            result.append(Hunk(draftStart: current.start, draftEnd: draftEnd, answer: Array(answer[current.answerStart..<answerEnd])))
            open = nil
        }
        while i < n || j < m {
            if i < n, j < m, a[i] == b[j] {
                close(at: i, answerEnd: j)
                // A matching word whose punctuation or case differs is still a change worth a hunk.
                if draft[i] != answer[j] { open = (i, j); close(at: i + 1, answerEnd: j + 1) }
                i += 1; j += 1
            } else {
                if open == nil { open = (i, j) }
                if j < m, i == n || table[i][j + 1] >= table[i + 1][j] { j += 1 } else { i += 1 }
            }
        }
        close(at: n, answerEnd: m)
        return result
    }
}

/// A line break written as a word, so a span repair can carry an answer's paragraphs through a word-by-word comparison with a
/// one-line draft. The word has letters (the comparison keys on letters and digits) that no dictation holds.
enum LineBreakWords {
    private static let word = "\u{23CE}hushylinebreak\u{23CE}"

    static func encode(_ text: String) -> String {
        text.replacingOccurrences(of: "\n", with: " \(word) ")
    }

    static func decode(_ text: String) -> String {
        Regex.replace(text, "[ \\t]*\(NSRegularExpression.escapedPattern(for: word))[ \\t]*", with: "\n")
    }
}
