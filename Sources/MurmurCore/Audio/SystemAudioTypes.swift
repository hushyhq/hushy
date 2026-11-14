import Foundation

/// Which physical stream a word/segment/chunk came from when Hushy records "the other side of
/// the call" alongside the microphone (see docs/research/speaker-labeling.md and
/// `.claude/DECISIONS.md`'s system-audio entry). Kept independent of any Core Audio/
/// ScreenCaptureKit type so `MurmurCore` has no AVFoundation/CoreAudio dependency, matching the
/// existing `Transcriber`/`WordTiming` pattern.
public enum AudioStreamKind: String, Sendable, Equatable, Codable {
    case microphone
    case systemAudio
}

/// One word, tagged with which stream produced it, ready for interleaving into a single
/// note-relative transcript. Distinct from `WordTiming` (which is stream-agnostic) because the
/// interleaver and echo-dedup rule both need to know provenance to decide attribution
/// ("You" for mic, diarized "Speaker N" for system audio) and to drop mic bleed.
public struct StreamWord: Sendable, Equatable {
    public let word: String
    public let start: Double
    public let end: Double
    public let stream: AudioStreamKind

    public init(word: String, start: Double, end: Double, stream: AudioStreamKind) {
        self.word = word
        self.start = start
        self.end = end
        self.stream = stream
    }

    public init(timing: WordTiming, stream: AudioStreamKind) {
        self.init(word: timing.word, start: timing.start, end: timing.end, stream: stream)
    }
}

/// Whether Hushy is currently permitted to capture system (call/output) audio, and why not when
/// it isn't. Deliberately mirrors the shape of `Permissions.Status` (mic/Accessibility) rather
/// than reusing it, since system-audio permission has a third failure mode neither mic nor
/// Accessibility has: the OS feature itself (Core Audio process taps) can be unsupported on an
/// older macOS even when the user has done nothing wrong.
public enum SystemAudioPermissionState: Sendable, Equatable {
    /// Not yet asked, or status unknown (e.g. brand new install).
    case notDetermined
    /// A capture has delivered real (non-silent) call audio, so macOS allowed it.
    case granted
    /// macOS's "System Audio Recording" permission was refused: the tap only delivers digital
    /// silence while the mic hears speech (see `SystemAudioVerdict`).
    case denied
    /// Core Audio process taps need macOS 14.4+; this Mac is on an older OS and the
    /// ScreenCaptureKit fallback also isn't usable (or was denied separately).
    case unsupported

    /// Whether capture should be attempted. Process taps have no preflight API: macOS asks for
    /// "System Audio Recording" the first time a tap starts, so anything short of unsupported
    /// is worth trying (a user may have re-allowed it in System Settings since).
    public var canCapture: Bool { self != .unsupported }

    /// A short, user-facing explanation of why call audio isn't being captured, or `nil` when
    /// capture is expected to work. Never instructs the app to change System Settings itself —
    /// per product policy, only the user can do that; the UI pairs this with a deep link.
    public var userMessage: String? {
        switch self {
        case .granted: nil
        case .notDetermined: nil
        case .denied: "macOS blocked call audio. Allow Hushy in System Settings → Privacy & Security → Screen & System Audio Recording → System Audio Recording Only."
        case .unsupported: "Recording call audio needs macOS 14.4 or later."
        }
    }
}

/// Decides from a recording whether macOS actually let Hushy hear system audio. A refused
/// process tap doesn't error; it just delivers exact digital silence. So: real signal means
/// granted; about 10 s of pure zeros while the mic hears speech means denied; anything else
/// is not enough evidence yet.
public enum SystemAudioVerdict {
    public static let minimumSilentSeconds = 10.0
    /// Mic level above which the mic is clearly hearing something (speech or room).
    public static let micActiveRMS: Float = 0.005

    public static func verdict(systemPeak: Float, systemSeconds: Double, micRMS: Float) -> SystemAudioPermissionState? {
        if systemPeak > 0 { return .granted }
        if systemSeconds >= minimumSilentSeconds, micRMS >= micActiveRMS { return .denied }
        return nil
    }
}
