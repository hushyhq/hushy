import Foundation

/// A frame the speaker started again: "it was 12, it was 14", "starting at 10, starting at 10:30", "it might slip it may
/// slip", "the bug isn't isn't fixed". No cue word marks the restart, so the first copy's number, negation or modal
/// looked lost to the guards that count them, and they refused an answer that kept the later copy, which is what the
/// speaker meant.
///
/// A restart is two copies of one stretch of words side by side (up to three hesitation words between them) in which
/// - the copies are word for word the same, and the doubling is not one of `LegitDoubles` (emphasis: "very very"); or
/// - they differ in one slot only, the slot being a run of number words or digits, a modal, or a negation word in both
///   copies, and the stretch has three words or more. A number directly before a subject's copula can label
///   two different entities, so that pair stays separate.
/// What this does not read as a restart: copies that differ in any other word ("cancel the Tuesday sync, cancel the Friday
/// retro" adds an item, and `RepeatedFrame` protects it), a stretch of one or two words with a replaced slot, an
/// explicit connective, or three parallel sentences. A repeat with a cue word beside it is a cued correction.
///
/// It is used only to retry a refusal: when `OutputGuard.check` refuses an answer for a changed or dropped number,
/// negation, stance word or content word, the answer is judged again against the draft without the earlier copies. The
/// answer must also pass `CorrectionBound` against the whole draft, so it holds nothing the speaker did not say.
enum RestartedFrame {
    /// Refusals that an earlier copy taken back can explain.
    static let relaxable: Set<GuardCode> = [.changedDigits, .droppedNumber, .droppedNegation, .droppedStanceWord, .droppedContentWords]

    private static let modals: Set<String> = ["can", "could", "may", "might", "must", "shall", "should", "will", "would"]
    private static let hesitationWords: Set<String> = ["um", "uh", "er", "ah", "hmm", "like", "well"]
    private static let hesitationPhrases: Set<String> = ["you know", "i mean"]
    static let copulas: Set<String> = ["is", "are", "was", "were", "am"]
    private static let subjects = Set(ToneProfessionalRules.pronounExpansions.keys.compactMap {
        $0.split(separator: "'").first.map(String.init)
    })
    private static let longest = 8
    private static let fillerGap = 3

    /// True when the answer says a modal or stance word ("will", "maybe") the draft never does: taking a copy back may
    /// drop the speaker's stance, never put a different one in its place.
    static func addsAStance(answer: String, draft: String) -> Bool {
        let stance = modals.union(DisfluencyOnlyGuard.stanceWords)
        let said = Set(EvalMetrics.normalizedWords(draft))
        return EvalMetrics.normalizedWords(answer).contains { stance.contains($0) && !said.contains($0) }
    }

    /// The draft without each earlier copy of a restarted frame, or nil when it has none.
    static func withoutEarlierCopies(_ draft: String) -> String? {
        let tokens = draft.split(whereSeparator: \.isWhitespace).map(String.init)
        let slots = Slots(tokens)
        let legit = Set(LegitDoubles.legitimateDoubles(in: draft))
        var drop = Set<Int>()
        var index = 0
        while index < slots.shapes.count {
            guard let found = earlierCopy(at: index, in: slots, legit: legit)
                ?? expandedEarlierCopy(at: index, in: slots) else { index += 1; continue }
            drop.formUnion(slots.tokenRange(from: index, to: found.laterStart))
            index = found.laterStart
        }
        guard !drop.isEmpty else { return nil }
        return tokens.indices.filter { !drop.contains($0) }.map { tokens[$0] }.joined(separator: " ")
    }

