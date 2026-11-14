import Foundation
import MurmurCore

/// Which half of the real-speech recordings a number comes from: settings are chosen on `tune`, reported on `held`.
enum VoiceMatchHalf: String, Codable, Sendable {
    case tune
    case held
}

struct VoiceMatchRecording {
    let id: String
    let set: String
    let half: VoiceMatchHalf
    let audio: [Float]
    let turns: [LabeledRange]
}

/// The real-speech sets `murmur-eval voice-match` reads. Only the two folders named here are ever opened; the
/// others are skipped with a reason. Nothing is downloaded: audio is the 16 kHz float PCM already on disk.
enum VoiceMatchData {
    /// Fixed before any number was looked at: the longest meeting plus the one-speaker file are tuned on; the
    /// other two meetings and the five-speaker file are held out (recordings, not excerpts, so no speaker or
    /// room appears in both halves).
    static let halfByRecording: [String: VoiceMatchHalf] = [
        "TS3003a": .tune, "abjxc": .tune,
        "ES2004a": .held, "IS1009a": .held, "afjiv": .held,
    ]

    static let sets: [(folder: String, idKey: String)] = [("ami-meetings-sdm", "meetingId"), ("voxconverse-dev", "fileId")]

    static let skipped: [(set: String, reason: String)] = [
        ("ami-headset", "150 single-utterance clips for speech recognition; no speaker labels"),
        ("podcasts-changelog", "transcripts name the speaker per paragraph but carry no timings, so a stretch of audio cannot be assigned to a speaker"),
    ]

    private struct Manifest: Decodable {
        struct Turn: Decodable {
            let speakerId: String
            let beginTime: Double
            let endTime: Double
        }
        let meetingId: String?
        let fileId: String?
        let turns: [Turn]
    }

    static func load(root: URL) throws -> [VoiceMatchRecording] {
        var recordings: [VoiceMatchRecording] = []
        for (folder, _) in sets {
            let dir = root.appendingPathComponent(folder, isDirectory: true)
            let names = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
            for name in names.filter({ $0.hasSuffix(".json") }).sorted() {
                let id = String(name.dropLast(".json".count))
                guard let half = halfByRecording[id] else { continue }
                let manifest = try JSONDecoder().decode(Manifest.self, from: Data(contentsOf: dir.appendingPathComponent(name)))
                let pcm = try Data(contentsOf: dir.appendingPathComponent("\(id).pcm"))
                let audio = pcm.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
                let turns = manifest.turns.map { LabeledRange(label: $0.speakerId, start: $0.beginTime, end: $0.endTime) }
                recordings.append(VoiceMatchRecording(id: id, set: folder, half: half, audio: audio, turns: turns))
            }
        }
        return recordings
    }
}
