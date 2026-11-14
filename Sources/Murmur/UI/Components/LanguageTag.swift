import MurmurCore
import SwiftUI

/// A small capsule label showing a dictation or note's detected non-English language, shown
/// next to the app name/timestamp in History and Notes. Never shown for English — the vast
/// majority of dictations — so it stays out of the way except when it's actually informative.
struct LanguageTag: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.system(size: 9, weight: .semibold))
            .foregroundStyle(Theme.textTertiary)
            .padding(.horizontal, 5).padding(.vertical, 1)
            .background(Capsule().fill(Theme.textTertiary.opacity(0.12)))
    }

    /// The short label to show for a stored BCP-47 `language` code, or `nil` for English/unknown
    /// (`nil` column, or an "en"/"en-…" code) — callers should skip rendering the tag entirely
    /// in that case rather than show an empty one.
    static func label(for languageCode: String) -> String? {
        let detected = DetectedLanguage(code: languageCode, confidence: 1)
        guard !detected.isEnglish else { return nil }
        return detected.displayName
    }
}
