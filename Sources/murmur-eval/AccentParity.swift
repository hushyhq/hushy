import Foundation
import MurmurCore

/// `murmur-eval us-english parity`: WER for every EdAcc accent group with enough clips, with the
/// numbers an accent-parity claim has to survive — per-group 95% intervals (clip bootstrap, and
/// speaker bootstrap where a group has ≥ 3 speakers), how many speakers stand behind each group,
/// the spread across groups (max − min, standard deviation), the speaker-to-speaker spread inside
/// a single accent, and a permutation test of whether accent explains more than speakers do.
enum AccentParity {
    static func run(_ args: Arguments) async throws {
        let perGroup = args.int("per-group") ?? 100
        let minClips = args.int("min-clips") ?? 50
        let models = USEnglishRunner.list(args, "models", default: ["ultra+guard"])
        let clips = try await EdAccAccents.loadOrDownload(
            perGroup: perGroup, minClips: minClips, seed: UInt64(args.int("seed") ?? 42), root: Paths.data)
        guard !clips.isEmpty else { throw EvalError.missing("No EdAcc clips available") }
        if args.flag("download-only") {
            print("edacc-all-accents: \(clips.count) clips across \(Set(clips.compactMap(\.group)).count) accents")
            return
        }
        for model in models {
            let recognizer = try await USEnglishRunner.recognizer(named: model)
            let scored = try await USEnglishRunner.transcribe(clips, with: recognizer, label: "\(model) · edacc")
            try USEnglishRunner.dump(scored, set: EdAccAccents.folderName, model: model)
            Runners.emit(report(scored, model: model, minClips: minClips))
        }
    }

    struct GroupResult {
        let group: String
        let clips: Int
        let speakers: Int
        let wer: Double
        let clipInterval: (low: Double, high: Double)?
        let speakerInterval: (low: Double, high: Double)?
    }

    static func groups(_ scored: [ScoredClip]) -> [GroupResult] {
        Dictionary(grouping: scored, by: { $0.group ?? "unlabelled" }).map { group, members in
            let speakers = Set(members.map { $0.speaker ?? $0.id }).count
            return GroupResult(
                group: group, clips: members.count, speakers: speakers, wer: WERStats.wer(members),
                clipInterval: WERStats.interval(members),
                speakerInterval: speakers >= 3 ? WERStats.interval(members, cluster: { $0.speaker ?? $0.id }) : nil)
        }
        .sorted { $0.wer < $1.wer }
    }

    /// Per-speaker WERs inside each group that has at least `minSpeakers` speakers.
    static func withinGroupSpeakerSD(_ scored: [ScoredClip], minSpeakers: Int = 3) -> [(group: String, speakers: Int, sd: Double)] {
        Dictionary(grouping: scored, by: { $0.group ?? "unlabelled" }).compactMap { group, members in
            let bySpeaker = Dictionary(grouping: members, by: { $0.speaker ?? $0.id })
            guard bySpeaker.count >= minSpeakers else { return nil }
            return (group, bySpeaker.count, WERStats.standardDeviation(bySpeaker.values.map { WERStats.wer($0) }))
        }
        .sorted { $0.speakers > $1.speakers }
    }

    static func report(_ scored: [ScoredClip], model: String, minClips: Int) -> String {
        let results = groups(scored)
        let pct = USEnglishRunner.pct
        let rows = results.map { result in
            let clipCI = result.clipInterval.map { "\(pct($0.low))–\(pct($0.high))" } ?? "—"
            let speakerCI = result.speakerInterval.map { "\(pct($0.low))–\(pct($0.high))" } ?? "n/a (<3 speakers)"
            return "| \(result.group) | \(result.clips) | \(result.speakers) | **\(pct(result.wer))** | \(clipCI) | \(speakerCI) |"
        }
        let spread = spreadLines(results)
        let within = withinGroupSpeakerSD(scored).map {
            "  - \($0.group): \($0.speakers) speakers, per-speaker WER SD \(pct($0.sd))"
        }
        let test = WERStats.accentPermutationTest(scored)
        return """
            ### Accent parity · EdAcc (validation+test), all accent groups ≥ \(minClips) clips · \(model) · \(WhisperEnglishNormalizer.version)
            - Overall: **\(pct(WERStats.wer(scored)))** WER on \(scored.count) clips, \(results.count) groups, \(Set(scored.map { $0.speaker ?? $0.id }).count) speakers
            | Accent | Clips | Speakers | WER | 95% CI (clips) | 95% CI (speakers) |
            |---|---|---|---|---|---|
            \(rows.joined(separator: "\n"))
            \(spread.joined(separator: "\n"))
            - Speaker-to-speaker spread inside one accent:
            \(within.joined(separator: "\n"))
            - Permutation test (speakers shuffled across accent labels, 2,000×): observed SD of group WERs \(pct(test.observedSD)), p = \(String(format: "%.3f", test.pValue))
            """
    }

    static func spreadLines(_ results: [GroupResult]) -> [String] {
        let pct = USEnglishRunner.pct
        func line(_ label: String, _ subset: [GroupResult]) -> String? {
            guard let best = subset.first, let worst = subset.last, subset.count > 1 else { return nil }
            let sd = WERStats.standardDeviation(subset.map(\.wer))
            return "- Spread, \(label) (\(subset.count) groups): \(pct(best.wer)) (\(best.group)) to \(pct(worst.wer)) (\(worst.group)), "
                + "max − min **\(String(format: "%.1f", (worst.wer - best.wer) * 100)) points**, SD \(String(format: "%.1f", sd * 100)) points"
        }
        return [
            line("all groups", results),
            line("groups with ≥ 3 speakers", results.filter { $0.speakers >= 3 }),
        ].compactMap { $0 }
    }
}
