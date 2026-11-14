import Foundation
import Testing
@testable import MurmurCore

@Suite("VoiceLabPrompts")
struct VoiceLabPromptsTests {
    @Test("rejects an empty prompt set")
    func rejectsEmpty() {
        #expect(throws: VoiceLabPrompts.LoadError.self) {
            try VoiceLabPrompts.validate([])
        }
    }

    @Test("rejects duplicate ids")
    func rejectsDuplicates() {
        let prompts = [
            VoiceLabPrompt(id: "a", category: "plain", style: .normal, prompt: "Say hi.", expected: "Say hi."),
            VoiceLabPrompt(id: "a", category: "plain", style: .normal, prompt: "Say bye.", expected: "Say bye."),
        ]
        #expect(throws: VoiceLabPrompts.LoadError.self) {
            try VoiceLabPrompts.validate(prompts)
        }
    }

    @Test("rejects ids that could escape the session folder", arguments: ["../x", "a/b", "..", "", ".hidden", "a b"])
    func rejectsUnsafeIDs(id: String) {
        let prompts = [VoiceLabPrompt(id: id, category: "plain", style: .normal, prompt: "Say hi.", expected: "Say hi.")]
        #expect(throws: VoiceLabPrompts.LoadError.self) {
            try VoiceLabPrompts.validate(prompts)
        }
    }

    @Test("accepts a well-formed prompt set")
    func acceptsValid() throws {
        let prompts = [
            VoiceLabPrompt(id: "a", category: "plain", style: .normal, prompt: "Say hi.", expected: "Say hi."),
            VoiceLabPrompt(id: "b", category: "plain", style: .whisper, prompt: "Whisper hi.", expected: "Hi."),
        ]
        try VoiceLabPrompts.validate(prompts)
    }

    @Test("loads from a JSON file on disk")
    func loadsFromDisk() throws {
        let prompts = [
            VoiceLabPrompt(
                id: "roundtrip-1", category: "plain", style: .normal, prompt: "Say hi.", expected: "Say hi.",
                alternatives: ["Hi."], expectedPressEnter: false, exactText: false),
        ]
        let url = try Self.writeTempJSON(prompts)
        defer { try? FileManager.default.removeItem(at: url) }
        let loaded = try VoiceLabPrompts.load(from: url)
        #expect(loaded == prompts)
    }

    @Test("the real prompt set is unique, non-empty and covers all three styles", .enabled(if: PrivateFiles.present("Evals/voicelab-prompts.json"), "needs a private file: Evals/voicelab-prompts.json"))
    func realPromptSet() throws {
        guard let url = Self.repoPromptsURL() else {
            Issue.record("Could not locate Evals/voicelab-prompts.json from the test bundle")
            return
        }
        let prompts = try VoiceLabPrompts.load(from: url)
        #expect(prompts.count >= 50)
        let byStyle = Dictionary(grouping: prompts, by: \.style)
        #expect((byStyle[.normal]?.count ?? 0) >= 20)
        #expect((byStyle[.whisper]?.count ?? 0) >= 15)
        #expect((byStyle[.noisy]?.count ?? 0) >= 10)
        for prompt in prompts {
            #expect(!prompt.prompt.isEmpty, "prompt \(prompt.id) has empty prompt text")
            #expect(!prompt.expected.isEmpty, "prompt \(prompt.id) has empty expected text")
            #expect(!prompt.category.isEmpty, "prompt \(prompt.id) has empty category")
        }
    }

    static func writeTempJSON(_ prompts: [VoiceLabPrompt]) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).json")
        try JSONEncoder().encode(prompts).write(to: url)
        return url
    }

    /// Walks up from this source file to find the repo's `Evals/voicelab-prompts.json`.
    static func repoPromptsURL() -> URL? {
        var directory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        for _ in 0..<8 {
            let candidate = directory.appendingPathComponent("Evals/voicelab-prompts.json")
            if FileManager.default.fileExists(atPath: candidate.path) { return candidate }
            directory.deleteLastPathComponent()
        }
        return nil
    }
}

@Suite("VoiceLabTake")
struct VoiceLabTakeTests {
    @Test("sidecar round-trips through disk")
    func sidecarRoundTrip() throws {
        let take = VoiceLabTake(
            promptID: "n-plain-01", category: "plain", style: .normal, timestamp: Date(timeIntervalSince1970: 1_700_000_000),
            deviceName: "MacBook Pro Microphone", voiceProcessingEnabled: true, osVersion: "macOS 15.0",
            capturePeak: 0.42, captureRMS: 0.081, durationSeconds: 3.25)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        try VoiceLabStorage.write(take, to: url)
        let loaded = try VoiceLabStorage.readTake(url)
        #expect(loaded == take)
    }

    @Test("discoverRecordings finds matched wav/json pairs and skips orphans")
    func discoverRecordings() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let take1 = VoiceLabTake(
            promptID: "n-plain-01", category: "plain", style: .normal, timestamp: Date(timeIntervalSince1970: 1_700_000_000),
            deviceName: "Mic A", voiceProcessingEnabled: true, osVersion: "macOS 15.0",
            capturePeak: 0.3, captureRMS: 0.05, durationSeconds: 2.0)
        let take2 = VoiceLabTake(
            promptID: "w-01", category: "plain", style: .whisper, timestamp: Date(timeIntervalSince1970: 1_700_000_100),
            deviceName: "Mic A", voiceProcessingEnabled: true, osVersion: "macOS 15.0",
            capturePeak: 0.02, captureRMS: 0.005, durationSeconds: 1.5)

        try VoiceLabStorage.write(take1, to: directory.appendingPathComponent("n-plain-01.json"))
        try Data().write(to: directory.appendingPathComponent("n-plain-01.wav"))
        try VoiceLabStorage.write(take2, to: directory.appendingPathComponent("w-01.json"))
        try Data().write(to: directory.appendingPathComponent("w-01.wav"))
        // Orphan sidecar with no matching audio must be skipped, not crash discovery.
        try VoiceLabStorage.write(take1, to: directory.appendingPathComponent("orphan.json"))

        let recordings = try VoiceLabStorage.discoverRecordings(in: directory)
        #expect(recordings.count == 2)
        #expect(Set(recordings.map(\.take.promptID)) == ["n-plain-01", "w-01"])
    }

    @Test("session directory is namespaced by UTC date")
    func sessionDirectoryByDate() {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.timeZone = TimeZone(identifier: "UTC")
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        let directory = VoiceLabStorage.sessionDirectory(for: date)
        #expect(directory.lastPathComponent == formatter.string(from: date))
        #expect(directory.path.hasPrefix(VoiceLabStorage.root.path))
    }
}
