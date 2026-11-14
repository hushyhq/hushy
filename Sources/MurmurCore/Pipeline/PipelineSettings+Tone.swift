import Foundation

extension PipelineSettings {
    /// A tone asks for the grammar-and-flow cleanup (`CleanupLevel.polished`), which is written
    /// for English. For any other detected language the cleanup stays at Cleaned up, as it was
    /// before tones, and `processTranscript` lays the text out without changing any words. A code editor
    /// or terminal has no tone but gets the same grammar repair, so it follows the same rule.
    func resolvedForLanguage() -> PipelineSettings {
        guard tone != nil || cleanupOptions.isCodeContext, cleanupOptions.level == .polished,
              !cleanupOptions.isEnglishOrUnknown else { return self }
        var copy = self
        copy.cleanupOptions.level = .clean
        return copy
    }
}
