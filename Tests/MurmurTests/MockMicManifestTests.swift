#if DEBUG
import Foundation
import Testing
@testable import Murmur

@Suite("Mock microphone: clip manifest")
struct MockMicManifestTests {
    private func meeting(_ id: String = "m1", turns: [MockMicManifest.Turn]? = nil) -> MockMicManifest.Meeting {
        MockMicManifest.Meeting(
            id: id, wavs: ["\(id).wav"], reference: "hello there",
            turns: turns ?? [.init(speaker: "A", start: 1, end: 5), .init(speaker: "B", start: 5.5, end: 9)],
            expectedSpeakers: nil)
    }

    private func manifest(source: String = "say", meetings: [MockMicManifest.Meeting]? = nil,
                          voice: MockMicManifest.Voice? = nil) -> MockMicManifest {
        MockMicManifest(version: 1, source: source, scoring: nil,
                        dictation: [.init(id: "d1", wavs: ["d1.wav"], reference: "one two")],
                        meetings: meetings ?? [meeting()], voice: voice)
    }

    @Test("a well-formed manifest validates and survives a JSON round trip")
    func roundTrip() throws {
        let original = manifest(voice: .init(from: "m1", speaker: "B", name: "Marlow Quince",
                                             later: [.init(meeting: "m2", containsSpeaker: true)]))
        let withSecond = MockMicManifest(version: 1, source: "say", scoring: "full", dictation: original.dictation,
                                         meetings: [meeting("m1"), meeting("m2")], voice: original.voice)
        try withSecond.validate()
        let data = try JSONEncoder().encode(withSecond)
        #expect(try JSONDecoder().decode(MockMicManifest.self, from: data) == withSecond)
    }

    @Test("rejects duplicate ids, empty wav lists and an unknown version")
    func structure() {
        #expect(throws: MockMicManifestError.self) { try manifest(meetings: [meeting("x"), meeting("x")]).validate() }
        var empty = meeting(); empty.wavs = []
        #expect(throws: MockMicManifestError.self) { try manifest(meetings: [empty]).validate() }
        var bad = manifest(); bad.version = 2
        #expect(throws: MockMicManifestError.self) { try bad.validate() }
        var source = manifest(); source.source = "mic"
        #expect(throws: MockMicManifestError.self) { try source.validate() }
    }

    @Test("rejects turns that go backwards or overlap their own start")
    func turns() {
        let backwards = meeting(turns: [.init(speaker: "A", start: 5, end: 2)])
        #expect(throws: MockMicManifestError.self) { try manifest(meetings: [backwards]).validate() }
        let negative = meeting(turns: [.init(speaker: "A", start: -1, end: 2)])
        #expect(throws: MockMicManifestError.self) { try manifest(meetings: [negative]).validate() }
    }

    @Test("a voice section must point at real meetings and a speaker that talks in the first one")
    func voice() {
        let two = [meeting("m1"), meeting("m2")]
        let ok = MockMicManifest.Voice(from: "m1", speaker: "B", name: "Marlow Quince",
                                       later: [.init(meeting: "m2", containsSpeaker: true)])
        #expect((try? manifest(meetings: two, voice: ok).validate()) != nil)
        var unknownFrom = ok; unknownFrom.from = "zzz"
        #expect(throws: MockMicManifestError.self) { try manifest(meetings: two, voice: unknownFrom).validate() }
        var unknownSpeaker = ok; unknownSpeaker.speaker = "Q"
        #expect(throws: MockMicManifestError.self) { try manifest(meetings: two, voice: unknownSpeaker).validate() }
        var unknownLater = ok; unknownLater.later = [.init(meeting: "nope", containsSpeaker: false)]
        #expect(throws: MockMicManifestError.self) { try manifest(meetings: two, voice: unknownLater).validate() }
        var genericName = ok; genericName.name = "Speaker 2"
        #expect(throws: MockMicManifestError.self) { try manifest(meetings: two, voice: genericName).validate() }
    }

    @Test("thresholds are enforced for say clips only, and the scoring default follows the source")
    func enforcement() {
        #expect(manifest(source: "say").enforcesThresholds)
        #expect(!manifest(source: "external").enforcesThresholds)
        #expect(manifest(source: "say").scoringMode == .full)
        #expect(manifest(source: "external").scoringMode == .bestStretch)
        var forced = manifest(source: "external"); forced.scoring = "full"
        #expect(forced.scoringMode == .full)
    }