    private static func earlierCopy(at start: Int, in slots: Slots, legit: Set<String>) -> (laterStart: Int, Void)? {
        let shapes = slots.shapes
        for length in stride(from: min(longest, (shapes.count - start) / 2), through: 1, by: -1) {
            for gap in 0...fillerGap {
                let later = start + length + gap
                let between = shapes[(start + length)..<min(later, shapes.count)]
                // A negation repeated after hesitation may restart with its subject restored:
                // "can't, you know, it can't". The final word of the gap must be an existing
                // subject pronoun; a connective cannot be read as hesitation here.
                let restoredSubject = length == 1 && shapes[start] == Slots.negation
                    && between.last.map(subjects.contains) == true
                    && isHesitation(between.dropLast())
                guard later + length <= shapes.count,
                      isHesitation(between) || restoredSubject,
                      shapes[start..<(start + length)] == shapes[later..<(later + length)]
                else { continue }
                if slots.hasSentenceBoundary(before: start + length - 1, from: start)
                    || slots.hasSentenceBoundary(before: later + length - 1, from: later)
                    || hasChangedAlignedPrefix(start: start, later: later, in: slots) { continue }
                if isThreeSentenceRun(start: start, later: later, length: length, in: slots) { continue }
                let same = slots.values[start..<(start + length)] == slots.values[later..<(later + length)]
                if same {
                    if length == 1, legit.contains(shapes[start]) || shapes[start] == Slots.number { continue }
                    return (later, ())
                }
                guard length >= 3 else { continue }
                let changed = (0..<length).filter { slots.values[start + $0] != slots.values[later + $0] }
                guard changed.count == 1 else { continue }
                let slot = changed[0]
                if shapes[start + slot] == Slots.number,
                   slot + 1 < length, copulas.contains(shapes[start + slot + 1]) {
                    // A number immediately before the subject's predicate can identify the subject itself.
                    // Without a correction cue, two such subjects are separate facts.
                    continue
                }
                return (later, ())
            }
        }
        return nil
    }

    private static func isHesitation(_ gap: ArraySlice<String>) -> Bool {
        let words = Array(gap)
        var index = 0
        while index < words.count {
            if index + 1 < words.count,
               hesitationPhrases.contains(words[index] + " " + words[index + 1]) {
                index += 2
            } else if hesitationWords.contains(words[index]) {
                index += 1
            } else {
                return false
            }
        }
        return true
    }

    /// The later copy may add detail while retaining every word of the first copy in order:
    /// "the two roles the two supervisor roles". Its opening two slots and final content
    /// slot must match, and no sentence boundary or non-hesitation joins the copies.
    private static func expandedEarlierCopy(at start: Int, in slots: Slots) -> (laterStart: Int, Void)? {
        let values = slots.values
        guard start + 6 < values.count else { return nil }
        for length in stride(from: min(longest, (values.count - start) / 2), through: 3, by: -1) {
            let source = Array(values[start..<(start + length)])
            guard let last = source.last, !TokenLexicon.functionWords.contains(last),
                  !slots.hasSentenceBoundary(before: start + length - 1, from: start),
                  !slots.endsItem(at: start + length - 1) else { continue }
            for gap in 0...fillerGap {
                let later = start + length + gap
                guard later + length < values.count,
                      isHesitation(slots.shapes[(start + length)..<later]),
                      values[start] == values[later], values[start + 1] == values[later + 1]
                else { continue }
                var matched = 0
                var cursor = later
                let limit = min(values.count, later + length + 4)
                while cursor < limit && matched < length {
                    if values[cursor] == source[matched] { matched += 1 }
                    if slots.endsSentence(at: cursor) && matched < length { break }
                    cursor += 1
                }
                guard matched == length, cursor - later > length,
                      !slots.hasSentenceBoundary(before: cursor - 1, from: later) else { continue }
                // The rest of the later clause may belong to a separate fact. Do not read it
                // as an expansion if it introduces a critical slot absent from the first copy.
                var clauseEnd = cursor
                while clauseEnd < values.count && !slots.endsSentence(at: clauseEnd - 1) { clauseEnd += 1 }
                let laterShapes = slots.shapes[later..<clauseEnd]
                for critical in [Slots.number, Slots.negation, Slots.modal] {
                    if laterShapes.filter({ $0 == critical }).count > slots.shapes[start..<(start + length)].filter({ $0 == critical }).count {
                        matched = -1
                    }
                }
                guard matched >= 0 else { continue }
                if slots.capitalizedNames(from: later, to: clauseEnd).subtracting(slots.capitalizedNames(from: start, to: start + length)).isEmpty == false {
                    continue
                }
                return (later, ())
            }
        }
        return nil
    }

