import Testing
@testable import MurmurCore

@Suite("LanguageDetector")
struct LanguageDetectionTests {
    @Test("detects Spanish with reasonable confidence")
    func detectsSpanish() {
        let result = LanguageDetector.detect("Hola, ¿cómo estás? Espero que tengas un buen día hoy.")
        #expect(result?.code == "es")
        #expect(result?.isEnglish == false)
    }

    @Test("detects French with reasonable confidence")
    func detectsFrench() {
        let result = LanguageDetector.detect("Bonjour, pouvez-vous m'envoyer le rapport avant vendredi s'il vous plaît.")
        #expect(result?.code == "fr")
    }

    @Test("detects German with reasonable confidence")
    func detectsGerman() {
        let result = LanguageDetector.detect("Guten Tag, können Sie mir bitte den Bericht bis Freitag schicken.")
        #expect(result?.code == "de")
    }

    @Test("detects English and marks it as English")
    func detectsEnglish() {
        let result = LanguageDetector.detect("Let's meet at nine tomorrow morning in the main conference room.")
        #expect(result?.code == "en")
        #expect(result?.isEnglish == true)
    }

    @Test("returns nil for text shorter than the minimum length")
    func tooShortReturnsNil() {
        #expect(LanguageDetector.detect("Hola") == nil)
        #expect(LanguageDetector.detect("") == nil)
    }

    @Test("returns nil below the confidence threshold")
    func lowConfidenceReturnsNil() {
        // An unreasonably high threshold should push even a clear detection below cutoff.
        let result = LanguageDetector.detect("Bonjour, comment allez-vous aujourd'hui mon ami.", threshold: 1.01)
        #expect(result == nil)
    }

    @Test("displayName returns a human-readable language name")
    func displayName() {
        let spanish = DetectedLanguage(code: "es", confidence: 0.9)
        #expect(spanish.displayName.lowercased().contains("spanish"))
    }

    @Test("SupportedDictationLanguage recognizes base codes and rejects unsupported ones")
    func supportedLanguageCodes() {
        #expect(SupportedDictationLanguage.isSupported("es"))
        #expect(SupportedDictationLanguage.isSupported("de-DE"))
        #expect(SupportedDictationLanguage.isSupported("fr"))
        #expect(!SupportedDictationLanguage.isSupported("zh"))
        #expect(!SupportedDictationLanguage.isSupported("ja"))
    }
}
