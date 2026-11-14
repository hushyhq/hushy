import Testing
@testable import MurmurCore

@Suite("LanguageMatchGuard")
struct LanguageMatchGuardTests {
    @Test("rejects an answer whose detected language differs from expected")
    func rejectsMismatch() {
        // The model drifted into English while asked to keep Spanish.
        let answer = "Hello, how are you? I hope you have a great day today."
        let result = LanguageMatchGuard.violation(answer: answer, expectedLanguage: "es")
        #expect(result != nil)
        #expect(result?.contains("language mismatch") == true)
    }

    @Test("accepts an answer whose detected language matches expected")
    func acceptsMatch() {
        let answer = "Hola, ¿cómo estás? Espero que tengas un buen día hoy."
        let result = LanguageMatchGuard.violation(answer: answer, expectedLanguage: "es")
        #expect(result == nil)
    }

    @Test("does not reject when the answer is too short/ambiguous to classify")
    func inconclusiveIsNotRejected() {
        let result = LanguageMatchGuard.violation(answer: "Sí.", expectedLanguage: "es")
        #expect(result == nil)
    }

    @Test("SmartCleaner.modelSupports treats unknown/nil language as eligible")
    func modelSupportsNilIsEligible() {
        #expect(SmartCleaner.modelSupports(nil))
    }
}
