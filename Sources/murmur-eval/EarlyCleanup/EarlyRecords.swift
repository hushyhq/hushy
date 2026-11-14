import Foundation
import MurmurCore

/// What `murmur-eval early-text` and `murmur-eval early-clean` write. Invented dev text only.
enum EarlyRecords {
    /// One whole-recording pass over the audio up to `t` seconds.
    struct Heard: Codable {
        let t: Double
        let text: String
        let ms: Double
    }

    /// The while-speaking recogniser's state once the audio up to `t` seconds had been fed to it.
    struct Sliding: Codable {
        let t: Double
        let confirmed: String
        let volatile: String
    }

    struct Confidence: Codable {
        let word: String
        let confidence: Float
    }

    /// One spoken dev dictation: what the recogniser made of it at the end and on the way there.
    struct Clip: Codable {
        let set: String
        let id: String
        let spokenWords: Int
        let seconds: Double
        /// The transcript the app would clean: one pass over the whole recording.
        let final: String
        let finalConfidences: [Confidence]?
        let finalMs: Double
        /// The same pass over the audio so far, every `tick` seconds.
        let prefixes: [Heard]
        /// The while-speaking recogniser fed in `tick`-second steps from the start.
        let sliding: [Sliding]
        /// From the last audio handed to the while-speaking recogniser to its finished text: what the app waits for today.
        let slidingStopMs: Double
        let slidingFinal: String
        /// Wall-clock seconds since 1970 when this dictation's measurement began and ended, to find one a sleep cut.
        let clockStart: Double
        let clockEnd: Double
    }

    struct EventsFile: Codable {
        let started: String
        let seconds: Double
        let voice: String
        let rate: Int
        /// A silence of `pauseMs` after every `pauseEvery` words (0: none). Absent in files written before it existed.
        var pauseMs: Int?
        var pauseEvery: Int?
        let tick: Double
        let recogniser: String
        let loadAtStart: [Double]
        let loadAtEnd: [Double]
        let clips: [Clip]
    }

    struct EarlyCall: Codable {
        /// Seconds from the start of the recording, on the simulated clock.
        let start: Double
        let seconds: Double
    }

    /// One dictation in one arm.
    struct Row: Codable {
        let set: String
        let id: String
        let finalWords: Int
        let spokenWords: Int
        let seconds: Double
        let plannedGroups: Int
        let output: String
        /// The wait after the key release: `max(blockMs + asrMs, inFlightMs) + cleanMs`.
        let waitMs: Double
        /// The pass over the whole recording.
        let asrMs: Double
        /// What the release waits for before that pass can start: the while-speaking recogniser's last chunk (today), or
        /// an early pass still running (after the change).
        let blockMs: Double
        /// An early model call still running at the release.
        let inFlightMs: Double
        /// `DictationPipeline.clean` on the final transcript, measured.
        let cleanMs: Double
        let sources: [String]
        let earlyStarted: Int
        let earlyUsed: Int
        let withdrawn: Int
        /// Transcripts taken in before the release, and the recogniser passes that produced them.
        let transcripts: Int
        let passes: Int
        let passMs: Double
        let earlyCalls: [EarlyCall]
        /// Model calls by backend, before and after the release.
        let modelCallsEarly: [String: Int]
        let modelCallsRelease: [String: Int]
        let groups: [SecondPassRecords.Group]
        let load: Double
        /// Wall-clock seconds since 1970 when this dictation's run began and ended, to find one a sleep cut.
        let clockStart: Double
        let clockEnd: Double
    }

    struct Arm: Codable {
        let label: String
        let arm: String
        let input: String
        let setting: String
        let firstModel: String
        let secondModel: String?
        let started: String
        let seconds: Double
        let loadAtStart: [Double]
        let loadAtEnd: [Double]
        let thermalAtEnd: String
        let dictations: [Row]
    }
}
