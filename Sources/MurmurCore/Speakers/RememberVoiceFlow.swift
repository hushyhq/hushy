import Foundation

extension NoteSpeaker {
    /// "Speaker 3" and nothing else: the label the diarizer gives a person it knows nothing about.
    var hasGenericLabel: Bool {
        label.range(of: #"^Speaker \d+$"#, options: [.regularExpression, .caseInsensitive]) != nil
    }

    /// True when the user gave this speaker a name of their own, not "" and not another "Speaker N".
    var hasRealName: Bool {
        guard let name = displayName?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty else { return false }
        return name.range(of: #"^Speaker \d+$"#, options: [.regularExpression, .caseInsensitive]) == nil
    }
}

/// Whether a speaker's chip menu offers "Remember <name>'s voice". Nothing here stores anything:
/// it only decides what the menu shows. Pure, so every case is tested without a window.
public enum RememberVoiceAvailability: Equatable, Sendable {
    /// Offer the action.
    case available
    /// Show nothing: not entitled, no real name yet, already remembered, or the note owner's own track.
    case hidden
    /// The note's recording is gone (or the right track is), so the menu can say so instead of offering it.
    case audioGone

    /// `speakers` is every speaker in the note; `audioStream` is which retained track holds other
    /// people's voices (`nil` when no audio is left).
    public static func evaluate(
        speaker: NoteSpeaker, in speakers: [NoteSpeaker], audioStream: SpeakerAudioStream?, entitled: Bool
    ) -> RememberVoiceAvailability {
        // The note owner's mic track is labelled "You" (or their name), never "Speaker N"; their own
        // voice is enrolled in Tune.
        guard entitled, speaker.hasRealName, speaker.voiceId == nil, speaker.hasGenericLabel else { return .hidden }
        guard let audioStream else { return .audioGone }
        // A two-channel note has an owner track; everyone else is on the system stream only.
        let isTwoChannel = speakers.contains { !$0.hasGenericLabel }
        if isTwoChannel && audioStream != .system { return .audioGone }
        return .available
    }

    /// The one line the menu shows beside a disabled item when the recording is gone.
    public static let audioGoneMessage = "This note's recording was deleted, so there is nothing to learn the voice from."
}

/// The consent steps for one speaker, as a value the view holds. The only way to reach `.working`
/// (and so to store anything) is `requested()` then `confirmed()`.
public enum RememberVoiceFlow: Equatable, Sendable {
    case idle
    /// The consent line is showing; nothing has been computed or stored.
    case asking
    case working
    case remembered
    /// Declined with a one-line reason.
    case declined(String)

    public func requested() -> RememberVoiceFlow {
        switch self {
        case .working: self
        default: .asking
        }
    }

    public func cancelled() -> RememberVoiceFlow { self == .asking ? .idle : self }

    /// "Remember" pressed. Only meaningful while the consent line is showing.
    public func confirmed() -> RememberVoiceFlow { self == .asking ? .working : self }

    public func finished(_ outcome: RememberVoiceOutcome) -> RememberVoiceFlow {
        guard self == .working else { return self }
        switch outcome {
        case .remembered: return .remembered
        case .declined(let message): return .declined(message)
        }
    }
}
