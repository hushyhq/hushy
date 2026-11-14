import Foundation

/// Only the deterministic presentation steps around the whole-transcript model.
/// The model still resolves retractions and chooses the words to keep.
enum IntentTextFormat {
    static func input(_ raw: String, options: CleanupOptions) -> String {
        options.voiceCommandsEnabled ? VoiceCommands.applyLineBreaks(raw) : raw
    }

    static func restore(_ answer: String, raw: String, options: CleanupOptions) -> String {
        SpokenLayoutGuard.restoringFlattenedBreaks(answer: answer, draft: input(raw, options: options))
    }

    static func format(_ answer: String, options: CleanupOptions) -> String {
        guard options.level != .verbatim, options.isEnglishOrUnknown else { return answer }
        let written = InverseTextNormalizer.apply(answer, codeContext: options.isCodeContext)
        return ListFormatter.format(written, codeContext: options.isCodeContext)
    }
}
