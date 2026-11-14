import Foundation

/// What a note's finalize run does next, from its stored step and its journal alone (meetings schema freeze
/// section 3). Pure, so a relaunch decides exactly as the run that was killed would have.
public enum FinalizePlan {
    /// The step that follows `step` once its work is done.
    /// - `isLive`: a recorder still owns the note, so `capturing` stays.
    /// - `hasTurns`: the note has at least one turn; with neither turns nor audio frames there is nothing to finish.
    public static func next(after step: FinalizeStep, journal: CaptureJournal, hasTurns: Bool, isLive: Bool) -> FinalizeStep {
        switch step {
        case .capturing:
            return isLive ? .capturing : .sealing
        case .sealing:
            return journal.hasOpenRows ? .sealing : .transcribing
        case .transcribing:
            if !journal.sealedAudio.isEmpty { return .transcribing }
            return journal.hasAudioFrames || hasTurns ? .assembling : .needsAttention
        case .assembling:
            return .writing
        case .writing:
            return .exporting
        case .exporting:
            return .done
        case .done, .needsAttention:
            return step
        }
    }

    /// How many times one step may fail to write before the note needs attention.
    public static let maxStepAttempts = 3
    /// How many times a segment's recognition may throw before it is a gap.
    public static let maxSegmentAttempts = 3
}
