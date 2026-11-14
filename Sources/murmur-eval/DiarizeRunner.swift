import FluidAudio
import Foundation
import MurmurCore

/// `murmur-eval diarize` — computes Diarization Error Rate (DER) and speaker-count accuracy for
/// FluidAudio's `DiarizerManager` against real, officially-annotated multi-speaker audio, per
/// docs/research/speaker-labeling.md §3.4/§5 Phase 1.
///
/// Two independent public datasets, both with official ground-truth RTTM (never reconstructed
/// or synthesized):
/// - **AMI** (`--dataset ami`, default): the community-standard 3-meeting "mini" subset
///   (`pyannote/AMI-diarization-setup`'s `test.mini.txt`), official far-field (SDM) or
///   headset-mix (IHM) audio from the AMI Corpus mirror — see `AmiMeetingDownloader`.
/// - **VoxConverse** (`--dataset voxconverse`): a fixed subset of dev-set files, audio extracted
///   from YouTube political debates/news, official RTTM from `joonson/voxconverse` — see
///   `VoxConverseDownloader`.
/// Which half of a dataset a `murmur-eval diarize --split` run uses — "tune on half the meetings
/// and report on the other half," per this task's instruction. `.tune` is the half config
/// changes are allowed to be evaluated against while searching for better settings; `.test` is
/// the held-out half a reported number must come from. Shared between `AmiMeetingDownloader` and
/// `VoxConverseDownloader` so both datasets' splits are named the same way.
enum EvalSplit: String {
    case tune
    case test
}

enum DiarizeRunner {
    /// usage: murmur-eval diarize [--dataset ami|voxconverse] [--config sdm|ihm] [--meetings N]
    ///   [--collar 0.25] [--two-channel] [--split tune|test]
    ///   [--clustering-threshold F] [--min-speech-duration F] [--min-silence-gap F] [--num-clusters N]
    ///
    /// `--two-channel` (AMI only) runs `TwoChannelDiarizeRunner` instead: an informational
    /// simulation of Hushy's mic + system-audio recording, reporting DER/speaker attribution
    /// with vs without the channel split — see that type's doc comment for the exact
    /// construction. Never gates CI, per the task's instruction.
    ///
    /// `--split tune|test` selects one disjoint half of the dataset (see `EvalSplit`,
    /// `AmiMeetingDownloader.meetingIds(for:)`, `VoxConverseDownloader.fileIds(for:)`) instead of
    /// `--meetings`' arbitrary prefix — this is what makes "tune on half, report on the other
    /// half" possible without accidentally reusing the same audio for both. Omitting `--split`
    /// keeps the original `--meetings`-prefix behavior unchanged, so every existing call site
    /// (`scripts/run-evals.sh`, CI) is unaffected.
    ///
    /// `--clustering-threshold`/`--min-speech-duration`/`--min-silence-gap`/`--num-clusters`
    /// override FluidAudio's `DiarizerConfig` defaults (`.default`, i.e. threshold 0.7, min
    /// speech 1.0s, min silence gap 0.5s, auto speaker count) — see `Evals/results.md`'s tuning
    /// entry for what was searched and why the chosen values were picked.
    static func run(_ args: Arguments) async throws {
        let datasetName = args.string("dataset") ?? "ami"

        if args.flag("two-channel") {
            guard datasetName == "ami" else {
                throw EvalError.missing("usage: murmur-eval diarize --dataset ami --two-channel [--meetings N] [--collar seconds]")
            }
            try await TwoChannelDiarizeRunner.run(args)
            return
        }

        let collar = args.string("collar").flatMap(Double.init) ?? 0.25
        let count = args.int("meetings") ?? 3
        let split = args.string("split").flatMap(EvalSplit.init(rawValue:))
        let config = diarizerConfig(from: args)
        switch datasetName {
        case "ami":
            try await runAmi(args, count: count, collar: collar, split: split, diarizerConfig: config)
        case "voxconverse":
            try await runVoxConverse(count: count, collar: collar, split: split, diarizerConfig: config)
        default:
            throw EvalError.missing("usage: murmur-eval diarize [--dataset ami|voxconverse] [--config sdm|ihm] [--meetings N] [--collar seconds]")
        }
    }

