import Foundation

/// A sentence the speaker let trail off ("...and then... Okay, the next item") keeps its ellipsis. The model
/// sometimes turns it into a full stop or drops it, which says the speaker finished a thought they did not.
///
/// The check counts ellipses (three or more dots, or the single ellipsis character) and objects when the answer
/// has fewer than the draft. The draft keeps every one the speaker's pause made, so a smaller count is always a
/// loss. It points at a place, so `SpanRepair` puts back only the word whose ellipsis went and keeps the rest
/// of the answer.
enum TrailOffGuard {
    static let reason = "dropped trail-off"

    static func violation(answer: String, draft: String) -> String? {
        count(in: answer) < count(in: draft) ? reason : nil
    }

    static func count(in text: String) -> Int {
        guard let regex = try? NSRegularExpression(pattern: "\\.{3,}|\u{2026}") else { return 0 }
        return regex.numberOfMatches(in: text, range: NSRange(location: 0, length: (text as NSString).length))
    }
}
