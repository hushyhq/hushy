import Foundation

/// How present the pill is, the one choice in Settings → General (2026-10-28, founder, after
/// Superwhisper's "Recording window"). Two stored settings carry it, so the older switches keep
/// working: the menu bar's "Show Pill When Idle" and the pill's own "Hide pill when idle" turn
/// `showIdlePill` off (Hidden) and on again without forgetting Mini or Large.
///
/// - **Mini** (default): a small resting pill you can click to dictate; bars while you talk, then the
///   writing dots until the text lands, then the paste glow.
/// - **Large**: the same, with the live words beside the bars while you talk.
/// - **Hidden**: nothing on screen until the dictation key; the recording pill then appears as Mini
///   or Large, whichever was chosen last.
enum PillPresence: String, CaseIterable, Identifiable {
    case mini, large, hidden

    var id: String { rawValue }

    var title: String {
        switch self {
        case .mini: "Mini"
        case .large: "Large"
        case .hidden: "Hidden"
        }
    }

    /// One short line under the picture.
    var detail: String {
        switch self {
        case .mini: "Bars while you talk"
        case .large: "Your words as you talk"
        case .hidden: "Nothing until you press the key"
        }
    }

    init(showIdlePill: Bool, showsLiveWords: Bool) {
        self = !showIdlePill ? .hidden : (showsLiveWords ? .large : .mini)
    }
}

extension AppSettings {
    var pillPresence: PillPresence {
        get { PillPresence(showIdlePill: showIdlePill, showsLiveWords: pillShowsLiveWords) }
        set {
            showIdlePill = newValue != .hidden
            // Hidden keeps the last recording look, so un-hiding brings it back.
            if newValue != .hidden { pillShowsLiveWords = newValue == .large }
        }
    }
}
