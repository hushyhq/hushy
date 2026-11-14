import Foundation

/// Turns a batch into the plain sentences a person can read to check what would be shared.
/// Pure: the same batch always gives the same lines. It reads only the batch, so it cannot show
/// (or leak) anything the batch does not hold.
public enum MetricsDisclosure {
    /// The closing promise, shown with every disclosure (also on its own when nothing is recorded yet).
    public static let neverSent =
        "Never sent: what you say or write, transcripts, audio, text from any field, the names of apps or windows, "
        + "web addresses, file names or paths, learned words, or anything that identifies you or this Mac."

    /// One titled group of sentences in the "See what's sent" sheet.
    public struct Section: Sendable, Equatable {
        public let title: String
        public let lines: [String]
    }

    /// Everything the batch's bytes hold, in plain words and grouped, then the never-sent promise.
    public static func lines(for batch: DailyMetricsBatch, isPreview: Bool = false) -> [String] {
        sections(for: batch, isPreview: isPreview).flatMap(\.lines) + [neverSent]
    }

    // MARK: - The short summary

    /// The few plain bullets on the sheet's first view. Not the full list: the sheet says so and
    /// offers the field-by-field batch one step away.
    public enum SummaryBullet: Int, CaseIterable, Sendable {
        case counts, timings, outcomes, mac, usage, identity

        public var text: String {
            switch self {
            case .counts: "How many dictations, voice actions and meetings you did, and each dictation's tone and kind of app"
            case .timings: "How long dictations were and how long each step took, such as recognising speech and pasting"
            case .outcomes: "Whether text was pasted or copied, how cleanup went, and how much you edited it afterwards"
            case .mac: "Your Mac's general type, its macOS version and the Hushy version"
            case .usage: "Roughly how long you have used Hushy, and how far setup got"
            case .identity: "The date, the data format and a random batch number, not tied to you or your Mac"
            }
        }
    }

    /// Which summary bullet each encoded field belongs to (same paths as `fieldLabels`). A test walks
    /// the encoded bytes and fails if a field is missing here, so a new field must fit a bullet or
    /// force a new one. Every bullet must be used by at least one field.
    public static let summaryBulletForField: [String: SummaryBullet] = {
        var map: [String: SummaryBullet] = [
            "schemaVersion": .identity, "batchID": .identity, "day": .identity,
            "appBuild": .mac, "environment": .mac, "environment.chipClass": .mac, "environment.memoryBand": .mac,
            "environment.macOSMajor": .mac,
            "retention": .usage, "retention.daysSinceFirstRun": .usage, "retention.activeDaysLast7": .usage, "funnel": .usage,
            "dictations": .counts, "dictations.*": .counts, "tones": .counts,
            "editRate": .outcomes, "editRate.tone": .counts, "editRate.appKind": .counts,
            "editRate.verdict": .outcomes, "editRate.size": .outcomes, "editRate.count": .outcomes,
            "voiceActions": .counts, "voiceActions.outcome": .counts, "voiceActions.failure": .counts,
            "meetings": .counts, "meetings.outcome": .counts, "meetings.minutesRecorded": .counts,
        ]
        for key in ["delivery", "editObservation", "editCoverage", "fallbackReason", "cleanupLevel", "modeKind", "modelState"] {
            map["dictations.*.\(key)"] = .outcomes
        }
        for key in ["words", "audioMilliseconds", "speechMilliseconds", "cleanupMilliseconds", "releaseToDeliveryMilliseconds"] {
            for suffix in ["", ".counts", ".sum"] { map["dictations.*.\(key)\(suffix)"] = .timings }
        }
        return map
    }()

    /// For every field the encoder can write (a dotted path, with `*` for the cleanup profile), the
    /// words the sheet uses for it. A test walks the encoded bytes of a fully populated batch and
    /// fails if a path has no entry here or its words do not appear in the disclosure, so a new
    /// field cannot ship without being shown.
    public static let fieldLabels: [String: String] = {
        var labels = [
            "schemaVersion": "Format version", "batchID": "Batch ID", "day": "Day", "appBuild": "App build",
            "environment": "Your Mac", "environment.chipClass": "Your Mac", "environment.memoryBand": "memory",
            "environment.macOSMajor": "macOS",
            "retention": "Time since you started using Hushy", "retention.daysSinceFirstRun": "Time since you started using Hushy",
            "retention.activeDaysLast7": "Days you used Hushy in the last week",
            "dictations": "Dictations", "dictations.*": "Dictations with this cleanup",
            "voiceActions": "Voice actions", "voiceActions.outcome": "succeeded", "voiceActions.failure": "Voice action failures",
            "meetings": "Meetings", "meetings.outcome": "started", "meetings.minutesRecorded": "minutes recorded",
            "funnel": "Setup steps reached", "tones": "Tone used",
            "editRate": "Edits by tone and kind of app", "editRate.tone": "Tone", "editRate.appKind": "kind of app",
            "editRate.verdict": "kept as typed", "editRate.size": "words", "editRate.count": "pasted dictations",
        ]
        let tables = [
            "delivery": "Outcome", "editObservation": "Not checked", "editCoverage": "Why edits were not checked",
            "fallbackReason": "Fell back to simpler cleanup", "cleanupLevel": "Cleanup used", "modeKind": "Mode type",
            "modelState": "Model state",
        ]
        let histograms = [
            "words": "Words per dictation", "audioMilliseconds": "Audio length", "speechMilliseconds": "Speech recognition time",
            "cleanupMilliseconds": "Cleanup time", "releaseToDeliveryMilliseconds": "Time to paste",
        ]
        for (key, words) in tables { labels["dictations.*.\(key)"] = words }
        for (key, words) in histograms {
            labels["dictations.*.\(key)"] = words
            labels["dictations.*.\(key).counts"] = "×"
            labels["dictations.*.\(key).sum"] = "total"
        }
        return labels
    }()

