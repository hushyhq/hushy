#if DEBUG
import Foundation
import Testing
@testable import Murmur

@Suite("Mock microphone: report and assignment")
struct MockMicReportTests {
    private func check(_ name: String, _ passed: Bool, enforced: Bool = true) -> MockMicCheck {
        MockMicCheck(name: name, passed: passed, enforced: enforced, value: "v", threshold: nil)
    }

    @Test("status follows the enforced checks only")
    func status() {
        #expect(MockMicReport.status(for: [check("a", true), check("b", true)]) == .pass)
        #expect(MockMicReport.status(for: [check("a", true), check("b", false)]) == .fail)
        #expect(MockMicReport.status(for: [check("a", true), check("b", false, enforced: false)]) == .pass)
        #expect(MockMicReport.status(for: [check("a", false, enforced: false)]) == .reported)
        #expect(MockMicReport.status(for: []) == .reported)
    }

    private func scenario(_ id: String, _ status: MockMicStatus) -> MockMicScenarioResult {
        MockMicScenarioResult(id: id, title: id, status: status, seconds: 1.5, detail: "", checks: [], metrics: [:], texts: nil)
    }

    private func report(_ statuses: [MockMicStatus]) -> MockMicReport {
        MockMicReport(version: 1, source: "say", scoring: "full", device: "BlackHole 2ch", cleanupBackend: "apple",
                      scenarios: statuses.enumerated().map { scenario("s\($0.offset)", $0.element) })
    }

    @Test("exit code: failure beats everything, blocked beats skipped, all skipped is the skipped code")
    func exitCode() {
        #expect(report([.pass, .pass]).exitCode == MockMicExit.ok)
        #expect(report([.pass, .fail]).exitCode == MockMicExit.failed)
        #expect(report([.pass, .skipped]).exitCode == MockMicExit.ok)
        #expect(report([.skipped, .skipped]).exitCode == MockMicExit.skipped)
        #expect(report([.pass, .blocked]).exitCode == MockMicExit.blocked)
        #expect(report([.fail, .blocked]).exitCode == MockMicExit.blocked)
        #expect(report([.reported]).exitCode == MockMicExit.ok)
        #expect(report([]).exitCode == MockMicExit.failed, "no scenarios ran: a failure, not a skip")
    }

    @Test("the JSON has stable keys and sorted order, and omits texts for external clips")
    func json() throws {
        var result = scenario("dictation-1", .pass)
        result.metrics = ["wer": 0.05]
        result.texts = ["reference": "one two", "cleaned": "one two"]
        let text = try report([]).with(scenarios: [result]).jsonString()
        let object = try #require(JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
        #expect(Set(object.keys) == ["version", "source", "scoring", "device", "cleanupBackend", "scenarios"])
        let first = try #require((object["scenarios"] as? [[String: Any]])?.first)
        #expect(first["status"] as? String == "pass")
        #expect((first["metrics"] as? [String: Double])?["wer"] == 0.05)
        #expect(first["texts"] != nil)
        let stripped = try report([]).with(scenarios: [result]).withoutTexts().jsonString()
        #expect(!stripped.contains("one two"))
    }

    @Test("the one-line console summary names the status, the id and the time")
    func summary() {
        let line = scenario("meeting-1", .fail).summaryLine
        #expect(line.contains("FAIL") && line.contains("meeting-1") && line.contains("1.5"))
        #expect(scenario("x", .skipped).summaryLine.contains("SKIPPED"))
    }

    // MARK: - Speaker assignment

    private func seg(_ speaker: String, _ start: Double, _ end: Double) -> MockMicNoteSegment {
        MockMicNoteSegment(speaker: speaker, start: start, end: end)
    }

    @Test("note speakers map to reference speakers by overlap, allowing for the capture offset")
    func assignment() {
        let turns: [MockMicManifest.Turn] = [.init(speaker: "A", start: 1, end: 5), .init(speaker: "B", start: 5.5, end: 9)]
        let segments = [seg("n1", 2.2, 6.2), seg("n2", 6.6, 10.0)]   // everything is ~1.1 s late
        let map = MockMicAssignment.map(segments: segments, turns: turns, offset: 1.1)
        #expect(map["n1"]?.reference == "A")
        #expect(map["n2"]?.reference == "B")
    }

    @Test("a note speaker with almost no overlap maps to nothing")
    func noOverlap() {
        let turns: [MockMicManifest.Turn] = [.init(speaker: "A", start: 1, end: 5)]
        #expect(MockMicAssignment.map(segments: [seg("n1", 20, 25)], turns: turns, offset: 0).isEmpty)
    }

    @Test("distinct speakers ignores speakers who only talk for a moment")
    func distinct() {
        let segments = [seg("n1", 0, 10), seg("n2", 10, 20), seg("n3", 20, 20.4)]
        #expect(MockMicAssignment.distinctSpeakers(segments, minimumSeconds: 2) == 2)
        #expect(MockMicAssignment.distinctSpeakers(segments, minimumSeconds: 0) == 3)
    }

    // MARK: - Voice checks

    @Test("remembered voice: suggested with the invented name, never named, and the new voice has none")
    func voiceChecks() {
        let good = MockMicVoiceObservation(
            rememberedSuggestedName: "Marlow Quince", rememberedIsNamed: false, rememberedSimilarity: 0.84,
            otherSuggestedName: nil, otherIsNamed: false, otherSimilarity: 0.31)
        let checks = MockMicVoiceChecks.laterMeeting(good, invented: "Marlow Quince", expectsRemembered: true)
        #expect(checks.allSatisfy { $0.passed })

        let namedAutomatically = MockMicVoiceObservation(
            rememberedSuggestedName: "Marlow Quince", rememberedIsNamed: true, rememberedSimilarity: 0.9,
            otherSuggestedName: nil, otherIsNamed: false, otherSimilarity: 0.2)
        #expect(MockMicVoiceChecks.laterMeeting(namedAutomatically, invented: "Marlow Quince", expectsRemembered: true)
            .contains { !$0.passed })

        let wrongSuggestionOnNewVoice = MockMicVoiceObservation(
            rememberedSuggestedName: "Marlow Quince", rememberedIsNamed: false, rememberedSimilarity: 0.8,
            otherSuggestedName: "Marlow Quince", otherIsNamed: false, otherSimilarity: 0.76)
        #expect(MockMicVoiceChecks.laterMeeting(wrongSuggestionOnNewVoice, invented: "Marlow Quince", expectsRemembered: true)
            .contains { !$0.passed })
    }

    @Test("a meeting with neither voice must get no suggestions at all")
    func neitherVoice() {
        let clean = MockMicVoiceObservation(
            rememberedSuggestedName: nil, rememberedIsNamed: false, rememberedSimilarity: nil,
            otherSuggestedName: nil, otherIsNamed: false, otherSimilarity: 0.4)
        #expect(MockMicVoiceChecks.laterMeeting(clean, invented: "Marlow Quince", expectsRemembered: false).allSatisfy { $0.passed })
        let leak = MockMicVoiceObservation(
            rememberedSuggestedName: nil, rememberedIsNamed: false, rememberedSimilarity: nil,
            otherSuggestedName: "Marlow Quince", otherIsNamed: false, otherSimilarity: 0.8)
        #expect(MockMicVoiceChecks.laterMeeting(leak, invented: "Marlow Quince", expectsRemembered: false).contains { !$0.passed })
    }
}
#endif
