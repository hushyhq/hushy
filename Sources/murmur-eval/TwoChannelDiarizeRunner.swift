import FluidAudio
import Foundation
import MurmurCore

/// `murmur-eval diarize --dataset ami --two-channel` — an informational extension of
/// `DiarizeRunner` that simulates Hushy's mic + system-audio recording (see
/// `.claude/DECISIONS.md`'s system-audio entry and `docs/research/speaker-labeling.md`) using
/// AMI's official per-speaker close-talking ("Headset-N") audio as the closest available
/// construction of the two streams:
///
/// - **"mic"** = one participant's individual headset channel (`<meeting>.Headset-N.wav`) — the
///   closest AMI has to "this one person's own microphone."
/// - **"system"** = the meeting's official `Mix-Headset` file (every participant's headsets
///   mixed together, including the "mic" participant) — the closest available proxy for "the
///   audio coming out of the call," since AMI has no synthetic "everyone except speaker N" mix
///   and reconstructing one by subtracting waveforms is not how any real call-audio tap works
///   either (a real system-audio tap also generally still contains some bleed of the local
///   participant, which is exactly the echo/bleed case `EchoDeduplicator` exists for).
///
/// This intentionally does **not** use Hushy's own `SystemAudioCapture`/echo-dedup pipeline —
/// AMI is pre-recorded audio, not a live call — but it exercises the same downstream comparison
/// the task asks for: diarization quality "with vs without channel split," i.e. running
/// diarization on the full `Mix-Headset` alone (single-stream, current shipping behavior) vs.
/// running it only on the "system" portion once the known "mic" speaker's headset audio is
/// available to attribute separately. Purely informational — never gates CI, per the task's
/// instruction ("informational only").
enum TwoChannelDiarizeRunner {
    /// usage: murmur-eval diarize --dataset ami --two-channel [--config ihm] [--meetings N] [--collar seconds]
    static func run(_ args: Arguments) async throws {
        let collar = args.string("collar").flatMap(Double.init) ?? 0.25
        let count = args.int("meetings") ?? 3

        print("Fetching AMI per-speaker headset audio for two-channel simulation — up to \(count) meeting(s)…")
        let meetings: [TwoChannelMeeting]
        do {
            meetings = try await TwoChannelAmiDownloader.download(meetingCount: count, root: Paths.data)
        } catch {
            Runners.emit(skipReport(reason: error.localizedDescription))
            return
        }
        guard !meetings.isEmpty else {
            Runners.emit(skipReport(reason: "no meetings had a usable individual-headset channel"))
            return
        }

        let manager = try await makeDiarizer()
        var withoutSplit: [DiarizeRunnerCase] = []
        var withSplit: [DiarizeRunnerCase] = []
        for meeting in meetings {
            print("  \(meeting.meetingId): mic=\(meeting.micSpeakerId), \(String(format: "%.0f", meeting.durationSeconds))s")

            // "Without channel split": today's shipping behavior — diarize the single mixed
            // stream exactly as `SpeakerDiarizer.diarizeAndSave` does for a mic-only note.
            let refFull = meeting.turns.map { MurmurCore.DERSegment(speaker: $0.speakerId, start: $0.beginTime, end: $0.endTime) }
            withoutSplit.append(diarize(id: meeting.meetingId, audio: meeting.systemMix, reference: refFull, manager: manager, collar: collar))

            // "With channel split": the mic speaker's words are attributed directly (as "You"
            // always is in the real feature — see `StreamInterleaver.SegmentSpeaker.you`, no
            // diarization needed), so only the *other* speakers need to be told apart by
            // diarization. The hypothesis is re-diarized on the *reference-masked* system audio
            // (the mic speaker's own turns zeroed out) so the diarizer never gets credit or
            // blame for a "speaker" that is only present because the mic channel bled into the
            // system mix — a real system-audio tap that excludes Hushy's own process still
            // contains some acoustic bleed of the local speaker (the exact case
            // `EchoDeduplicator` exists for), but the *diarization* half of the pipeline (this
            // eval's scope) only ever needs to tell the *other* participants apart, since the
            // mic speaker's words are never sent through the diarizer to begin with in the real
            // feature (see `SpeakerDiarizer.diarizeTwoChannelAndSave`, which diarizes only the
            // system stream, and `NoteRecorder`, which only ever writes mic audio to the mic
            // stream's chunk files). Reference is restricted the same way, so both sides of the
            // comparison omit the mic speaker consistently.
            let refOthers = meeting.turns
                .filter { $0.speakerId != meeting.micSpeakerId }
                .map { MurmurCore.DERSegment(speaker: $0.speakerId, start: $0.beginTime, end: $0.endTime) }
            guard !refOthers.isEmpty else { continue }
            let micTurns = meeting.turns.filter { $0.speakerId == meeting.micSpeakerId }
            let systemOnlyAudio = maskOutTurns(meeting.systemMix, turns: micTurns)
            withSplit.append(diarize(id: meeting.meetingId, audio: systemOnlyAudio, reference: refOthers, manager: manager, collar: collar))
        }

        Runners.emit(report(withoutSplit: withoutSplit, withSplit: withSplit, collar: collar))
    }

