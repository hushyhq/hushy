import Foundation

/// Voice edit: the person selects text in any app, presses Hushy's key and says what to do with it
/// ("make this shorter", "change catch to cache"). Hushy rewrites the selection in place with the
/// on-device model and keeps one undo. When the words are new text instead of an instruction, the
/// selection is simply dictated over, as before. Flag `FeatureFlags.voiceEdit`.
///
/// The types here are the whole shape of one edit, from key-down to undo:
/// `SelectedText` (read at key-down) → `SpokenOverSelection` (what the words are) →
/// `VoiceEditRequest` → `VoiceEditOutcome` → `VoiceEditUndo` (what Undo puts back).
/// None of their text is ever logged or stored.

/// The text selected in the focused field when the key went down.
public struct SelectedText: Sendable, Equatable {
    /// Longer selections are dictated over, never edited: the model's window and the wait both grow with it.
    public static let maxCharacters = 6_000

    public let text: String
    /// Where the selection starts in the field (UTF-16 offset, from Accessibility), when the field says.
    public let location: Int?

    /// nil when there is nothing to edit (empty or whitespace) or too much.
    public init?(text: String, location: Int? = nil) {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              text.count <= Self.maxCharacters else { return nil }
        self.text = text
        self.location = location
    }
}

/// What the words spoken over a selection are.
public enum SpokenOverSelection: String, Sendable, Equatable, CaseIterable {
    /// An instruction about the selection: edit it.
    case instruction
    /// New text to write in the selection's place: dictate over it.
    case replacement
}

/// One edit to run: the selection and what the person said about it.
public struct VoiceEditRequest: Sendable, Equatable {
    public let selection: String
    public let instruction: String
    /// One more line for the model about how to write the result (a register line). Only the model reads it: the
    /// guard judges the answer against `instruction` alone, so wording in the line cannot loosen a check.
    public let guidance: String?

    public init(selection: String, instruction: String, guidance: String? = nil) {
        self.selection = selection
        self.instruction = instruction
        self.guidance = guidance
    }
}

/// How one edit ended.
public enum VoiceEditOutcome: Sendable, Equatable {
    /// Replace the selection with this text.
    case edited(String)
    /// The model read the words as new text, not an instruction: dictate them over the selection.
    case dictation
    /// The selection stays as it was, and the pill says why.
    case declined(VoiceEditDecline)
}

/// Why an edit was not made. Each one is said plainly in the pill; the selection is left untouched.
public enum VoiceEditDecline: String, Sendable, Equatable, CaseIterable {
    /// The model said it cannot do this with the text alone ("add the meeting link").
    case cannotDo
    /// The answer changed a number, a name or a "not" the instruction did not ask about.
    case wouldChangeMeaning
    /// The answer is the selection as it was.
    case unchanged
    /// No answer in time, an unusable answer, or no model to ask.
    case noAnswer

    /// The pill's one line.
    public var line: String {
        switch self {
        case .cannotDo: "Couldn't do that · text kept"
        case .wouldChangeMeaning: "That would change the meaning · text kept"
        case .unchanged: "Nothing to change"
        case .noAnswer: "Couldn't edit right now · text kept"
        }
    }
}

/// What Undo needs: the text that was replaced and the text that replaced it, and where. Kept in
/// memory for `window` only; never written anywhere.
public struct VoiceEditUndo: Sendable, Equatable {
    /// How long Undo is offered after an edit.
    public static let window: Duration = .seconds(10)

    public let original: String
    public let replacement: String
    public let bundleID: String?
    public let processID: Int32
    public let madeAt: Date

    public init(original: String, replacement: String, bundleID: String?, processID: Int32, madeAt: Date) {
        self.original = original
        self.replacement = replacement
        self.bundleID = bundleID
        self.processID = processID
        self.madeAt = madeAt
    }

    /// Whether Undo is still offered at `now`.
    public func isOpen(at now: Date) -> Bool {
        let seconds = Double(Self.window.components.seconds)
        return now.timeIntervalSince(madeAt) < seconds
    }
}
