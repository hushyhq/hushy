import Foundation

/// Whether a dictation is in texting register — the casual voice of a chat message, where a hedge
/// "like" ("in like 20 mins", "like literally") is part of how the speaker writes, not a
/// disfluency. Founder policy (2026-09-28, `.claude/DECISIONS.md`): in that register the rules keep
/// hedge "like" and leave the call to the model; formal text still loses it.
enum TextingRegister {
    /// Whole words that only appear in casual, message-style speech.
    static let markers: Set<String> = [
        "gonna", "wanna", "gotta", "rn", "lol", "lmao", "omg", "ngl", "tbh", "idk", "btw", "imo",
    ]

    /// True when `text` contains a texting marker as a whole word.
    static func isCasual(_ text: String) -> Bool {
        text.lowercased()
            .split(whereSeparator: { !$0.isLetter })
            .contains { markers.contains(String($0)) }
    }
}
