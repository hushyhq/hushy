import Foundation

/// One change the person made to a dictation after it was typed: the dictation's own words
/// around the change as Hushy wrote them, and the same stretch as the person left it.
///
/// A pair holds the dictation's passage and nothing else. That is kept true by where the passage
/// is read from: an earlier look at the field that still held the dictation, exactly once, shows
/// what stood before it and after it. A later look counts only if it still begins and ends with
/// exactly that text; what is between is the dictation's place. With no such earlier look
/// there is no pair.
public struct EditPair: Sendable, Equatable {
    public let before: String
    public let after: String

    public init(before: String, after: String) {
        self.before = before
        self.after = after
    }
}

extension EditPair {
    /// One word of a pair and whether the person changed it, for showing the pair.
    public struct Word: Sendable, Equatable {
        public let text: String
        public let isChanged: Bool
    }

    /// Both sides word by word, the changed ones marked.
    public var words: (before: [Word], after: [Word]) {
        let alignment = CorrectionAlignment.align(inserted: CorrectionAlignment.tokens(before),
                                                  edited: CorrectionAlignment.tokens(after))
        let steps = Self.steps(alignment)
        return (steps.flatMap { step in step.before.map { Word(text: $0, isChanged: step.isChanged) } },
                steps.flatMap { step in step.after.map { Word(text: $0, isChanged: step.isChanged) } })
    }

    /// Unchanged words of the dictation kept either side of a change, so it reads in place.
    public static let contextWords = 3
    /// The longest either side of a pair may be. A longer change is not kept: it would crowd
    /// out everything else the model is told about the person.
    public static let maxWords = 40
    /// The most pairs one dictation gives (changes far apart are separate pairs).
    public static let maxPairs = 3
    /// Looks that must show the same text, unless a later look shows the field had moved on.
    public static let minStableReads = 2

    /// The pairs from the newest look that shows the dictation changed. Unlike the learned-item
    /// path (`CorrectionCapture.derive`) a reworded passage counts: how someone rewrites is what
    /// memory is for. `CorrectionAlignment.locate` still has to find the dictation in its place,
    /// so at least 60% of its words must survive in order; below that a rewrite cannot be told
    /// from something new typed in the same box, and nothing is kept.
    public static func derive(inserted: String, snapshots: [FieldSnapshot], context: LearningContext) -> [EditPair] {
        guard LearningGate.refusal(context) == nil,
              CorrectionAlignment.tokens(inserted).count >= CorrectionCapture.minInsertedWords else { return [] }
        let reads = snapshots.filter { snapshot in
            snapshot.value.map { CorrectionAlignment.tokens($0).count <= CorrectionAlignment.maxFieldTokens } ?? false
        }
        // Left as dictated in the end (or put back): the person changed nothing.
        guard let last = reads.last?.value, !last.contains(inserted) else { return [] }
        for index in reads.indices.reversed() {
            var atRead = context
            atRead.elapsed = reads[index].elapsed
            guard LearningGate.refusal(atRead) == nil,
                  let place = place(of: inserted, in: reads[index], earlier: reads[..<index]) else { continue }
            let pairs = pairs(inserted: inserted, place: place)
            guard !pairs.isEmpty else { continue }
            // The last look alone may have caught a word half typed.
            let sightings = reads.indices.filter { self.place(of: inserted, in: reads[$0], earlier: reads[..<$0]) == place }
            return index < reads.count - 1 || sightings.count >= minStableReads ? pairs : []
        }
        return []
    }

    /// The text standing where the dictation was pasted, or nil when that cannot be known.
    private static func place(of inserted: String, in read: FieldSnapshot, earlier: ArraySlice<FieldSnapshot>) -> String? {
        guard let value = read.value,
              let anchor = earlier.last(where: { holdsOnce(inserted, $0.value ?? "") })?.value,
              let range = anchor.range(of: inserted) else { return nil }
        let head = anchor[..<range.lowerBound], tail = anchor[range.upperBound...]
        guard value.count >= head.count + tail.count, value.hasPrefix(head), value.hasSuffix(tail) else { return nil }
        return String(value.dropFirst(head.count).dropLast(tail.count))
    }

    private static func holdsOnce(_ text: String, _ value: String) -> Bool {
        guard let first = value.range(of: text) else { return false }
        return value.range(of: text, range: first.upperBound..<value.endIndex) == nil
    }

    // MARK: Clipping

    /// One aligned stretch: a word that stayed (changed only if its capitals or punctuation
    /// did), or a run of words that was replaced, removed or added.
    private struct Step {
        let before: ArraySlice<String>
        let after: ArraySlice<String>
        let isChanged: Bool
    }

    private static func pairs(inserted: String, place: String) -> [EditPair] {
        guard let alignment = CorrectionAlignment.locate(inserted: inserted, in: place) else { return [] }
        let steps = steps(alignment)
        return clusters(steps).compactMap { cluster -> EditPair? in
            let window = steps[max(0, cluster.lowerBound - contextWords)...min(steps.count - 1, cluster.upperBound + contextWords)]
            let before = window.flatMap(\.before), after = window.flatMap(\.after)
            guard !before.isEmpty, !after.isEmpty, before != after,
                  before.count <= maxWords, after.count <= maxWords else { return nil }
            return EditPair(before: before.joined(separator: " "), after: after.joined(separator: " "))
        }
        .prefix(maxPairs).map { $0 }
    }

    private static func steps(_ alignment: CorrectionAlignment) -> [Step] {
        let inserted = alignment.inserted, edited = alignment.edited
        var steps: [Step] = []
        var at = 0
        for region in BoostGuard.align(inserted.map(CorrectionAlignment.key), edited.map(CorrectionAlignment.key)) {
            switch region {
            case .same(let range):
                for (offset, editedIndex) in range.enumerated() {
                    let index = at + offset
                    // A full stop dropped where the person kept typing is a continuation, not a change.
                    let isContinuation = index == inserted.count - 1 && alignment.continuesAfter
                    steps.append(Step(before: inserted[index...index], after: edited[editedIndex...editedIndex],
                                      isChanged: inserted[index] != edited[editedIndex] && !isContinuation))
                }
                at += range.count
            case .changed(let old, let new):
                steps.append(Step(before: inserted[old], after: edited[new], isChanged: true))
                at = old.upperBound
            }
        }
        return steps
    }

    /// Changes whose surrounding words would touch are one pair; changes further apart are separate.
    private static func clusters(_ steps: [Step]) -> [ClosedRange<Int>] {
        var found: [ClosedRange<Int>] = []
        for index in steps.indices where steps[index].isChanged {
            if let last = found.last, index - last.upperBound - 1 <= 2 * contextWords {
                found[found.count - 1] = last.lowerBound...index
            } else {
                found.append(index...index)
            }
        }
        return found
    }
}
