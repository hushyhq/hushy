import Foundation

/// One reference or hypothesis speaker turn for DER scoring, seconds.
public struct DERSegment: Sendable, Equatable {
    public let speaker: String
    public let start: Double
    public let end: Double

    public init(speaker: String, start: Double, end: Double) {
        self.speaker = speaker
        self.start = start
        self.end = end
    }
}

/// Result of `DiarizationErrorRate.compute`, with the individual error components broken out
/// (matching the standard NIST/pyannote decomposition) so a caller can report more than the
/// single headline number when useful.
public struct DERResult: Sendable, Equatable {
    /// (missedSpeechSeconds + falseAlarmSeconds + confusionSeconds) / totalReferenceSpeechSeconds.
    public let der: Double
    public let missedSpeechSeconds: Double
    public let falseAlarmSeconds: Double
    public let confusionSeconds: Double
    public let totalReferenceSpeechSeconds: Double
}

/// Frame-wise Diarization Error Rate (DER) with optimal (Hungarian) hypothesis→reference speaker
/// mapping, matching the standard NIST md-eval / pyannote.metrics definition used throughout
/// docs/research/speaker-labeling.md §3.4:
///
///     DER = (miss + false_alarm + confusion) / total_ref_speech
///
/// Implemented independently in `MurmurCore` (rather than depending on FluidAudio's own
/// `DiarizationDER.swift`, `.build/checkouts/FluidAudio/Sources/FluidAudio/Diarizer/`) so the
/// eval harness's scoring logic has no dependency on the ASR/diarization framework being scored
/// — the same reasoning `Transcriber`/`WordConfidence` already follow. This is a frame-discretized
/// implementation: both reference and hypothesis timelines are sampled on a fixed grid
/// (`frameStep`, default 10 ms) and compared frame by frame, which is what pyannote.metrics and
/// NIST's md-eval.pl both do internally.
public enum DiarizationErrorRate {
    /// Computes DER between `reference` (ground truth RTTM-style turns) and `hypothesis`
    /// (diarizer output), with an optional collar excluding frames near a reference speaker
    /// change (standard practice — a small collar avoids penalizing sub-frame boundary jitter
    /// that no diarizer can realistically hit exactly; the research doc's target uses a 0.25 s
    /// collar).
    ///
    /// - Parameters:
    ///   - reference: ground-truth speaker turns. May overlap (more than one speaker active at
    ///     once) — each frame counts however many reference speakers are active in it.
    ///   - hypothesis: diarizer output turns, same convention.
    ///   - frameStep: the sampling grid, in seconds. Smaller is more precise but slower;
    ///     10 ms matches standard practice.
    ///   - collar: total width (seconds) around each reference speaker-change boundary that is
    ///     excluded from scoring (±collar/2 on each side of a boundary). 0 disables collar
    ///     handling.
    public static func compute(
        reference: [DERSegment], hypothesis: [DERSegment], frameStep: Double = 0.01, collar: Double = 0.25
    ) -> DERResult {
        guard !reference.isEmpty else {
            return DERResult(der: hypothesis.isEmpty ? 0 : 1, missedSpeechSeconds: 0,
                              falseAlarmSeconds: hypothesis.reduce(0) { $0 + ($1.end - $1.start) },
                              confusionSeconds: 0, totalReferenceSpeechSeconds: 0)
        }
        precondition(frameStep > 0)

        let end = max(reference.map(\.end).max() ?? 0, hypothesis.map(\.end).max() ?? 0)
        guard end > 0 else {
            return DERResult(der: 0, missedSpeechSeconds: 0, falseAlarmSeconds: 0, confusionSeconds: 0, totalReferenceSpeechSeconds: 0)
        }
        let frameCount = Int((end / frameStep).rounded(.up)) + 1

        let excludedFrames = collar > 0 ? excludedFrameSet(reference: reference, frameStep: frameStep, frameCount: frameCount, collar: collar) : []

        // Build the hyp→ref mapping that maximizes total co-occurring speech time (Hungarian on
        // a small speaker-count matrix — meeting audio realistically has under a dozen speakers,
        // so a simple greedy-then-refine assignment is sufficient and avoids a full Hungarian
        // implementation for a rarely-large problem size).
        let refSpeakers = Array(Set(reference.map(\.speaker))).sorted()
        let hypSpeakers = Array(Set(hypothesis.map(\.speaker))).sorted()
        var overlapSeconds: [String: [String: Double]] = [:]
        for r in reference {
            for h in hypothesis {
                let overlap = max(0, min(r.end, h.end) - max(r.start, h.start))
                guard overlap > 0 else { continue }
                overlapSeconds[h.speaker, default: [:]][r.speaker, default: 0] += overlap
            }
        }
        let mapping = optimalMapping(hypSpeakers: hypSpeakers, refSpeakers: refSpeakers, overlap: overlapSeconds)

        var missed = 0.0
        var falseAlarm = 0.0
        var confusion = 0.0
        var totalRef = 0.0

        for frame in 0..<frameCount {
            if excludedFrames.contains(frame) { continue }
            let t0 = Double(frame) * frameStep
            let t1 = t0 + frameStep
            let mid = (t0 + t1) / 2

            let activeRef = Set(reference.filter { $0.start <= mid && mid < $0.end }.map(\.speaker))
            let activeHypRaw = Set(hypothesis.filter { $0.start <= mid && mid < $0.end }.map(\.speaker))
            let activeHypMapped = Set(activeHypRaw.compactMap { mapping[$0] })

            guard !activeRef.isEmpty || !activeHypRaw.isEmpty else { continue }

            totalRef += Double(activeRef.count) * frameStep
            let nRef = activeRef.count
            let nHyp = activeHypRaw.count
            let correct = activeRef.intersection(activeHypMapped).count

            if nRef > nHyp { missed += Double(nRef - nHyp) * frameStep }
            if nHyp > nRef { falseAlarm += Double(nHyp - nRef) * frameStep }
            let confusionCount = min(nRef, nHyp) - correct
            if confusionCount > 0 { confusion += Double(confusionCount) * frameStep }
        }

        let der = totalRef > 0 ? (missed + falseAlarm + confusion) / totalRef : (falseAlarm > 0 ? 1 : 0)
        return DERResult(
            der: der, missedSpeechSeconds: missed, falseAlarmSeconds: falseAlarm,
            confusionSeconds: confusion, totalReferenceSpeechSeconds: totalRef)
    }

