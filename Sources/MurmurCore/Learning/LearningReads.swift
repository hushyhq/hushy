import Foundation

/// One look at the pasted field: what it held, whether that same look found it secure, and when.
public struct FieldRead: Sendable, Equatable {
    public let value: String?
    public let security: FieldSecurity
    public let elapsed: TimeInterval
    /// Taken as Return went down: the person had finished the text they were about to send.
    public let onReturn: Bool
    /// Taken because the field said its value changed (`LearningReadSchedule.maxChangeReads`), not on the schedule.
    public let onChange: Bool

    public init(value: String?, security: FieldSecurity, elapsed: TimeInterval, onReturn: Bool = false, onChange: Bool = false) {
        self.value = value
        self.security = security
        self.elapsed = elapsed
        self.onReturn = onReturn
        self.onChange = onChange
    }
}

/// Turns the raw looks into what correction learning may use.
public enum LearningReads {
    public struct Resolved: Sendable, Equatable {
        public let snapshots: [FieldSnapshot]
        public let isSecureField: Bool
    }

    /// A secure field on any look refuses the whole dictation. A look whose security could
    /// not be read (timed out, element gone) is dropped: its text is never used, and it does
    /// not refuse the dictation. A look's text is used only when that same look said not secure.
    /// A look that held the text a change read then saw emptied is marked `lastBeforeClear`.
    public static func resolve(_ reads: [FieldRead]) -> Resolved {
        let isSecure = reads.contains { $0.security == .secure }
        let usable = reads.filter { $0.security == .notSecure }
        let finals = lastBeforeClear(usable)
        let snapshots = usable.indices.map {
            FieldSnapshot(value: usable[$0].value, elapsed: usable[$0].elapsed, onReturn: usable[$0].onReturn,
                          lastBeforeClear: finals.contains($0))
        }
        return Resolved(snapshots: snapshots, isSecureField: isSecure)
    }

    /// Which reads (indices, in time order) held the field's text right before a change read saw it empty: a chat box
    /// that clears on send. A scheduled look that already found the box empty, before the change report arrived, does
    /// not break the link. A read counts only when a change read saw that same text in the same unbroken run, so the
    /// field was reporting its changes and nothing was typed between that text and the clear. A scheduled look that
    /// caught a word half typed just before a send the field never reported is not marked.
    public static func lastBeforeClear(_ reads: [FieldRead]) -> Set<Int> {
        var finals: Set<Int> = []
        for (index, read) in reads.enumerated() where read.onChange && isBlank(read.value) {
            // Looks that found the box already empty, or could not read it, sit between the text and this report.
            guard let last = reads[..<index].lastIndex(where: { $0.value != nil && !isBlank($0.value) }),
                  let text = reads[last].value else { continue }
            var start = last
            while start > 0, reads[start - 1].value == nil || reads[start - 1].value == text { start -= 1 }
            let run = (start...last).filter { reads[$0].value == text }
            if run.contains(where: { reads[$0].onChange }) { finals.insert(last) }
        }
        return finals
    }

    private static func isBlank(_ value: String?) -> Bool {
        value.map { $0.allSatisfy(\.isWhitespace) } ?? false
    }
}