    /// A shorter suffix must not hide another changed slot in the same two parallel frames.
    private static func hasChangedAlignedPrefix(start: Int, later: Int, in slots: Slots) -> Bool {
        var first = start
        var second = later
        while first > 0 && second > 0 && slots.shapes[first - 1] == slots.shapes[second - 1] {
            first -= 1
            second -= 1
            if slots.values[first] != slots.values[second] { return true }
            if slots.endsSentence(at: first) || slots.endsSentence(at: second) { break }
        }
        return false
    }

    private static func isThreeSentenceRun(start: Int, later: Int, length: Int, in slots: Slots) -> Bool {
        guard slots.endsSentence(at: start + length - 1) else { return false }
        let shapes = slots.shapes
        let hasPrevious = start >= length && slots.endsSentence(at: start - 1)
            && shapes[(start - length)..<start] == shapes[later..<(later + length)]
        let third = later + length
        let hasNext = third + length <= shapes.count && slots.endsSentence(at: third - 1)
            && shapes[third..<(third + length)] == shapes[start..<(start + length)]
        return hasPrevious || hasNext
    }

    /// The draft as comparable shapes: a run of number words or digits is one number slot, a modal is one modal slot, a
    /// negation word is one negation slot, any other word is itself. `values` keeps what stood in each slot.
    private struct Slots {
        static let number = "#"
        static let modal = "§"
        static let negation = "¬"
        var shapes: [String] = []
        var values: [String] = []
        private var spans: [Range<Int>] = []
        private let tokens: [String]

        init(_ tokens: [String]) {
            self.tokens = tokens
            var index = 0
            while index < tokens.count {
                let key = LegitDoubles.key(tokens[index])
                if Self.isNumeric(key) {
                    var end = index + 1
                    while end < tokens.count, Self.isNumeric(LegitDoubles.key(tokens[end])) { end += 1 }
                    append(Self.number, tokens[index..<end].map(LegitDoubles.key).joined(separator: " "), index..<end)
                    index = end
                    continue
                }
                let plain = key.replacingOccurrences(of: "'", with: "")
                if modals.contains(key) {
                    append(Self.modal, key, index..<(index + 1))
                } else if CriticalTokenGuard.negationWords.contains(plain) {
                    append(Self.negation, plain, index..<(index + 1))
                } else {
                    append(key, key, index..<(index + 1))
                }
                index += 1
            }
        }

        private mutating func append(_ shape: String, _ value: String, _ span: Range<Int>) {
            shapes.append(shape)
            values.append(value)
            spans.append(span)
        }

        func tokenRange(from first: Int, to later: Int) -> Range<Int> {
            spans[first].lowerBound..<spans[later].lowerBound
        }

        func endsSentence(at slot: Int) -> Bool {
            guard spans.indices.contains(slot), let last = tokens[spans[slot].upperBound - 1].last else { return false }
            return ".!?".contains(last)
        }

        func endsItem(at slot: Int) -> Bool {
            guard spans.indices.contains(slot), let last = tokens[spans[slot].upperBound - 1].last else { return false }
            return ".!?,;:".contains(last)
        }

        func capitalizedNames(from start: Int, to end: Int) -> Set<String> {
            guard start < end else { return [] }
            let text = tokens[spans[start].lowerBound..<spans[end - 1].upperBound].joined(separator: " ")
            return CriticalTokenGuard.capitalizedNames(in: text)
        }

        func hasSentenceBoundary(before end: Int, from start: Int) -> Bool {
            guard start < end else { return false }
            return (start..<end).contains { endsSentence(at: $0) }
        }

        private static func isNumeric(_ key: String) -> Bool {
            !key.isEmpty && (key.contains(where: \.isNumber) || NumberPhrase.isNumberWord(key))
        }
    }
}
