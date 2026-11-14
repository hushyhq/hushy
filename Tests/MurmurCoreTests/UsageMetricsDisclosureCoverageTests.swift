import Foundation
import Testing
@testable import MurmurCore

/// "What's sent" in two layers. The detail shows every field the encoder writes, each in its own
/// section; the summary maps every field to exactly one plain bullet. A new field cannot ship
/// without being shown in the detail and without fitting a bullet (or forcing a new one).
@Suite("Usage metrics: disclosure coverage", .timeLimit(.minutes(1)))
struct UsageMetricsDisclosureCoverageTests {
    typealias F = UsageMetricsFixtures

    /// The fully populated batch (version 4, with retention, tones and the edit rate) and the same batch as older
    /// queue files (version 3, no edit rate; version 2, no tones; version 1, no retention either): between them
    /// every optional key is present at least once.
    private func variants() throws -> [DailyMetricsBatch] {
        let v4 = try F.fullyPopulatedBatch()
        var object = try #require(JSONSerialization.jsonObject(with: v4.encodedBody()) as? [String: Any])
        func decoded(_ object: [String: Any]) throws -> DailyMetricsBatch {
            try JSONDecoder().decode(
                DailyMetricsBatch.self, from: JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes]))
        }
        object["schemaVersion"] = 3
        object["editRate"] = nil
        let v3 = try decoded(object)
        object["schemaVersion"] = 2
        object["tones"] = nil
        let v2 = try decoded(object)
        object["schemaVersion"] = 1
        object["retention"] = nil
        return [v4, v3, v2, try decoded(object)]
    }

    /// Every structural path in the encoded bytes, arrays included. A table (an object of plain
    /// integers) is one path; its keys are closed-vocabulary cases and are checked by value. The
    /// keys under `dictations` are cleanup profiles and show as `*`.
    private func paths(in value: Any, at path: String = "") -> [String] {
        if let array = value as? [Any] { return array.flatMap { paths(in: $0, at: path) } }
        guard let object = value as? [String: Any] else { return [] }
        if !object.isEmpty, !path.isEmpty, object.values.allSatisfy({ $0 is NSNumber }) { return [] }
        var found: [String] = []
        for (key, child) in object {
            let name = path == "dictations" ? "*" : key
            let childPath = path.isEmpty ? name : "\(path).\(name)"
            found.append(childPath)
            found += paths(in: child, at: childPath)
        }
        return found
    }

    private func encodedPaths(_ batch: DailyMetricsBatch) throws -> Set<String> {
        Set(paths(in: try JSONSerialization.jsonObject(with: batch.encodedBody())))
    }

    // MARK: the detail

    @Test("every key the encoder writes has words, and the labels name no key the encoder never writes")
    func everyKeyHasWords() throws {
        var all = Set<String>()
        for batch in try variants() {
            let found = try encodedPaths(batch)
            #expect(found.count > 25)                                   // the walk really saw the batch
            for path in found.sorted() where MetricsDisclosure.fieldLabels[path] == nil {
                Issue.record("no disclosure words for the encoded field \(path)")
            }
            all.formUnion(found)
        }
        for path in MetricsDisclosure.fieldLabels.keys where !all.contains(path) { Issue.record("label for \(path), which is never written") }
    }

    /// The section each field must appear in.
    private func sectionTitles(for path: String, batch: DailyMetricsBatch) -> [String] {
        switch path.split(separator: ".").first.map(String.init) ?? "" {
        case "schemaVersion", "batchID", "day", "appBuild": return ["This batch"]
        case "environment": return ["Your Mac"]
        case "retention": return ["How long you have used Hushy"]
        case "voiceActions": return ["Voice actions"]
        case "meetings": return ["Meetings"]
        case "funnel": return ["Setup"]
        case "tones": return ["Tone"]
        case "editRate": return [MetricsDisclosure.editRateTitle]
        default: return path == "dictations" ? ["Dictations"] : batch.dictationsByProfile.keys.map { "Dictations, \($0.disclosureLabel)" }
        }
    }

    @Test("each field's words appear in its own section, for every cleanup profile")
    func wordsAreInTheirOwnSection() throws {
        for batch in try variants() {
            let sections = MetricsDisclosure.sections(for: batch, isPreview: true)
            for path in try encodedPaths(batch).sorted() {
                let words = try #require(MetricsDisclosure.fieldLabels[path])
                for title in sectionTitles(for: path, batch: batch) {
                    let section = try #require(sections.first { $0.title == title }, "no section \(title)")
                    #expect(section.lines.joined(separator: "\n").contains(words), "\"\(words)\" (\(path)) missing from \(title)")
                }
            }
        }
    }

    @Test("every value shows in its own section: table cases, bucket counts, sums, profiles, Mac, retention, identity")
    func valuesAreInTheirOwnSection() throws {
        let batch = try F.fullyPopulatedBatch()
        let sections = MetricsDisclosure.sections(for: batch, isPreview: false)
        func text(_ title: String) throws -> String {
            try #require(sections.first { $0.title == title }, "no section \(title)").lines.joined(separator: "\n")
        }
        for (profile, totals) in batch.dictationsByProfile {
            let own = try text("Dictations, \(profile.disclosureLabel)")
            #expect(own.contains("Cleanup type: \(profile.disclosureLabel)"))
            #expect(own.contains("Dictations with this cleanup: \(totals.count)"))
            func tables<K: MetricsKey & MetricsDisclosureLabel>(_ table: MetricsCountTable<K>, skipping: String? = nil) {
                for key in K.allCases where table[key] > 0 && key.disclosureLabel != skipping { #expect(own.contains("\(key.disclosureLabel) \(table[key])"), "\(key.disclosureLabel)") }
            }
            tables(totals.delivery); tables(totals.editCoverage, skipping: DictationFeedback.EditCoverage.observed.disclosureLabel);   // `observed` is the kept and edited lines
             tables(totals.fallbackReason)
            tables(totals.cleanupLevel); tables(totals.modeKind); tables(totals.modelState)
            #expect(own.contains("Kept without edits: ") || totals.editObservation[.kept] + totals.editObservation[.edited] == 0)
            #expect(own.contains("Not checked: \(totals.editObservation[.unknown])"))
            for histogram in [totals.words, totals.audioMilliseconds, totals.speechMilliseconds, totals.cleanupMilliseconds,
                              totals.releaseToDeliveryMilliseconds] where histogram.sampleCount > 0 {
                for (bucket, count) in histogram.counts.enumerated() where count > 0 {
                    #expect(own.contains("\(MetricsDisclosure.label(for: histogram.spec, bucket: bucket)) ×\(count)"))
                }
                #expect(own.contains("total \(histogram.sum) "))
            }
        }
        let mac = try text("Your Mac")
        #expect(mac.contains(batch.environment.chipClass.disclosureLabel) && mac.contains(batch.environment.memoryBand.disclosureLabel))
        #expect(mac.contains("macOS \(batch.environment.macOSMajor)"))
        let retention = try #require(batch.retention)
        let usage = try text("How long you have used Hushy")
        #expect(usage.contains(retention.daysSinceFirstRun.disclosureLabel))
        #expect(usage.contains("\(retention.activeDaysLast7) of \(MetricsRetention.activeDayWindow)"))
        let voice = try text("Voice actions")
        #expect(voice.contains("\(batch.voiceActions.attempted) attempted"))
        for key in VoiceActionFailureCategory.allCases where batch.voiceActions.failure[key] > 0 {
            #expect(voice.contains("\(key.disclosureLabel) \(batch.voiceActions.failure[key])"))
        }
        let meetings = try text("Meetings")
        #expect(meetings.contains("\(batch.meetings.minutesRecorded) minutes recorded"))
        let tones = try #require(batch.tones)
        let toneText = try text("Tone")
        for tone in MetricsTone.allCases where tones[tone] > 0 { #expect(toneText.contains("\(tone.disclosureLabel) \(tones[tone])")) }
        let editRate = try #require(batch.editRate)
        let editText = try text(MetricsDisclosure.editRateTitle)
        #expect(editText.contains("\(editRate.total) pasted dictations in all"))
        for (key, count) in editRate.counts {
            #expect(editText.contains(key.verdict == .edited ? "edited (\(key.size.disclosureLabel)) \(count)" : "\(key.verdict.disclosureLabel) \(count)"),
                    "\(key)")
            #expect(editText.contains("Tone \(key.tone.disclosureLabel), kind of app \(key.appKind.disclosureLabel):"))
        }
        let setup = try text("Setup")
        for step in FunnelStep.allCases where batch.funnel[step] > 0 { #expect(setup.contains("\(step.disclosureLabel) \(batch.funnel[step])")) }
    }

    @Test("identity fields are shown as encoded, a real batch shows its ID, a preview says it is made when saved, and the note is true")
    func identityFields() throws {
        let batch = try F.fullyPopulatedBatch()
        let json = try #require(JSONSerialization.jsonObject(with: batch.encodedBody()) as? [String: Any])
        let real = MetricsDisclosure.lines(for: batch).joined(separator: "\n")
        #expect(real.contains("Batch ID: \(batch.batchID.uuidString.lowercased())"))
        #expect((json["batchID"] as? String)?.lowercased() == batch.batchID.uuidString.lowercased())
        #expect(real.contains("Format version: \(json["schemaVersion"] as? Int ?? -1)"))
        #expect(real.contains("Day: \(json["day"] as? String ?? "?")"))
        #expect(real.contains("App build: \(json["appBuild"] as? Int ?? -1)"))
        let preview = MetricsDisclosure.lines(for: batch, isPreview: true).joined(separator: "\n")
        #expect(!preview.contains(batch.batchID.uuidString.lowercased()))                    // no throwaway ID shown as if real
        #expect(preview.contains(MetricsDisclosure.previewBatchID))
        #expect(MetricsDisclosure.previewBatchID.contains("made when the day is closed"))
        for text in [real, preview] { #expect(text.contains(MetricsDisclosure.batchIDNote)) }
        #expect(MetricsDisclosure.batchIDNote.contains("made fresh for each batch") && MetricsDisclosure.batchIDNote.contains("when its day is closed"))
        #expect(!MetricsDisclosure.batchIDNote.contains("each day"))
    }

    @Test("sums are shown as sums, with the average only beside them")
    func sumsAsEncoded() throws {
        let batch = try F.fullyPopulatedBatch()
        let lines = MetricsDisclosure.lines(for: batch)
        for totals in batch.dictationsByProfile.values where totals.words.sampleCount > 0 {
            #expect(lines.contains { $0.hasPrefix("Words per dictation:") && $0.contains("total \(totals.words.sum) words") && $0.contains("average ") })
        }
    }

    // MARK: the summary

    @Test("every encoded key maps to exactly one summary bullet, and no bullet is claimed by nothing")
    func everyKeyHasABullet() throws {
        var all = Set<String>()
        for batch in try variants() { all.formUnion(try encodedPaths(batch)) }
        for path in all.sorted() where MetricsDisclosure.summaryBulletForField[path] == nil {
            Issue.record("encoded field \(path) fits no summary bullet: map it to one, or add a bullet")
        }
        for path in MetricsDisclosure.summaryBulletForField.keys where !all.contains(path) { Issue.record("bullet mapping for \(path), which is never written") }
        let used = Set(MetricsDisclosure.summaryBulletForField.values)
        for bullet in MetricsDisclosure.SummaryBullet.allCases { #expect(used.contains(bullet), "no field behind: \(bullet.text)") }
    }

    @Test("the summary is short and plain, and does not claim to be the full list")
    func summaryIsShortAndHonest() {
        let bullets = MetricsDisclosure.SummaryBullet.allCases
        #expect((5...6).contains(bullets.count))
        for bullet in bullets {
            #expect(bullet.text.count < 100 && !bullet.text.contains("ms") && !bullet.text.contains("histogram"))
            #expect(!bullet.text.localizedCaseInsensitiveContains("in full") && !bullet.text.localizedCaseInsensitiveContains("everything"))
        }
        let batchNote = MetricsDisclosure.SummaryBullet.identity.text
        #expect(batchNote.contains("random batch number") && batchNote.contains("not tied to you or your Mac"))
    }
}