    @Test("paths into held-out or Voice Lab audio, or the real Hushy folder, are refused")
    func pathGuard() {
        let real = "/Users/someone/Library/Application Support/Hushy"
        for path in ["/x/Evals/data/voicelab-eval/a.wav", "/x/heldout/a.wav", "/x/HELDOUT/a.wav", "/x/Voice Lab/a.wav",
                     "\(real)/notes/a.wav", "/x/VoiceLab/a.wav"] {
            #expect(!MockMicManifest.isAllowedAudioPath(path, realSupport: real), "\(path)")
        }
        #expect(MockMicManifest.isAllowedAudioPath("/x/Evals/data/ami-meetings-sdm/a.wav", realSupport: real))
        #expect(MockMicManifest.isAllowedAudioPath("/private/tmp/work/m1.wav", realSupport: real))
    }

    @Test("wav paths resolve against the manifest folder and cannot climb out of it")
    func resolve() {
        let dir = URL(fileURLWithPath: "/private/tmp/clips", isDirectory: true)
        #expect(MockMicManifest.resolve("m1.wav", in: dir)?.path == "/private/tmp/clips/m1.wav")
        #expect(MockMicManifest.resolve("sub/m1.wav", in: dir)?.path == "/private/tmp/clips/sub/m1.wav")
        #expect(MockMicManifest.resolve("../m1.wav", in: dir) == nil)
        #expect(MockMicManifest.resolve("/etc/hosts", in: dir) == nil)
    }
}

@Suite("Mock microphone: say clip plan")
struct MockMicSayPlanTests {
    @Test("turn layout starts after the lead-in and separates turns by the gap")
    func layout() {
        let turns = MockMicSayPlan.layout(speakers: ["A", "B", "A"], durations: [3, 4, 2], leadIn: 1, gap: 0.5)
        #expect(turns.map(\.speaker) == ["A", "B", "A"])
        #expect(turns[0].start == 1 && turns[0].end == 4)
        #expect(turns[1].start == 4.5 && turns[1].end == 8.5)
        #expect(turns[2].start == 9 && turns[2].end == 11)
    }

    @Test("the built-in plan has three dictation clips and three meetings that fit the player's limit")
    func shape() throws {
        let plan = MockMicSayPlan.standard
        #expect(plan.dictation.count == 3)
        #expect(plan.meetings.count == 3)
        #expect(plan.meetings.allSatisfy { Set($0.turns.map(\.speaker)).count == 2 })
        #expect(plan.voice.speaker == "B")
        #expect(!plan.voice.name.isEmpty)
        let jobs = plan.jobs
        #expect(jobs.count == plan.dictation.count + plan.meetings.reduce(0) { $0 + $1.turns.count })
        #expect(Set(jobs.map(\.path)).count == jobs.count)
        #expect(jobs.allSatisfy { !$0.text.contains("\t") && !$0.text.contains("\n") && !$0.voice.isEmpty })
    }

    @Test("the remembered speaker uses the same voice in the first two meetings and a new voice in the third")
    func voices() {
        let plan = MockMicSayPlan.standard
        func voices(_ meeting: Int) -> Set<String> { Set(plan.meetings[meeting].turns.map(\.voice)) }
        #expect(!voices(0).isDisjoint(with: voices(1)))
        #expect(voices(0).isDisjoint(with: voices(2)))
        #expect(voices(1).count == 2 && voices(2).count == 2)
    }

    @Test("the jobs file is one voice, path and text per line, tab separated")
    func tsv() {
        let tsv = MockMicSayPlan.tsv(MockMicSayPlan.standard.jobs)
        let lines = tsv.split(separator: "\n")
        #expect(lines.count == MockMicSayPlan.standard.jobs.count)
        #expect(lines.allSatisfy { $0.split(separator: "\t", omittingEmptySubsequences: false).count == 3 })
    }

    @Test("the manifest built from measured durations is valid and marked as say")
    func manifestFromDurations() throws {
        let plan = MockMicSayPlan.standard
        let durations = Dictionary(uniqueKeysWithValues: plan.jobs.map { ($0.path, 3.0) })
        let manifest = try plan.manifest(durations: durations, leadIn: 1, gap: 0.5)
        try manifest.validate()
        #expect(manifest.source == "say")
        #expect(manifest.meetings.count == 3)
        #expect(manifest.voice?.later.map(\.containsSpeaker) == [true, false])
    }
}
#endif
