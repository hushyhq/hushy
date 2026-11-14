#if DEBUG
import Foundation

/// The built-in synthetic clips: invented text spoken by macOS `say` voices. The plan produces the
/// jobs for `scripts/mock-mic.sh` to run through `say`, and, once the clips exist and their lengths
/// are known, the same `clips.json` manifest an external clip folder would carry.
struct MockMicSayPlan {
    struct Job: Equatable {
        let voice: String
        let path: String
        let text: String
    }

    struct DictationClip {
        let id: String
        let voice: String
        let text: String
    }

    struct SpokenTurn {
        let speaker: String
        let voice: String
        let text: String
    }

    struct SpokenMeeting {
        let id: String
        let turns: [SpokenTurn]
    }

    let dictation: [DictationClip]
    let meetings: [SpokenMeeting]
    let voice: MockMicManifest.Voice

    var jobs: [Job] {
        let spoken = dictation.map { Job(voice: $0.voice, path: "\($0.id).wav", text: $0.text) }
        let parts = meetings.flatMap { meeting in
            meeting.turns.enumerated().map { index, turn in
                Job(voice: turn.voice, path: Self.partPath(meeting.id, index), text: turn.text)
            }
        }
        return spoken + parts
    }

    static func partPath(_ meeting: String, _ index: Int) -> String {
        "parts/\(meeting)-\(String(format: "%02d", index + 1)).wav"
    }

    static func tsv(_ jobs: [Job]) -> String {
        jobs.map { "\($0.voice)\t\($0.path)\t\($0.text)" }.joined(separator: "\n") + "\n"
    }

    /// Silence of `leadIn` seconds, then each turn with `gap` seconds of silence between turns.
    static func layout(speakers: [String], durations: [Double], leadIn: Double, gap: Double) -> [MockMicManifest.Turn] {
        var clock = leadIn
        var turns: [MockMicManifest.Turn] = []
        for (speaker, duration) in zip(speakers, durations) {
            turns.append(.init(speaker: speaker, start: clock, end: clock + duration))
            clock += duration + gap
        }
        return turns
    }

    func manifest(durations: [String: Double], leadIn: Double, gap: Double) throws -> MockMicManifest {
        let spokenClips = dictation.map {
            MockMicManifest.Dictation(id: $0.id, wavs: ["\($0.id).wav"], reference: $0.text)
        }
        let rendered = try meetings.map { meeting in
            let lengths = try meeting.turns.indices.map { index -> Double in
                let path = Self.partPath(meeting.id, index)
                guard let seconds = durations[path] else { throw MockMicManifestError(message: "no length for \(path)") }
                return seconds
            }
            let turns = Self.layout(speakers: meeting.turns.map(\.speaker), durations: lengths, leadIn: leadIn, gap: gap)
            return MockMicManifest.Meeting(
                id: meeting.id, wavs: ["\(meeting.id).wav"],
                reference: meeting.turns.map(\.text).joined(separator: " "), turns: turns, expectedSpeakers: 2)
        }
        let result = MockMicManifest(version: MockMicManifest.currentVersion, source: "say", scoring: "full",
                                     dictation: spokenClips, meetings: rendered, voice: voice)
        try result.validate()
        return result
    }
}
#endif
