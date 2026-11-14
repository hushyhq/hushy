import Foundation

/// When the pasted field is read after a paste. One read, at `verdictOffset`, decides whether
/// the dictation was edited (`EditVerdict`); every other read only feeds correction learning.
public enum LearningReadSchedule {
    /// The edit-verdict read. Unchanged: this is what the edit-free rate has always measured.
    public static let verdictOffset: TimeInterval = 8
    /// Learning-only reads before the verdict read, so a fix sent before the verdict read (a chat
    /// message: fix one word, press Return) is seen while it is still in the field. A fix plus
    /// Return can take about two seconds, and the one-letter shortcut needs the fix on two reads
    /// (`CorrectionCapture.minStableReads`), so the early reads are dense: a fix that sits about
    /// a second before Return still gets two. A message sent with a click (no Return read) can sit
    /// fixed for well under a second, so the reads stay half a second apart to 6 s. Each read is a
    /// few Accessibility calls, bounded by the learning read timeout.
    public static let earlyOffsets: [TimeInterval] = [0.5, 1, 1.5, 2, 2.5, 3, 3.5, 4, 4.5, 5, 5.5, 6]
    /// Learning-only reads after the verdict read.
    public static let lateInterval: TimeInterval = 4
    public static let lastOffset: TimeInterval = 30
    /// Between the paste and `lastOffset`, a field that reports its value changing is also read on each change, so a
    /// fix sent from a chat box that empties on send is seen as it stood the moment before (a click on Send, Return in
    /// an app that clears before the Return read, a fix between two scheduled reads). A change read is one more read
    /// of the same field, bounded like every learning read; past this many a watch stops taking them (about 15 s of
    /// steady typing) and keeps its schedule.
    public static let maxChangeReads = 150

    /// Every read offset in order, verdict read included.
    public static var offsets: [TimeInterval] {
        var all = earlyOffsets + [verdictOffset]
        var next = verdictOffset + lateInterval
        while next < lastOffset { all.append(next); next += lateInterval }
        all.append(lastOffset)
        return all
    }
}
