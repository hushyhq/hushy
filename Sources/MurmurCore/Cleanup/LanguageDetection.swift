import Foundation
import NaturalLanguage

/// Detects which language a transcript is written in, using Apple's on-device
/// `NLLanguageRecognizer` (no network, no extra model download — it ships with the OS).
///
/// This backs three things: the language tag shown in History/Notes (`DetectedLanguage.tag`),
/// gating which cleanup stages run (English-only stages skip for non-English text — see
/// `TextCleaner`), and the language-mismatch guard on the on-device cleanup model (see
/// `LanguageMatchGuard`).
public enum LanguageDetector {
    /// Below this confidence, the recognizer's top guess is not trusted and the result falls
    /// back to `nil` (treated as "unknown", which behaves like English for cleanup gating —
    /// the safer default when we aren't sure, since English-only stages are conservative rules
    /// tuned on English text, not aggressive rewrites). Chosen conservatively: short utterances
    /// (a few words) routinely score 0.3–0.6 on the correct language, so a stricter threshold
    /// would misclassify a lot of ordinary short English dictation as "unknown".
    public static let defaultConfidenceThreshold: Double = 0.5

    /// A minimum length below which language ID is unreliable enough that we don't even try —
    /// matches NLLanguageRecognizer's own documented sweet spot (a handful of words or more).
    private static let minimumCharacters = 8

    /// Detects the dominant language of `text`. Returns `nil` when the text is too short, or
    /// when the top hypothesis's confidence is below `threshold`.
    public static func detect(_ text: String, threshold: Double = defaultConfidenceThreshold) -> DetectedLanguage? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= minimumCharacters else { return nil }
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(trimmed)
        guard let language = recognizer.dominantLanguage else { return nil }
        let hypotheses = recognizer.languageHypotheses(withMaximum: 1)
        let confidence = hypotheses[language] ?? 0
        guard confidence >= threshold else { return nil }
        return DetectedLanguage(code: language.rawValue, confidence: confidence)
    }
}

/// The detected language of a piece of text, along with how confident the recognizer was.
public struct DetectedLanguage: Sendable, Equatable {
    /// BCP-47 language code, e.g. "en", "es", "fr". Stored verbatim on `Dictation`/`Note`.
    public let code: String
    public let confidence: Double

    public init(code: String, confidence: Double) {
        self.code = code
        self.confidence = confidence
    }

    public var isEnglish: Bool { code == "en" || code.hasPrefix("en-") }

    /// Short human-readable label for the History/Notes language tag ("Spanish", "French"), in
    /// the current locale. Falls back to the raw code if the locale can't name it.
    public var displayName: String {
        Locale.current.localizedString(forLanguageCode: code)?.capitalized(with: Locale.current) ?? code.uppercased()
    }
}

/// One of the 25 languages FluidAudio's Parakeet Ultra/v3 models support in "Multiple
/// languages" mode. Used to validate the on-device cleanup model can be safely instructed to
/// keep a detected language (`LanguageMatchGuard`), and to size onboarding/Settings copy.
/// Source: FluidAudio's Parakeet TDT multilingual model card (25 European languages).
public enum SupportedDictationLanguage: String, CaseIterable, Sendable {
    case bulgarian = "bg", croatian = "hr", czech = "cs", danish = "da", dutch = "nl"
    case english = "en", estonian = "et", finnish = "fi", french = "fr", german = "de"
    case greek = "el", hungarian = "hu", italian = "it", latvian = "lv", lithuanian = "lt"
    case maltese = "mt", polish = "pl", portuguese = "pt", romanian = "ro", slovak = "sk"
    case slovenian = "sl", spanish = "es", swedish = "sv", russian = "ru", ukrainian = "uk"

    public static func isSupported(_ code: String) -> Bool {
        let base = code.split(separator: "-").first.map(String.init) ?? code
        return SupportedDictationLanguage(rawValue: base) != nil
    }
}
