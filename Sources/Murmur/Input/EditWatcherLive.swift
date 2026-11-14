import Foundation
import MurmurCore

/// The reads of one dictation's edit watch, kept where a Return key can reach them. The watch's
/// schedule loop and a Return press both append to `reads` on the main actor, so the list is in
/// the order the reads really happened and no read can interleave with another.
@MainActor
final class LiveEditWatch {
    let app: String?
    let pastedAt: Date
    /// Nil once learning is off for this watch (switched off, or never asked for).
    var learning: EditWatcher.LearningInput?
    private(set) var reads: [FieldRead] = []
    private var isOpen = true
    private var hasReadOnReturn = false
    /// Change reads taken, and whether they have stopped (the cap, or a change read that could not read the field).
    private(set) var changeReads = 0
    private var changeReadsStopped = false
    private let readField: @MainActor () -> EditWatcher.ReadResult
    private let boundReads: @MainActor (Bool) -> Void
    private let isCurrent: @MainActor () -> Bool

    init(
        app: String?, pastedAt: Date, learning: EditWatcher.LearningInput?,
        readField: @escaping @MainActor () -> EditWatcher.ReadResult,
        boundReads: @escaping @MainActor (Bool) -> Void,
        isCurrent: @escaping @MainActor () -> Bool
    ) {
        self.app = app
        self.pastedAt = pastedAt
        self.learning = learning
        self.readField = readField
        self.boundReads = boundReads
        self.isCurrent = isCurrent
    }

    /// Adds a look, stamped with how long after the paste it happened.
    func record(_ look: EditWatcher.ReadResult, onReturn: Bool = false, onChange: Bool = false) {
        reads.append(FieldRead(value: look.fieldValue, security: Self.security(of: look.coverage),
                               elapsed: Date().timeIntervalSince(pastedAt), onReturn: onReturn, onChange: onChange))
    }

    /// No more reads are taken after this (the schedule is over, or the watch ended).
    func close() { isOpen = false }

    /// Return (or Enter) went down in this watch's app: one extra look at the field, right now,
    /// because the fix may be sent and the field emptied before the next scheduled look. Only
    /// the first Return counts; a watch that is over, no longer learning, superseded, past
    /// `LearningReadSchedule.lastOffset`, or on a field already seen to be secure takes no read.
    /// The read is bounded like every learning look, and an empty or unreadable result is handled
    /// like any other (a later look that sees nothing never erases an earlier one).
    func readOnReturn() {
        guard isOpen, !hasReadOnReturn, let learning, learning.isStillAllowed(), isCurrent() else { return }
        guard Date().timeIntervalSince(pastedAt) <= LearningReadSchedule.lastOffset else { return }
        guard !reads.contains(where: { $0.security == .secure }) else { return }
        hasReadOnReturn = true
        boundReads(true)
        defer { boundReads(false) }
        record(readField(), onReturn: true)
    }

    /// The pasted field reported that its value changed: one look at it now, so the text a chat box held the moment
    /// before it sent and emptied is seen however the message was sent (`LearningReadSchedule.maxChangeReads`). Only
    /// while the watch is open and learning, to `LearningReadSchedule.lastOffset`, on a field never seen to be secure.
    /// A change read that cannot read the field (a hung or closing app) ends change reads for this watch, so a field
    /// that reports every keystroke cannot hold the main actor on the read timeout again and again. Superseding is
    /// left to the schedule's next look, which ends the watch.
    func readOnChange() {
        guard isOpen, !changeReadsStopped, let learning, learning.isStillAllowed() else { return }
        guard changeReads < LearningReadSchedule.maxChangeReads,
              Date().timeIntervalSince(pastedAt) <= LearningReadSchedule.lastOffset else {
            changeReadsStopped = true
            return
        }
        guard !reads.contains(where: { $0.security == .secure }) else { return }
        changeReads += 1
        boundReads(true)
        defer { boundReads(false) }
        let look = readField()
        if look.coverage != .observed { changeReadsStopped = true }
        record(look, onChange: true)
    }

    /// What the security half of a look said, for `LearningReads.resolve`.
    private static func security(of coverage: DictationEditObservation.Coverage) -> FieldSecurity {
        switch coverage {
        case .secure: .secure
        case .unknownSecurity: .unknown
        default: .notSecure
        }
    }
}

extension EditWatcher {
    /// Watches that are taking looks right now (each is in this list from its paste until its last
    /// scheduled look). Normally zero or one, so a Return press is a scan of a very short list.
    private static var liveWatches: [LiveEditWatch] = []

    static func register(_ watch: LiveEditWatch) { liveWatches.append(watch) }

    static func unregister(_ watch: LiveEditWatch) {
        watch.close()
        liveWatches.removeAll { $0 === watch }
    }

    /// Return, ⌘Return or Enter went down (it was not consumed by Hushy). Each live watch whose
    /// app is the frontmost one takes one extra look at its field. `frontmostBundleID` is what the
    /// caller sees in front when this runs; with no app known nothing is read.
    static func returnPressed(frontmostBundleID: String?) {
        guard let frontmostBundleID, !liveWatches.isEmpty else { return }
        for watch in liveWatches where watch.app == frontmostBundleID { watch.readOnReturn() }
    }
}