    /// Builds a `DiarizerConfig` from any of the four tunable-parameter flags present in `args`,
    /// falling back to FluidAudio's own `.default` for anything not overridden — so a run with no
    /// tuning flags at all behaves exactly as it did before this task (the "before" side of a
    /// before/after comparison).
    private static func diarizerConfig(from args: Arguments) -> DiarizerConfig {
        var config = DiarizerConfig.default
        if let value = args.string("clustering-threshold").flatMap(Float.init) { config.clusteringThreshold = value }
        if let value = args.string("min-speech-duration").flatMap(Float.init) { config.minSpeechDuration = value }
        if let value = args.string("min-silence-gap").flatMap(Float.init) { config.minSilenceGap = value }
        if let value = args.int("num-clusters") { config.numClusters = value }
        return config
    }

    // MARK: AMI

    private static func runAmi(
        _ args: Arguments, count: Int, collar: Double, split: EvalSplit?, diarizerConfig: DiarizerConfig
    ) async throws {
        let configName = args.string("config") ?? "sdm"
        guard let config = AmiMeetingDownloader.Config(rawValue: configName) else {
            throw EvalError.missing("usage: murmur-eval diarize --dataset ami [--config sdm|ihm] [--meetings N] [--collar seconds]")
        }

        let meetingIds = split.map(AmiMeetingDownloader.meetingIds(for:))
        let label = split.map { "AMI \(config.rawValue) (\($0.rawValue) split)" } ?? "AMI \(config.rawValue)"
        print("Fetching \(label) — official RTTM + official audio…")
        let meetings: [AmiMeeting]
        do {
            meetings = if let meetingIds {
                try await AmiMeetingDownloader.download(config: config, meetingIds: meetingIds, root: Paths.data)
            } else {
                try await AmiMeetingDownloader.download(config: config, meetingCount: count, root: Paths.data)
            }
        } catch {
            Runners.emit(skipReport(label: label, reason: error.localizedDescription))
            return
        }
        guard !meetings.isEmpty else {
            Runners.emit(skipReport(label: label, reason: "no meetings were available to download"))
            return
        }

        let manager = try await makeDiarizer(config: diarizerConfig)
        var results: [DiarizationCase] = []
        for meeting in meetings {
            print("  Diarizing \(meeting.meetingId): \(String(format: "%.0f", meeting.durationSeconds))s (official RTTM: \(meeting.turns.count) turns)")
            let ref = meeting.turns.map { MurmurCore.DERSegment(speaker: $0.speakerId, start: $0.beginTime, end: $0.endTime) }
            results.append(diarize(id: meeting.meetingId, audio: meeting.audio, reference: ref, manager: manager, collar: collar))
        }
        Runners.emit(report(results, label: label, collar: collar, diarizerConfig: diarizerConfig))
    }

    // MARK: VoxConverse

    private static func runVoxConverse(
        count: Int, collar: Double, split: EvalSplit?, diarizerConfig: DiarizerConfig
    ) async throws {
        let fileIds = split.map(VoxConverseDownloader.fileIds(for:))
        let label = split.map { "VoxConverse dev (\($0.rawValue) split)" } ?? "VoxConverse dev"
        print("Fetching \(label) — official RTTM + official audio…")
        let files: [VoxConverseFile]
        do {
            files = if let fileIds {
                try await VoxConverseDownloader.download(fileIds: fileIds, root: Paths.data)
            } else {
                try await VoxConverseDownloader.download(fileCount: count, root: Paths.data)
            }
        } catch {
            Runners.emit(skipReport(label: label, reason: error.localizedDescription))
            return
        }
        guard !files.isEmpty else {
            Runners.emit(skipReport(label: label, reason: "no files were available to download"))
            return
        }

        let manager = try await makeDiarizer(config: diarizerConfig)
        var results: [DiarizationCase] = []
        for file in files {
            print("  Diarizing \(file.fileId): \(String(format: "%.0f", file.durationSeconds))s (official RTTM: \(file.turns.count) turns)")
            let ref = file.turns.map { MurmurCore.DERSegment(speaker: $0.speakerId, start: $0.beginTime, end: $0.endTime) }
            results.append(diarize(id: file.fileId, audio: file.audio, reference: ref, manager: manager, collar: collar))
        }
        Runners.emit(report(results, label: label, collar: collar, diarizerConfig: diarizerConfig))
    }

    // MARK: Shared

    private static func makeDiarizer(config: DiarizerConfig) async throws -> DiarizerManager {
        let manager = DiarizerManager(config: config)
        let models = try await DiarizerModels.downloadIfNeeded()
        manager.initialize(models: models)
        return manager
    }

