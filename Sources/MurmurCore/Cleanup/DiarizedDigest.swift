import Foundation

/// Speaker-turn helpers for a note's digest: the "Label: text" transcript of stored segments, and the
/// merge that keeps what the person touched when a note is summarized again (Library's re-summary).
/// The two-pass re-summary after diarization is gone: a meeting is summarized once, after its turns
/// are assembled with speakers (`NoteRecorder.assemble`, meetings schema freeze section 4).
public enum DiarizedDigest {
    public enum Field: String, Sendable, CaseIterable {
        case title, summary, actionItems
    }

    public struct Update: Equatable, Sendable {
        public var note: Note
        public var doneIndexes: Set<Int>
        public var replaced: Set<Field>
    }

    // MARK: - Transcript

    /// Speaker turns as "Label: text" lines (the label is the display label, so a renamed speaker
    /// is used by name), consecutive turns by one speaker joined. Nil unless at least two distinct
    /// speakers have text.
    public static func transcript(from segments: [NoteSegmentWithSpeaker]) -> String? {
        var lines: [(label: String?, text: String)] = []
        for row in segments {
            let text = row.segment.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }
            let label = row.speaker?.displayLabel
            if let last = lines.last, last.label == label {
                lines[lines.count - 1].text += " " + text
            } else {
                lines.append((label, text))
            }
        }
        guard Set(lines.compactMap(\.label)).count >= 2 else { return nil }
        return lines.map { line in line.label.map { "\($0): \(line.text)" } ?? line.text }.joined(separator: "\n")
    }

    // MARK: - Merge

    /// The fields to replace, given the note as the first summary left it (`first`), as it is now
    /// (`current`, with its checked-off item indexes `done`), and the labelled digest.
    /// - A field replaces only if it is still exactly what the first summary wrote: a renamed title,
    ///   an edited or re-generated summary, or a changed action-item list stays the user's.
    /// - An empty labelled field never replaces a non-empty one.
    /// - Action items: every checked-off item stays checked. It moves to the labelled item for the
    ///   same task if there is one, else it is kept as written at the end of the list. Unchecked
    ///   first-summary items are replaced by the labelled list.
    /// - `keepTitle`: the title came from the note's calendar meeting, not from a summary, so it is
    ///   never replaced.
    /// Nil when nothing would change.
    public static func merge(
        first: Note, current: Note, done: Set<Int>, labelled: ExtractiveSummarizer.Output, keepTitle: Bool = false
    ) -> Update? {
        var note = current
        var newDone = done
        var replaced: Set<Field> = []
        if !keepTitle, current.title == first.title, !labelled.title.isEmpty, labelled.title != current.title {
            note.title = labelled.title
            replaced.insert(.title)
        }
        if current.summary == first.summary, !labelled.summary.isEmpty, labelled.summary != current.summary {
            note.summary = labelled.summary
            replaced.insert(.summary)
        }
        if current.actionItems == first.actionItems, !labelled.actionItems.isEmpty,
           labelled.actionItems != current.actionItems {
            let merged = mergeList(
                current.actionItems, details: current.actionItemDetails, done: done,
                labelled: labelled.actionItems, labelledDetails: labelled.actionDetails)
            note.setActionItems(merged.items, details: merged.details)
            newDone = merged.done
            replaced.insert(.actionItems)
        }
        return replaced.isEmpty ? nil : Update(note: note, doneIndexes: newDone, replaced: replaced)
    }

    /// `labelled`, with every checked-off item of `items` kept checked: on the labelled item for the
    /// same task, else appended as written.
    public static func mergeItems(_ items: [String], done: Set<Int>, labelled: [String]) -> ([String], done: Set<Int>) {
        let merged = mergeList(items, details: nil, done: done, labelled: labelled, labelledDetails: nil)
        return (merged.items, merged.done)
    }

    /// The merged list: lines, their fields (nil unless the labelled list has fields), and which are checked.
    public struct MergedItems: Equatable, Sendable {
        public var items: [String]
        public var details: [ActionItemDetail]?
        public var done: Set<Int>
    }

    /// `mergeItems` with the items' fields, so line `i` and fields `i` stay the same item. A kept
    /// item brings its own fields; if any kept item has none (a note from before the fields),
    /// the merged list has no fields at all, never a mix of known and unknown owners.
    public static func mergeList(
        _ items: [String], details: [ActionItemDetail]?, done: Set<Int>,
        labelled: [String], labelledDetails: [ActionItemDetail]?
    ) -> MergedItems {
        var result = labelled
        var resultDetails = ActionItemDetail.aligned(labelledDetails, count: labelled.count)
        var newDone: Set<Int> = []
        for index in done.sorted() where items.indices.contains(index) {
            let checked = items[index]
            if let match = result.indices.first(where: { !newDone.contains($0) && sameTask(result[$0], checked) }) {
                newDone.insert(match)
            } else {
                result.append(checked)
                // A kept item brings its own fields. One that never had any (an older note) cannot be
                // given an owner, so the note keeps lines only rather than mix real fields with guesses.
                if let kept = details.flatMap({ $0.indices.contains(index) ? $0[index] : nil }) { resultDetails?.append(kept) } else { resultDetails = nil }
                newDone.insert(result.count - 1)
            }
        }
        return MergedItems(items: result, details: resultDetails, done: newDone)
    }

    /// Same task, ignoring an "Owner: " prefix and a " — due" suffix.
    static func sameTask(_ a: String, _ b: String) -> Bool {
        NoteDigestMerge.similar(taskPart(a), taskPart(b), threshold: 0.5)
    }

    static func taskPart(_ item: String) -> String {
        var text = item
        if let colon = text.firstIndex(of: ":"), text.distance(from: text.startIndex, to: colon) <= 30 {
            text = String(text[text.index(after: colon)...])
        }
        if let dash = text.range(of: " — ") { text = String(text[..<dash.lowerBound]) }
        return text
    }
}
