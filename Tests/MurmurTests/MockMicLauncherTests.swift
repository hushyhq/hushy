#if DEBUG
import Foundation
import Testing
@testable import Murmur

@Suite("Mock microphone: command line")
struct MockMicLauncherTests {
    @Test("the run flag with its folder, clips and player parses")
    func parsesRun() {
        let parsed = MockMicArguments.parse(["Murmur", "--mock-mic", "/r", "--clips", "/c", "--player", "/p"])
        #expect(parsed == MockMicArguments(mode: .run(report: "/r"), clips: "/c", player: "/p"))
    }

    @Test("a flag with no value is unusable")
    func missingValue() {
        #expect(MockMicArguments.parse(["Murmur", "--mock-mic"]) == nil)
        #expect(MockMicArguments.parse(["Murmur", "--mock-mic", "--clips", "/c"]) == nil)
    }

    @Test("two modes at once are unusable")
    func twoModes() {
        #expect(MockMicArguments.parse(["Murmur", "--mock-mic", "/r", "--mock-mic-jobs", "/w"]) == nil)
    }

    @Test("the helper modes parse")
    func helperModes() {
        #expect(MockMicArguments.parse(["Murmur", "--mock-mic-jobs", "/w"])?.mode == .jobs(work: "/w"))
        #expect(MockMicArguments.parse(["Murmur", "--mock-mic-assemble", "/w"])?.mode == .assemble(work: "/w"))
    }

    @Test("an ordinary launch does not ask for the mode")
    func ordinaryLaunch() {
        #expect(!MockMicArguments.requested(["Murmur"]))
        #expect(!MockMicArguments.requested(["Murmur", "--snapshots", "/x"]))
        #expect(MockMicArguments.requested(["Murmur", "--mock-mic", "/r"]))
    }
}

@Suite("Mock microphone: every mode applies the home rule")
@MainActor
struct MockMicHomeRuleTests {
    private let real = URL(fileURLWithPath: "/Users/someone/Library/Application Support/Hushy", isDirectory: true)

    @Test("the run, the job list and the assembly all refuse the real data folder, before touching their folder")
    func everyModeRefuses() async throws {
        let work = FileManager.default.temporaryDirectory.appendingPathComponent("mockmic-home-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: work) }
        for mode in [MockMicArguments.Mode.run(report: work.path), .jobs(work: work.path), .assemble(work: work.path)] {
            let arguments = MockMicArguments(mode: mode, clips: nil, player: nil)
            #expect(await MockMicLauncher.execute(arguments, environment: ["HUSHY_HOME": real.path], realSupport: real)
                    == MockMicExit.refused)
            #expect(await MockMicLauncher.execute(arguments, environment: [:], realSupport: real) == MockMicExit.refused)
        }
        #expect(!FileManager.default.fileExists(atPath: work.path))
    }

    @Test("with a disposable home the job list is written")
    func disposableHomeRuns() async throws {
        let work = FileManager.default.temporaryDirectory.appendingPathComponent("mockmic-home-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: work) }
        let code = await MockMicLauncher.execute(MockMicArguments(mode: .jobs(work: work.path), clips: nil, player: nil),
                                                 environment: ["HUSHY_HOME": "/private/tmp/x"], realSupport: real)
        #expect(code == MockMicExit.ok)
    }
}

@Suite("Mock microphone: audio files")
struct MockMicAudioFilesTests {
    private func temp() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("mockmic-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    @Test("a written WAV reads back at the same length and shape")
    func roundTrip() throws {
        let dir = try temp()
        defer { try? FileManager.default.removeItem(at: dir) }
        let tone = (0..<48_000).map { Float(sin(Double($0) * 0.05)) * 0.5 }
        let url = dir.appendingPathComponent("tone.wav")
        try MockMicAudio.writeWAV(tone, to: url)
        let back = try MockMicAudio.readMono(url)
        #expect(back.count == tone.count)
        #expect(abs(back[1000] - tone[1000]) < 0.001)
        #expect(abs(try MockMicAudio.duration(of: url) - 1.0) < 0.001)
    }

    @Test("a clip at another rate is resampled to 48 kHz")
    func resamples() throws {
        let dir = try temp()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("low.wav")
        try MockMicAudio.writeWAV([Float](repeating: 0.3, count: 16_000), rate: 16_000, to: url)
        let back = try MockMicAudio.readMono(url)
        #expect(abs(back.count - 48_000) < 200)
    }

    @Test("assembly puts each part at its turn start and the onset finder sees the first one")
    func assembles() {
        let part = [Float](repeating: 0.3, count: 4_800)
        let turns = [MockMicManifest.Turn(speaker: "A", start: 1, end: 1.1), .init(speaker: "B", start: 2, end: 2.1)]
        let out = MockMicAudio.assemble(parts: [part, part], turns: turns, rate: 48_000)
        #expect(out.count == 2 * 48_000 + 4_800)
        #expect(out[10] == 0)
        let onset = MockMicAudio.onset(out, rate: 48_000)
        #expect(onset != nil && abs(onset! - 1.0) < 0.03)
        #expect(MockMicAudio.onset([Float](repeating: 0, count: 48_000), rate: 48_000) == nil)
    }
}
#endif