    private struct DiarizationCase {
        let id: String
        let der: MurmurCore.DERResult
        let hypSpeakers: Int
        let refSpeakers: Int
        let rtf: Double
    }

    private static func diarize(
        id: String, audio: [Float], reference: [MurmurCore.DERSegment], manager: DiarizerManager, collar: Double
    ) -> DiarizationCase {
        let durationSeconds = Double(audio.count) / 16_000
        let start = Date()
        let diarization = (try? manager.performCompleteDiarization(audio, sampleRate: 16_000))
        let elapsed = Date().timeIntervalSince(start)
        let rtf = durationSeconds > 0 ? elapsed / durationSeconds : 0
        let hyp = (diarization?.segments ?? []).map {
            MurmurCore.DERSegment(speaker: $0.speakerId, start: Double($0.startTimeSeconds), end: Double($0.endTimeSeconds))
        }
        let der = MurmurCore.DiarizationErrorRate.compute(reference: reference, hypothesis: hyp, collar: collar)
        return DiarizationCase(
            id: id, der: der, hypSpeakers: Set(hyp.map(\.speaker)).count,
            refSpeakers: Set(reference.map(\.speaker)).count, rtf: rtf)
    }

    private static func report(
        _ results: [DiarizationCase], label: String, collar: Double, diarizerConfig: DiarizerConfig
    ) -> String {
        let meanDER = results.map(\.der.der).reduce(0, +) / Double(results.count)
        let speakerCountCorrect = results.count { $0.hypSpeakers == $0.refSpeakers }
        let speakerCountAccuracy = Double(speakerCountCorrect) / Double(results.count)
        let meanRTF = results.map(\.rtf).reduce(0, +) / Double(results.count)

        let perFile = results.map { entry -> String in
            let totalRef = max(entry.der.totalReferenceSpeechSeconds, 0.001)
            return "  - \(entry.id): DER \(percent(entry.der.der)) " +
                "(miss \(percent(entry.der.missedSpeechSeconds / totalRef)), " +
                "FA \(percent(entry.der.falseAlarmSeconds / totalRef)), " +
                "confusion \(percent(entry.der.confusionSeconds / totalRef))), " +
                "speakers hyp \(entry.hypSpeakers)/ref \(entry.refSpeakers), RTF \(String(format: "%.4f", entry.rtf))×"
        }

        return """
            ### Diarization · \(label) · \(results.count) file(s) · collar \(collar)s
            - Mean DER: **\(percent(meanDER))**
            - Speaker-count accuracy: **\(percent(speakerCountAccuracy))** (\(speakerCountCorrect)/\(results.count))
            - Mean diarization RTF: \(String(format: "%.4f", meanRTF))×
            - Config: clusteringThreshold \(diarizerConfig.clusteringThreshold), minSpeechDuration \(diarizerConfig.minSpeechDuration)s, \
              minSilenceGap \(diarizerConfig.minSilenceGap)s, numClusters \(diarizerConfig.numClusters == -1 ? "auto" : "\(diarizerConfig.numClusters)")
            - Overlap handling: FluidAudio's segmentation model natively detects overlapped speech
              (per-frame multi-label output); this eval's DER scoring counts a reference frame as
              correctly attributed only when every active reference speaker at that frame maps to
              an active hypothesis speaker (standard NIST/pyannote convention) — no partial credit
              for detecting only one of several simultaneous speakers.
            - Scoring: frame-wise DER (10ms grid), Hungarian-style optimal hyp→ref speaker mapping
              by total overlap time, \(collar)s collar around reference speaker-change boundaries
              (see MurmurCore's `DiarizationErrorRate`, independent of FluidAudio's own DER helper).
            - Ground truth: official RTTM, not reconstructed — see AmiMeetingDownloader.swift /
              VoxConverseDownloader.swift doc comments for exact sources.

            Per file:
            \(perFile.joined(separator: "\n"))
            """
    }

    private static func skipReport(label: String, reason: String) -> String {
        """
        ### Diarization · \(label) · SKIPPED
        - Could not download official audio/RTTM: \(reason)
        - This eval needs network access (GitHub raw content + the dataset's official audio
          mirror); an offline environment should see this SKIP rather than a false DER number.
        """
    }

    private static func percent(_ value: Double) -> String { String(format: "%.1f%%", value * 100) }
}
