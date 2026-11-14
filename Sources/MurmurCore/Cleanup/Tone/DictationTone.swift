import Foundation

/// How a dictation should sound once it is written down. A tone changes the register of the
/// words (see `ToneRegister`) and then lays the text out with an existing `WritingStyle`.
///
/// It never changes what was said: no new content words, no added courtesy, no emoji.
public enum DictationTone: String, CaseIterable, Codable, Sendable, Identifiable {
    case refined, casual, professional

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .refined: "Refined"
        case .casual: "Casual"
        case .professional: "Professional"
        }
    }

    /// One line, in plain words, for the picker.
    public var detail: String {
        switch self {
        case .refined: "Clean and clear, in the words you used."
        case .casual: "Everyday contractions: don't, I'll, we're."
        case .professional: "Contractions and spoken shortcuts spelled out: do not, going to."
        }
    }

    /// The layout style applied after the word-level change.
    public var formattingStyle: WritingStyle {
        switch self {
        case .refined: .formal
        case .casual: .casual
        case .professional: .formal
        }
    }
}
