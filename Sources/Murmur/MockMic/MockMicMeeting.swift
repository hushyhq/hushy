#if DEBUG
import Foundation
import MurmurCore

/// Scenario B: a real `NoteRecorder` recording of a multi-voice clip, then the transcript, the
/// diarization and the summary the app would have stored. Meetings that scenario C records later
/// (`voice.later`) are left to C.
extension MockMicHarness {
    func runMeetingScenarios() async {
        let later = Set(manifest.voice?.later.map(\.meeting) ?? [])
        let first = manifest.meetings.filter { !later.contains($0.id) }
        guard !first.isEmpty else { return }
        let title = "Meeting recorded by NoteRecorder"
        let missing = MockMicPreflight.missingForMeetings()
        if missing == ["speaker model"], let meeting = first.first {
            // Without the speaker model the page path still runs: record, type, stop, page, replay.
            record(await runMeetingPageWithoutSpeakers(meeting))
        }
        guard missing.isEmpty else {
            for meeting in first { record(skipped("meeting.\(meeting.id)", title, "skipped: model missing (\(missing.joined(separator: ", ")))")) }
            return
        }
        do { try await rig.prepareSpeech() } catch {
            for meeting in first { record(failed("meeting.\(meeting.id)", title, error, seconds: 0)) }
            return
        }
        for meeting in first {
            let result = await runMeeting(meeting, title: title)
            record(result)
            if result.status == .blocked { return }
        }
    }

    private func runMeeting(_ meeting: MockMicManifest.Meeting, title: String) async -> MockMicScenarioResult {
        let id = "meeting.\(meeting.id)"
        let start = ContinuousClock.now
        do {
            let recorded = try await recordMeeting(meeting)
            if recorded.captureSilent { return blockedResult(id, title, seconds: mockMicSeconds(since: start)) }
            meetings[meeting.id] = MockMicMeetingOutcome(meeting: meeting, recorded: recorded)
            return meetingResult(id: id, title: title, meeting: meeting, recorded: recorded, start: start)
        } catch {
            return failed(id, title, error, seconds: mockMicSeconds(since: start))
        }
    }

    private func meetingResult(id: String, title: String, meeting: MockMicManifest.Meeting,
                               recorded: MockMicRecorded, start: ContinuousClock.Instant) -> MockMicScenarioResult {
        let score = MockMicScoring.score(reference: meeting.reference, hypothesis: recorded.transcript,
                                         mode: manifest.scoringMode)
        let mapping = MockMicAssignment.map(segments: recorded.segments, turns: meeting.turns, offset: recorded.offset)
        let found = MockMicAssignment.distinctSpeakers(recorded.segments, minimumSeconds: MockMicThresholds.minimumSpeakerSeconds)
        let expected = meeting.expectedSpeakers ?? Set(meeting.turns.map(\.speaker)).count
        let distinct = Set(mapping.values.map(\.reference)).count
        let checks = [
            check("note reaches ready", recorded.note.status == .ready, recorded.note.status.rawValue),
            check("transcript word error", score.wer <= MockMicThresholds.meetingWordError, wordError(score.wer),
                  threshold: "<= \(wordError(MockMicThresholds.meetingWordError))", quality: true),
            check("speakers found", found == expected, "\(found) of \(expected)", quality: true),
            check("voices map to distinct reference speakers", distinct == expected, "\(distinct) of \(expected)", quality: true),
        ] + meetingPageChecks(recorded)
        let metrics: [String: Double] = [
            "wordError": score.wer, "referenceWords": Double(score.referenceWords), "speakersFound": Double(found),
            "speakersExpected": Double(expected), "captureOffsetSeconds": recorded.offset,
            "readySeconds": recorded.readySeconds, "summaryCharacters": Double(recorded.note.summary.count),
        ]
        let detail = "wer \(wordError(score.wer)), speakers \(found)/\(expected), offset \(String(format: "%.2f", recorded.offset)) s, scoring \(manifest.scoringMode.rawValue)"
        return MockMicScenarioResult(
            id: id, title: title, status: MockMicReport.status(for: checks), seconds: mockMicSeconds(since: start),
            detail: detail, checks: checks, metrics: metrics,
            texts: ["reference": meeting.reference, "transcript": recorded.transcript, "summary": recorded.note.summary])
    }
}

/// A recorded meeting kept for scenario C.
struct MockMicMeetingOutcome {
    let meeting: MockMicManifest.Meeting
    let recorded: MockMicRecorded

    var mapping: [String: MockMicAssignment.Match] {
        MockMicAssignment.map(segments: recorded.segments, turns: meeting.turns, offset: recorded.offset)
    }

    /// The note speaker that matches a reference speaker id.
    func speaker(forReference reference: String) -> NoteSpeaker? {
        let best = mapping.filter { $0.value.reference == reference }.max { $0.value.overlapSeconds < $1.value.overlapSeconds }
        return recorded.speakers.first { best.map(\.key) == $0.id.map(String.init) }
    }
}
#endif
