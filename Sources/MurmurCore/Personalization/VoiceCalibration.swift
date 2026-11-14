import Foundation

/// Per-user calibration derived from a Tune session's room-tone capture and takes: gate/
/// normalizer hints kept within safe bounds (never disables the gate, never amplifies past a
/// sane ceiling) so a bad calibration can only make Murmur a little less sensitive, not silent
/// or runaway-loud. Stored in `AppSettings` and read by the capture/gate path.
public struct VoiceCalibration: Codable, Sendable, Equatable {
    /// RMS of 2 s of silent room tone — the floor the speech gate should treat as "nothing said".
    public let noiseFloorRMS: Float
    /// RMS across the normal-volume takes.
    public let speechLevelRMS: Float
    /// RMS of the whisper take.
    public let whisperLevelRMS: Float
    public let calibratedAt: Date

    public init(noiseFloorRMS: Float, speechLevelRMS: Float, whisperLevelRMS: Float, calibratedAt: Date = Date()) {
        // Clamp to a safe range so a corrupt or pathological capture (e.g. a stuck-loud mic)
        // cannot push the gate threshold somewhere it would swallow real speech, and cannot
        // report a negative or absurd level that later math would misuse.
        self.noiseFloorRMS = Self.clamp(noiseFloorRMS, max: 0.05)
        self.speechLevelRMS = Self.clamp(speechLevelRMS, max: 1)
        self.whisperLevelRMS = Self.clamp(whisperLevelRMS, max: 1)
        self.calibratedAt = calibratedAt
    }

    private static func clamp(_ value: Float, max upperBound: Float) -> Float {
        guard value.isFinite else { return 0 }
        return min(max(value, 0), upperBound)
    }

    /// True when the whisper take was quiet enough that the production speech gate (tuned on
    /// the Voice Lab A/B, see .claude/DECISIONS.md) risks rejecting the user's real whispers —
    /// shown as a warning on the Tune result card so the user can check their mic placement.
    public var whisperBelowGateRisk: Bool {
        // The gate's own threshold is capture-side; this is a coarse, UI-facing heuristic: a
        // whisper within 3x of the measured noise floor has little headroom to be told apart
        // from silence.
        whisperLevelRMS < noiseFloorRMS * 3
    }

    public static func from(roomTone: [Float], speechTakes: [[Float]], whisperTake: [Float]) -> VoiceCalibration {
        let noiseFloor = StreamingResampler.rms(roomTone)
        let speechLevels = speechTakes.filter { !$0.isEmpty }.map { StreamingResampler.rms($0) }
        let speechLevel = speechLevels.isEmpty ? 0 : speechLevels.reduce(0, +) / Float(speechLevels.count)
        let whisperLevel = StreamingResampler.rms(whisperTake)
        return VoiceCalibration(noiseFloorRMS: noiseFloor, speechLevelRMS: speechLevel, whisperLevelRMS: whisperLevel)
    }
}
