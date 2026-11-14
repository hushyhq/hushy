#if DEBUG
import Foundation

struct MockMicManifestError: Error, CustomStringConvertible, Equatable {
    let message: String
    var description: String { message }
}

/// `clips.json`: what to play, what was said, and who spoke when. The built-in `say` clips and any
/// external clip folder use this one shape, so the harness has one code path (see docs/guide/MOCK-MIC.md).
struct MockMicManifest: Codable, Equatable {
    struct Turn: Codable, Equatable {
        var speaker: String
        var start: Double
        var end: Double
    }

    struct Dictation: Codable, Equatable {
        var id: String
        var wavs: [String]
        var reference: String
    }

    struct Meeting: Codable, Equatable {
        var id: String
        var wavs: [String]
        var reference: String
        var turns: [Turn]
        var expectedSpeakers: Int?
    }

    struct Later: Codable, Equatable {
        var meeting: String
        var containsSpeaker: Bool
        /// The speaker id the remembered voice has in this meeting; `voice.speaker` when absent.
        var speaker: String?
    }

    /// Which speaker of which meeting to remember, under which invented name, and which later
    /// meetings contain that speaker.
    struct Voice: Codable, Equatable {
        var from: String
        var speaker: String
        var name: String
        var later: [Later]
    }

    var version: Int
    /// "say" (synthetic clips from this machine's voices) or "external".
    var source: String
    /// "full" or "bestStretch"; defaults by source when absent.
    var scoring: String?
    var dictation: [Dictation]
    var meetings: [Meeting]
    var voice: Voice?

    static let currentVersion = 1

    /// Pass/fail thresholds apply only to the clips this harness synthesises itself.
    var enforcesThresholds: Bool { source == "say" }

    var scoringMode: MockMicScoreMode {
        if let scoring, let mode = MockMicScoreMode(rawValue: scoring) { return mode }
        return source == "say" ? .full : .bestStretch
    }

    func validate() throws {
        guard version == Self.currentVersion else { throw fail("unsupported manifest version \(version)") }
        guard source == "say" || source == "external" else { throw fail("source must be \"say\" or \"external\"") }
        if let scoring, MockMicScoreMode(rawValue: scoring) == nil { throw fail("unknown scoring \"\(scoring)\"") }
        try requireUnique(dictation.map(\.id), "dictation")
        try requireUnique(meetings.map(\.id), "meetings")
        for clip in dictation where clip.wavs.isEmpty { throw fail("dictation \(clip.id) lists no wav files") }
        for meeting in meetings {
            guard !meeting.wavs.isEmpty else { throw fail("meeting \(meeting.id) lists no wav files") }
            try validateTurns(meeting)
        }
        if let voice { try validate(voice) }
    }

    private func validateTurns(_ meeting: Meeting) throws {
        guard !meeting.turns.isEmpty else { throw fail("meeting \(meeting.id) has no speaker turns") }
        for turn in meeting.turns where turn.start < 0 || turn.end <= turn.start {
            throw fail("meeting \(meeting.id) has a turn with a bad time range")
        }
    }

    private func validate(_ voice: Voice) throws {
        guard let first = meetings.first(where: { $0.id == voice.from }) else {
            throw fail("voice.from names no meeting")
        }
        guard first.turns.contains(where: { $0.speaker == voice.speaker }) else {
            throw fail("voice.speaker does not talk in meeting \(voice.from)")
        }
        let name = voice.name.trimmingCharacters(in: .whitespacesAndNewlines)
        if name.isEmpty || name.range(of: #"^Speaker \d+$"#, options: [.regularExpression, .caseInsensitive]) != nil {
            throw fail("voice.name must be a real invented name, not a generic label")
        }
        for later in voice.later where !meetings.contains(where: { $0.id == later.meeting }) {
            throw fail("voice.later names no meeting: \(later.meeting)")
        }
    }

    private func requireUnique(_ ids: [String], _ what: String) throws {
        guard Set(ids).count == ids.count else { throw fail("duplicate ids in \(what)") }
    }

    private func fail(_ message: String) -> MockMicManifestError { MockMicManifestError(message: message) }

    // MARK: - Paths

    /// Audio the harness must never open: held-out and Voice Lab material, and the real data folder.
    static func isAllowedAudioPath(_ path: String, realSupport: String) -> Bool {
        let lower = path.lowercased()
        for banned in ["heldout", "voice lab", "voicelab"] where lower.contains(banned) { return false }
        let real = URL(fileURLWithPath: realSupport).standardizedFileURL.path
        let candidate = URL(fileURLWithPath: path).standardizedFileURL.path
        return !(candidate == real || candidate.hasPrefix(real + "/"))
    }

    /// A wav path from the manifest, relative to the manifest's folder. Absolute paths and paths
    /// that climb out of the folder are refused.
    static func resolve(_ relative: String, in directory: URL) -> URL? {
        guard !relative.hasPrefix("/"), !relative.hasPrefix("~") else { return nil }
        let parts = relative.split(separator: "/", omittingEmptySubsequences: true)
        guard !parts.contains("..") else { return nil }
        return parts.reduce(directory) { $0.appendingPathComponent(String($1)) }
    }

    static func load(from directory: URL) throws -> MockMicManifest {
        let file = directory.appendingPathComponent("clips.json")
        let data = try Data(contentsOf: file)
        let manifest = try JSONDecoder().decode(MockMicManifest.self, from: data)
        try manifest.validate()
        return manifest
    }
}
#endif
