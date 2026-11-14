import Foundation

/// What came of asking the model again after a check objected to its answer, as a fixed category with no words.
public enum AskedAgain: String, Sendable, Equatable, CaseIterable {
    /// Not asked: the check names nothing the model could be told, or asking again is switched off or already used.
    case none
    /// Not asked: there was no time left in the group's or the dictation's allowance.
    case noTime = "no-time"
    /// Asked, and the second answer failed the same check again: the plain text stands.
    case sameCheck = "same-check"
    /// Asked, and the second answer failed a different check: the plain text stands.
    case otherCheck = "other-check"
    /// Asked, and no answer came in time: the plain text stands.
    case timedOut = "timed-out"
    /// Asked, and the call failed some other way: the plain text stands.
    case failed
    /// Asked, and the second answer passed every check and is the text.
    case passed
}

/// A check that objects because the answer left out something the speaker said is told what was lost and the
/// model is asked once more, instead of the answer being thrown away. The note names the lost words and
/// carries no instruction beyond keeping them; it is built from the guard's own reason and never logged.
enum GuidedRetry {
    /// The checks whose objection names words the answer should have kept.
    static let codes: Set<GuardCode> = [
        .droppedIdentifier, .droppedPurposePhrase, .droppedContentWords, .droppedContrastiveActually,
        .collapsedDoubledWord, .keptRetractedItem,
    ]

    /// The words to keep, read from the guard's reason ("dropped identifier: B"), or nil when it names none.
    static func lostWords(reason: String) -> [String]? {
        guard let colon = reason.firstIndex(of: ":") else { return nil }
        let tail = String(reason[reason.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
        guard !tail.isEmpty else { return nil }
        let quoted = tail.split(separator: "\"", omittingEmptySubsequences: true).enumerated()
            .filter { $0.offset % 2 == 1 }.map { String($0.element) }
        let words = tail.hasPrefix("[") ? quoted : [tail]
        return words.isEmpty ? nil : words
    }

    /// The sentence added to the instructions for the second ask.
    static func note(code: GuardCode, reason: String) -> String? {
        guard codes.contains(code) else { return nil }
        let rest = " and still remove the fillers, repeats and restarts."
        switch code {
        case .droppedContrastiveActually:
            return "\nYour previous answer left out \"actually\", which carries a contrast the speaker meant. Keep it," + rest
        case .collapsedDoubledWord:
            guard let words = lostWords(reason: reason) else { return nil }
            return "\nYour previous answer collapsed \"\(words[0])\", which the speaker said twice on purpose. Keep both," + rest
        case .keptRetractedItem:
            guard let words = lostWords(reason: reason) else { return nil }
            return "\nYour previous answer kept \"\(words[0])\", which the speaker took back. Leave it out and keep the reason that goes with it," + rest
        default:
            guard let words = lostWords(reason: reason) else { return nil }
            let list = words.map { "\"\($0)\"" }.joined(separator: ", ")
            let what = code == .droppedPurposePhrase ? "the purpose phrase \"to \(words[0])\"" : list
            return "\nYour previous answer left out \(what), which the speaker said. Keep it," + rest
        }
    }
}