    /// Zeroes out every sample within `turns` (RTTM-timed, seconds) in `audio` (16 kHz mono).
    /// Used to approximate "system audio with the mic speaker's own contribution removed": AMI
    /// has no synthetic "everyone except speaker N" mix, but it does have official ground truth
    /// for exactly when that speaker was talking, so silencing those spans on the *known* mix is
    /// the closest available construction without fabricating a mix that never existed. This is
    /// an eval-only simplification — Hushy's real system-audio tap does not know in advance when
    /// the local user will speak, which is exactly why `EchoDeduplicator` exists as a runtime
    /// mechanism instead.
    private static func maskOutTurns(_ audio: [Float], turns: [AmiMeeting.Turn]) -> [Float] {
        guard !turns.isEmpty else { return audio }
        var masked = audio
        let sampleRate = 16_000.0
        for turn in turns {
            let startIndex = max(0, Int(turn.beginTime * sampleRate))
            let endIndex = min(masked.count, Int(turn.endTime * sampleRate))
            guard startIndex < endIndex else { continue }
            for index in startIndex..<endIndex { masked[index] = 0 }
        }
        return masked
    }

    private static func makeDiarizer() async throws -> DiarizerManager {
        let manager = DiarizerManager(config: .default)
        let models = try await DiarizerModels.downloadIfNeeded()
        manager.initialize(models: models)
        return manager
    }

    private struct DiarizeRunnerCase {
        let id: String
        let der: MurmurCore.DERResult
        let hypSpeakers: Int
        let refSpeakers: Int
    }

    private static func diarize(
        id: String, audio: [Float], reference: [MurmurCore.DERSegment], manager: DiarizerManager, collar: Double
    ) -> DiarizeRunnerCase {
        let diarization = try? manager.performCompleteDiarization(audio, sampleRate: 16_000)
        let hyp = (diarization?.segments ?? []).map {
            MurmurCore.DERSegment(speaker: $0.speakerId, start: Double($0.startTimeSeconds), end: Double($0.endTimeSeconds))
        }
        let der = MurmurCore.DiarizationErrorRate.compute(reference: reference, hypothesis: hyp, collar: collar)
        return DiarizeRunnerCase(id: id, der: der, hypSpeakers: Set(hyp.map(\.speaker)).count, refSpeakers: Set(reference.map(\.speaker)).count)
    }

    private static func report(withoutSplit: [DiarizeRunnerCase], withSplit: [DiarizeRunnerCase], collar: Double) -> String {
        guard !withoutSplit.isEmpty else {
            return skipReport(reason: "no scorable meetings")
        }
        let meanDERWithout = withoutSplit.map(\.der.der).reduce(0, +) / Double(withoutSplit.count)
        let meanDERWith = withSplit.isEmpty ? nil : withSplit.map(\.der.der).reduce(0, +) / Double(withSplit.count)

        let perMeeting = zip(withoutSplit, withSplit.isEmpty ? withoutSplit.map { _ in Optional<DiarizeRunnerCase>.none } : withSplit.map { Optional($0) })
            .map { without, with -> String in
                let withText = with.map { "\(percent($0.der.der)) (\($0.refSpeakers) other speaker(s))" } ?? "n/a"
                return "  - \(without.id): full-mix DER \(percent(without.der.der)) (\(without.refSpeakers) speaker(s)) · channel-split DER \(withText)"
            }

        return """
            ### Diarization · AMI two-channel simulation (mic=Headset-N, system=Mix-Headset) · \(withoutSplit.count) meeting(s) · collar \(collar)s
            - **Without channel split** (today's shipping single-stream path): mean DER **\(percent(meanDERWithout))**
              across all speakers in the full mix.
            - **With channel split** (mic speaker attributed directly as "You", diarization only
              scores the remaining speakers): mean DER \(meanDERWith.map(percent) ?? "n/a").
            - Construction: "mic" = one AMI participant's individual close-talking headset channel
              (used only to pick which RTTM speaker plays "You"); "system" = the meeting's
              official `Mix-Headset`, with that speaker's own RTTM-timed turns silenced before
              diarization runs, approximating "system audio with the mic speaker's contribution
              removed" using ground truth rather than a real echo-cancellation signal. AMI ships
              no synthetic "everyone except speaker N" mix, and Hushy's real system-audio tap
              still contains some local bleed in practice (see `EchoDeduplicator`, which handles
              that at runtime) — this eval isolates the *diarization* half of the pipeline only
              and does not exercise `SystemAudioCapture`, `StreamInterleaver`, or
              `EchoDeduplicator` directly.
            - Informational only — never gates CI, per the task's instruction.

            Per meeting:
            \(perMeeting.joined(separator: "\n"))
            """
    }

    private static func skipReport(reason: String) -> String {
        """
        ### Diarization · AMI two-channel simulation · SKIPPED
        - Could not build the two-channel simulation: \(reason)
        - Needs network access to the AMI Corpus mirror's individual headset channels
          (`<meeting>.Headset-N.wav`), in addition to what `diarize --dataset ami` already fetches.
        """
    }

    private static func percent(_ value: Double) -> String { String(format: "%.1f%%", value * 100) }
}
