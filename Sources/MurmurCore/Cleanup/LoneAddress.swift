import Foundation

/// A dictation that is only a web address or email ("jimmylord.com", "mail.example.com/pricing") is not a sentence: it
/// stays as the address is written, lower case with no full stop, whatever app it goes to and whichever stage (the rules,
/// the model, the tone and layout step) last touched it. Text with other words around the address is left to those stages.
///
/// An address with deliberate capitals inside it ("GitHub.com") keeps them, and so does one the person's own Dictionary
/// spells with a capital; only the sentence-initial capital and the closing punctuation are taken off.
public enum LoneAddress {
    private static let closing = CharacterSet(charactersIn: ".,;:!?")

    /// `text` as a lone address should read, or `text` unchanged when it is anything else.
    public static func settle(_ text: String, keepingSpellingOf terms: [String] = []) -> String {
        var stem = text.trimmingCharacters(in: .whitespacesAndNewlines)
        while let last = stem.unicodeScalars.last, closing.contains(last) { stem.removeLast() }
        guard !stem.isEmpty, SpokenAddressNormalizer.isOnlyAnAddress(stem) else { return text }
        if terms.contains(stem) { return stem }
        // Only the capital that starts the sentence goes; one inside the address ("GitHub") was meant.
        let body = stem.range(of: "://").map { stem[$0.upperBound...] } ?? Substring(stem)
        return body.dropFirst().contains(where: \.isUppercase) ? stem : stem.lowercased()
    }
}
