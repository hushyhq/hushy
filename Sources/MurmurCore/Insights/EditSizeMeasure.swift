import Foundation

/// How much of a dictation the person changed after it was pasted, as a number of words. The field's
/// text comes in, is compared in memory and is dropped: only the bucket leaves this type.
///
/// The field holds the dictation among other text, so the dictation is first located in it
/// (`CorrectionAlignment.locate`: k-gram anchors, then an exact alignment in a window about the
/// dictation's own length), then lined up word by word. Time is O(n + m) for a field of n words
/// and a dictation of m, plus the alignment's O(m^2) inside the window; very long fields are not
/// searched at all (`CorrectionAlignment.maxFieldTokens`).
public enum EditSizeMeasure {
    /// Words changed between what was pasted and what the field holds now: every run of words that was
    /// replaced, removed or added counts as the longer side of the run, and a word whose capitals or
    /// punctuation changed counts as one. Nil when the dictation cannot be located in the field.
    public static func wordsChanged(inserted: String, fieldValue: String) -> Int? {
        guard let alignment = CorrectionAlignment.locate(inserted: inserted, in: fieldValue) else { return nil }
        let runs = alignment.edits.reduce(0) { $0 + max($1.before.count, $1.after.count) }
        return runs + alignment.surfaceChanges.count
    }

    /// The bucket for a dictation the edit watcher judged edited. A dictation that cannot be located is
    /// one the person rewrote or moved, so it is counted in the largest bucket; an edit is never below
    /// the smallest one.
    public static func size(inserted: String, fieldValue: String) -> MetricsEditSize {
        guard let changed = wordsChanged(inserted: inserted, fieldValue: fieldValue) else { return .wordsMore }
        return MetricsEditSize.forEdit(wordsChanged: changed)
    }
}