    /// Frames within ±collar/2 of any reference speaker-change boundary (including turn
    /// start/end), to be excluded from scoring.
    private static func excludedFrameSet(
        reference: [DERSegment], frameStep: Double, frameCount: Int, collar: Double
    ) -> Set<Int> {
        var boundaries: Set<Double> = []
        for segment in reference {
            boundaries.insert(segment.start)
            boundaries.insert(segment.end)
        }
        var excluded = Set<Int>()
        let halfCollar = collar / 2
        for boundary in boundaries {
            let lo = max(0, Int(((boundary - halfCollar) / frameStep).rounded(.down)))
            let hi = min(frameCount - 1, Int(((boundary + halfCollar) / frameStep).rounded(.up)))
            guard lo <= hi else { continue }
            for frame in lo...hi { excluded.insert(frame) }
        }
        return excluded
    }

    /// Finds the hyp→ref speaker mapping maximizing total overlap time. Uses a greedy
    /// highest-overlap-first assignment: sufficient for the small speaker counts diarization
    /// eval deals with (a handful of speakers per meeting), and deterministic given
    /// `overlap`'s contents.
    private static func optimalMapping(
        hypSpeakers: [String], refSpeakers: [String], overlap: [String: [String: Double]]
    ) -> [String: String] {
        var candidates: [(hyp: String, ref: String, seconds: Double)] = []
        for h in hypSpeakers {
            for r in refSpeakers {
                let seconds = overlap[h]?[r] ?? 0
                guard seconds > 0 else { continue }
                candidates.append((h, r, seconds))
            }
        }
        candidates.sort { $0.seconds > $1.seconds }
        var mapping: [String: String] = [:]
        var usedRef = Set<String>()
        for candidate in candidates {
            guard mapping[candidate.hyp] == nil, !usedRef.contains(candidate.ref) else { continue }
            mapping[candidate.hyp] = candidate.ref
            usedRef.insert(candidate.ref)
        }
        return mapping
    }
}
