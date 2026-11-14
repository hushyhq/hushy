#if DEBUG
import Foundation
import MurmurCore

/// Scenario C: remember one speaker's voice through the code the UI calls, then record later meetings and
/// look at what the diarizer suggested. Invented names only.
extension MockMicHarness {
    func runVoiceScenarios() async {
        guard let voice = manifest.voice else { return }
        let title = "Remembered voice across meetings"
        let remembered = await rememberVoice(voice, title: title)
        guard let saved = remembered.voice else { record(remembered.result); return }
        record(remembered.result)
        for later in voice.later {
            let id = "voice.\(later.meeting)"
            let start = ContinuousClock.now
            let result = await runLater(later, voice: voice, saved: saved, id: id, title: title, start: start)
            record(result)
            if result.status == .blocked { return }
        }
    }

    private func similarityMeter() -> MockMicSimilarity {
        MockMicSimilarity(embedder: DiarizerVoiceEmbedder(diarizer: SpeakerDiarizer(), key: rig.encryption.currentKey, store: rig.store),
                          signatures: rig.encryption.voiceSignatureStore)
    }

    /// The same calls the speaker chip menu makes: rename, ask, confirm.
    private func rememberVoice(_ voice: MockMicManifest.Voice, title: String) async -> (result: MockMicScenarioResult, voice: Voice?) {
        let id = "voice.remember"
        let start = ContinuousClock.now
        guard Entitlements.has(.voiceSignatures) else {
            return (skipped(id, title, "skipped: remembered voices are not enabled in this build"), nil)
        }
        guard let outcome = meetings[voice.from], let speaker = outcome.speaker(forReference: voice.speaker),
              let speakerId = speaker.id else {
            return (skipped(id, title, "skipped: scenario B did not produce meeting \(voice.from) with that speaker"), nil)
        }
        do {
            try rig.store.renameSpeakerUpdatingDigest(id: speakerId, to: voice.name)
            let controller = SpeakerVoiceController(store: rig.store, encryption: rig.encryption)
            controller.request(speakerId: speakerId)
            await controller.confirm(speakerId: speakerId)
            return (rememberResult(controller.flow(for: speakerId), id: id, title: title, start: start),
                    try rig.store.voices().first { !$0.isYou && $0.name == voice.name })
        } catch {
            return (failed(id, title, error, seconds: mockMicSeconds(since: start)), nil)
        }
    }

    private func rememberResult(_ flow: RememberVoiceFlow, id: String, title: String,
                                start: ContinuousClock.Instant) -> MockMicScenarioResult {
        var reason = "\(flow)"
        if case .declined(let message) = flow { reason = "declined: \(message)" }
        let checks = [check("voice is remembered", flow == .remembered, reason)]
        return MockMicScenarioResult(
            id: id, title: title, status: MockMicReport.status(for: checks), seconds: mockMicSeconds(since: start),
            detail: flow == .remembered ? "voice saved" : reason, checks: checks, metrics: [:], texts: nil)
    }

    private func runLater(_ later: MockMicManifest.Later, voice: MockMicManifest.Voice, saved: Voice, id: String,
                          title: String, start: ContinuousClock.Instant) async -> MockMicScenarioResult {
        guard let meeting = manifest.meetings.first(where: { $0.id == later.meeting }) else {
            return skipped(id, title, "skipped: meeting \(later.meeting) is not in the manifest")
        }
        do {
            let recorded = try await recordMeeting(meeting)
            if recorded.captureSilent { return blockedResult(id, title, seconds: mockMicSeconds(since: start)) }
            let observation = await observe(recorded, meeting: meeting, later: later, voice: voice, saved: saved)
            let found = MockMicAssignment.distinctSpeakers(recorded.segments, minimumSeconds: MockMicThresholds.minimumSpeakerSeconds)
            return laterResult(id: id, title: title, later: later, voice: voice, observation: observation, start: start,
                               speakers: (found, meeting.expectedSpeakers))
        } catch {
            return failed(id, title, error, seconds: mockMicSeconds(since: start))
        }
    }

    private func observe(_ recorded: MockMicRecorded, meeting: MockMicManifest.Meeting, later: MockMicManifest.Later,
                         voice: MockMicManifest.Voice, saved: Voice) async -> MockMicVoiceObservation {
        let outcome = MockMicMeetingOutcome(meeting: meeting, recorded: recorded)
        let target = later.containsSpeaker ? outcome.speaker(forReference: later.speaker ?? voice.speaker) : nil
        var result = MockMicVoiceObservation(rememberedIsNamed: false, otherIsNamed: false)
        let meter = similarityMeter()
        for speaker in recorded.speakers {
            let isTarget = speaker.id != nil && speaker.id == target?.id
            let suggested = speaker.suggestedVoiceId.flatMap { try? rig.store.voice(id: $0) }?.name
            let score = await meter.similarity(of: speaker, in: recorded, to: saved)
            if isTarget {
                result.rememberedSuggestedName = suggested
                result.rememberedIsNamed = mockMicIsNamed(speaker)
                result.rememberedSimilarity = score
            } else {
                result.otherSuggestedName = result.otherSuggestedName ?? suggested
                result.otherIsNamed = result.otherIsNamed || mockMicIsNamed(speaker)
                result.otherSimilarity = [result.otherSimilarity, score].compactMap { $0 }.max()
            }
        }
        return result
    }

    private func laterResult(id: String, title: String, later: MockMicManifest.Later, voice: MockMicManifest.Voice,
                             observation: MockMicVoiceObservation, start: ContinuousClock.Instant,
                             speakers: (found: Int, expected: Int?)) -> MockMicScenarioResult {
        var checks = MockMicVoiceChecks.laterMeeting(observation, invented: voice.name, expectsRemembered: later.containsSpeaker)
        // Without this, "the new voice has no suggestion" passes trivially when the diarizer merged both voices.
        if let expected = speakers.expected {
            checks.append(check("both voices found as separate speakers", speakers.found >= expected,
                                "\(speakers.found) of \(expected)", quality: true))
        }
        var metrics: [String: Double] = ["speakersFound": Double(speakers.found)]
        metrics["rememberedSimilarity"] = observation.rememberedSimilarity
        metrics["otherSimilarity"] = observation.otherSimilarity
        metrics["suggestionGate"] = Double(VoiceMatcher.defaultThreshold)
        let scores = "remembered \(format(observation.rememberedSimilarity)), others \(format(observation.otherSimilarity)), gate \(VoiceMatcher.defaultThreshold)"
        return MockMicScenarioResult(
            id: id, title: title, status: MockMicReport.status(for: checks), seconds: mockMicSeconds(since: start),
            detail: "contains remembered voice: \(later.containsSpeaker); similarity \(scores)", checks: checks,
            metrics: metrics, texts: nil)
    }

    private func format(_ value: Double?) -> String { value.map { String(format: "%.3f", $0) } ?? "n/a" }
}
#endif

#if DEBUG
/// "The user gave this speaker a name": a non-empty display name that is not another "Speaker N".
/// (`NoteSpeaker.hasRealName` is module-internal to MurmurCore, so the harness states the rule itself.)
func mockMicIsNamed(_ speaker: NoteSpeaker) -> Bool {
    guard let name = speaker.displayName?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty else { return false }
    return name.range(of: #"^Speaker \d+$"#, options: [.regularExpression, .caseInsensitive]) == nil
}
#endif
