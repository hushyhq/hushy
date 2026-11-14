import Foundation

/// Which read of the field showed that a paste landed. Named in the diagnosis log line.
public enum LandingSignal: String, Sendable, Equatable {
    /// The character count changed.
    case count
    /// The caret advanced by the length of what was pasted (the count could not be read, or the
    /// paste replaced a selection of its own length).
    case caret
}

/// The size of what was pasted, as a field's accessibility counts it: UTF-16 units, and how many
/// of them are line breaks (an app may store each as one unit, as two, or drop it).
public struct PastedText: Sendable, Equatable {
    public let length: Int
    public let lineBreaks: Int

    public init(length: Int, lineBreaks: Int = 0) {
        self.length = length
        self.lineBreaks = lineBreaks
    }

    public init(_ text: String) {
        self.init(length: text.utf16.count, lineBreaks: text.utf16.filter { $0 == 0x0A || $0 == 0x0D }.count)
    }
}

/// What counts as "the paste landed" after ⌘V went to a target Hushy was not sure of.
///
/// Only a read of the field counts. A confirmed paste puts the person's earlier clipboard back, so
/// a false "it landed" can lose the dictation; an honest "could not tell" keeps it on the
/// clipboard. Nothing that does not come from the field itself may confirm.
public enum LandingEvidence {
    /// The paste changed the field: the count read before ⌘V differs after it, or the caret moved
    /// the way a paste moves it. A value readable on one side only is no baseline and proves nothing.
    public static func signal(before: LandingProbe, after: LandingProbe, pasted: PastedText) -> LandingSignal? {
        if let was = before.characterCount, let now = after.characterCount, was != now { return .count }
        if caretShowsPaste(before: before, after: after, pasted: pasted) { return .caret }
        return nil
    }

    /// A caret moves for many reasons: an arrow key, a click in the same field, an accessibility
    /// tree that settles between two reads. It counts as a paste only when it moved the way a
    /// paste moves it:
    ///
    /// - It advanced by the pasted length. The caret is where the selection starts, so a paste
    ///   over a selection ends at that start plus the pasted length, the same sum.
    /// - The only tolerance is one unit either way per line break in the pasted text (a field may
    ///   store a break as two units, or as none). Text with no line break must match exactly.
    /// - Both positions are real: never negative, never a not-found value.
    /// - Nothing is selected afterwards, where that can be read: a paste leaves a bare caret.
    /// - The paste has something other than line breaks in it.
    static func caretShowsPaste(before: LandingProbe, after: LandingProbe, pasted: PastedText) -> Bool {
        guard let was = before.caretLocation, let now = after.caretLocation,
              isRealLocation(was), isRealLocation(now), pasted.length > pasted.lineBreaks else { return false }
        if let selected = after.selectedLength, selected != 0 { return false }
        let advance = now - was
        return advance > 0 && abs(advance - pasted.length) <= pasted.lineBreaks
    }

    /// Accessibility reports "no position" as a negative number or as a very large one.
    private static func isRealLocation(_ location: Int) -> Bool {
        (0..<Int(Int32.max)).contains(location)
    }

    /// The field was read and the text is not there: the count was readable before and at the last
    /// read and never changed, and the selection could not explain that (a paste over a selection
    /// of its own length leaves the count as it was). This is evidence of a failure. A caret that
    /// did not move is not: on its own it is too weak to say the paste failed.
    public static func wasReadAndUnchanged(before: LandingProbe, last: LandingProbe, pasted: PastedText) -> Bool {
        guard let was = before.characterCount, let now = last.characterCount, was == now,
              let selected = before.selectedLength else { return false }
        return selected != pasted.length
    }
}

/// The field the read before ⌘V looked at. When nothing was bound at key-down each read asks which
/// field has focus, and the person may have tabbed or clicked to another one in between: its
/// count and caret differ and prove nothing. So the first field read is pinned, and a later read
/// of any other field is not a read of the landing at all.
public struct LandingPin<Element> {
    private var pinned: Element?

    public init() {}

    /// True for the first element (it becomes the pinned one) and afterwards only for that element.
    public mutating func admits(_ element: Element, isSame: (Element, Element) -> Bool) -> Bool {
        guard let pinned else {
            self.pinned = element
            return true
        }
        return isSame(pinned, element)
    }
}