    /// Said in plain words next to the ID, because an ID is the thing people worry about. True to
    /// the code: each batch gets its own random UUID when its day is closed (before it is saved to
    /// the queue), kept in the data epoch's own folder, so it cannot be derived from, or repeated
    /// across, days or epochs.
    public static let batchIDNote =
        "The batch ID is a random number, made fresh for each batch when its day is closed. It is not tied to this Mac or to you."

    /// What the detailed list says instead of an ID while the batch is only a preview: the real ID
    /// is made when the day is closed, so a preview must not show one as if it were real.
    public static let previewBatchID = "Batch ID: a random number, made when the day is closed"

    /// Every field `DailyMetricsBatch.encodedBody()` writes, as a titled group. Values are shown as
    /// encoded (sums as sums, counts as counts); an average may follow a sum but never replaces it.
    public static func sections(for batch: DailyMetricsBatch, isPreview: Bool = false) -> [Section] {
        var result = [
            Section(title: "This batch", lines: [
                "Format version: \(batch.schemaVersion)",
                isPreview ? previewBatchID : "Batch ID: \(batch.batchID.uuidString.lowercased())",
                batchIDNote,
                "Day: \(batch.day.isoString)",
                "App build: \(batch.appBuild)",
            ]),
            Section(title: "Your Mac", lines: [
                "Your Mac: \(batch.environment.chipClass.disclosureLabel), \(batch.environment.memoryBand.disclosureLabel), macOS \(batch.environment.macOSMajor)",
            ]),
        ]
        let retention = retentionLines(batch.retention)
        if !retention.isEmpty { result.append(Section(title: "How long you have used Hushy", lines: retention)) }
        result += dictationSections(batch)
        if let tones = batch.tones {
            // Always shown for a batch that carries the field, even when empty, so the line is never missing.
            result.append(Section(title: "Tone", lines: [tableLine("Tone used", tones) ?? "Tone used: none"]))
        }
        if let editRate = batch.editRate { result.append(Section(title: editRateTitle, lines: editRateLines(editRate))) }
        result.append(Section(title: "Voice actions", lines: voiceActionLines(batch.voiceActions)))
        result.append(Section(title: "Meetings", lines: meetingLines(batch.meetings)))
        let funnel = tableLine("Setup steps reached", batch.funnel) ?? "Setup steps reached: none"
        result.append(Section(title: "Setup", lines: [funnel]))
        return result
    }

    public static let editRateTitle = "Edits by tone and kind of app"

    /// One line per tone and kind of app that has a count, then the total line first. Always shown for a batch
    /// that carries the field, even when empty, so the line is never missing.
    private static func editRateLines(_ table: MetricsEditRateTable) -> [String] {
        guard table.total > 0 else { return ["\(editRateTitle): none"] }
        var lines = ["\(editRateTitle): \(table.total) pasted dictations in all"]
        for tone in MetricsTone.allCases {
            for kind in MetricsAppKind.allCases where table.total(tone: tone, appKind: kind) > 0 {
                var parts: [String] = []
                for verdict in MetricsEditVerdict.allCases {
                    for size in MetricsEditSize.allCases {
                        guard let key = try? MetricsEditRateKey(tone: tone, appKind: kind, verdict: verdict, size: size),
                              table[key] > 0 else { continue }
                        parts.append(verdict == .edited ? "edited (\(size.disclosureLabel)) \(table[key])" : "\(verdict.disclosureLabel) \(table[key])")
                    }
                }
                lines.append("Tone \(tone.disclosureLabel), kind of app \(kind.disclosureLabel): " + parts.joined(separator: ", "))
            }
        }
        return lines
    }

    private static func dictationSections(_ batch: DailyMetricsBatch) -> [Section] {
        let profiles = DictationFeedback.CleanupModelProfile.allCases.filter { batch.dictationsByProfile[$0] != nil }
        guard !profiles.isEmpty else { return [] }
        var result = [Section(title: "Dictations", lines: ["Dictations: \(batch.combinedDictations.count) in all"])]
        for profile in profiles {
            guard let totals = batch.dictationsByProfile[profile] else { continue }
            let lines = ["Cleanup type: \(profile.disclosureLabel)", "Dictations with this cleanup: \(totals.count)"] + dictationLines(totals)
            result.append(Section(title: "Dictations, \(profile.disclosureLabel)", lines: lines))
        }
        return result
    }

    private static func retentionLines(_ retention: MetricsRetention?) -> [String] {
        guard let retention else { return [] }
        return [
            "Time since you started using Hushy: \(retention.daysSinceFirstRun.disclosureLabel)",
            "Days you used Hushy in the last week: \(retention.activeDaysLast7) of \(MetricsRetention.activeDayWindow)",
        ]
    }

    /// A readable range for one histogram bucket, e.g. "3–5 words" or "under 250 ms".
    public static func label(for spec: MetricsHistogramSpec, bucket: Int) -> String {
        let edges = spec.upperEdges
        let unit = spec == .words ? "words" : "ms"
        if spec == .audioMilliseconds { return audioLabel(edges: edges, bucket: bucket) }
        if bucket == 0 { return edges[0] == 1 && spec == .words ? "0 words" : "under \(edges[0]) \(unit)" }
        if bucket >= edges.count { return "\(edges[edges.count - 1])+ \(unit)" }
        let lower = edges[bucket - 1], upper = edges[bucket] - 1
        return lower == upper ? "\(lower) \(unit)" : "\(lower)–\(upper) \(unit)"
    }

    private static func audioLabel(edges: [Int], bucket: Int) -> String {
        if bucket == 0 { return "under \(edges[0] / 1_000) s" }
        if bucket >= edges.count { return "\(edges[edges.count - 1] / 1_000)+ s" }
        return "\(edges[bucket - 1] / 1_000) s to under \(edges[bucket] / 1_000) s"
    }

    private static func dictationLines(_ totals: DictationMetricTotals) -> [String] {
        var lines: [String] = []
        let checked = totals.editObservation[.kept] + totals.editObservation[.edited]
        if checked > 0 {
            lines.append("Kept without edits: \(totals.editObservation[.kept]) of \(checked) checked")
            lines.append("Edited after pasting: \(totals.editObservation[.edited]) of \(checked) checked")
        }
        lines.append("Not checked: \(totals.editObservation[.unknown])")
        lines += [tableLine("Outcome", totals.delivery) ?? "Outcome: none"]
        lines += [tableLine("Why edits were not checked", totals.editCoverage, excluding: [.observed]) ?? "Why edits were not checked: none"]
        lines += [tableLine("Cleanup used", totals.cleanupLevel) ?? "Cleanup used: none"]
        lines += [tableLine("Fell back to simpler cleanup", totals.fallbackReason) ?? "Fell back to simpler cleanup: none"]
        lines += [tableLine("Mode type", totals.modeKind) ?? "Mode type: none"]
        lines += [tableLine("Model state", totals.modelState) ?? "Model state: none"]
        lines += histogramLine("Words per dictation", totals.words)
        lines += histogramLine("Audio length", totals.audioMilliseconds)
        lines += histogramLine("Speech recognition time", totals.speechMilliseconds)
        lines += histogramLine("Cleanup time", totals.cleanupMilliseconds)
        lines += histogramLine("Time to paste", totals.releaseToDeliveryMilliseconds)
        return lines
    }

    private static func voiceActionLines(_ totals: VoiceActionTotals) -> [String] {
        let outcome = totals.outcome
        var lines = [
            "Voice actions: \(totals.attempted) attempted, \(outcome[.succeeded]) succeeded, "
                + "\(outcome[.failed]) failed, \(outcome[.cancelled]) cancelled"
        ]
        lines += [tableLine("Voice action failures", totals.failure) ?? "Voice action failures: none"]
        return lines
    }

    private static func meetingLines(_ totals: MeetingTotals) -> [String] {
        let outcome = totals.outcome
        return ["Meetings: \(outcome[.started]) started, \(outcome[.completed]) completed, "
            + "\(outcome[.discarded]) discarded, \(totals.minutesRecorded) minutes recorded"]
    }

    private static func tableLine<K: MetricsKey & MetricsDisclosureLabel>(
        _ title: String, _ table: MetricsCountTable<K>, excluding: Set<K> = []
    ) -> String? {
        let parts = K.allCases.filter { !excluding.contains($0) && table[$0] > 0 }.map { "\($0.disclosureLabel) \(table[$0])" }
        return parts.isEmpty ? nil : "\(title): " + parts.joined(separator: ", ")
    }

    /// Non-empty buckets with counts, then the exact total as encoded and the average beside it.
    /// Empty histograms produce no line.
    private static func histogramLine(_ title: String, _ histogram: MetricsHistogram) -> [String] {
        let samples = histogram.sampleCount
        guard samples > 0 else { return ["\(title): none"] }
        let parts = histogram.counts.enumerated().filter { $0.element > 0 }
            .map { "\(label(for: histogram.spec, bucket: $0.offset)) ×\($0.element)" }
        let unit = histogram.spec == .words ? "words" : "ms"
        return ["\(title): " + parts.joined(separator: ", ") + " (total \(histogram.sum) \(unit), average \(histogram.sum / samples) \(unit))"]
    }
}
