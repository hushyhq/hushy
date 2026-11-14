import Foundation
import Testing
@testable import MurmurCore

/// The count of dictations per tone they really ran with: what decides the tone, how it is counted,
/// that it stays counts-only, and that older batches and journal lines still read.
@Suite("Usage metrics: tones", .timeLimit(.minutes(1)))
struct MetricsToneTests {
    typealias F = UsageMetricsFixtures

    private func applied(
        _ tones: ToneSettings, _ category: AppCategory, bundleID: String? = nil, registerSent: Bool = true, verbatimMode: Bool = false
    ) -> MetricsTone {
        // The session's mode is the stock Default resolved against the person's setting, as at key-down.
        var mode = Mode.builtIns(userName: "")[0].resolvingAppCleanupLevel(tones.dictationLevel)
        if verbatimMode { mode.cleanupLevel = .verbatim }
        return MetricsTone.applied(by: tones, mode: mode, category: category, bundleID: bundleID, registerSent: registerSent)
    }

    // MARK: which tone ran

    @Test("the default is Refined; email starts on Professional; a chosen default tone follows")
    func defaults() {
        #expect(applied(.standard, .other) == .refined)
        #expect(applied(.standard, .email) == .professional)
        #expect(applied(ToneSettings(defaultTone: .casual), .other) == .casual)
        #expect(applied(ToneSettings(defaultTone: .professional), .documents) == .professional)
    }

    @Test("As spoken counts as As spoken, from the setting or from a verbatim mode, in every app")
    func asSpoken() {
        for category in AppCategory.allCases {
            #expect(applied(ToneSettings(isAsSpoken: true), category) == .asSpoken, "\(category)")
        }
        #expect(applied(.standard, .email, verbatimMode: true) == .asSpoken)
    }

    @Test("the tone for the kind of app, not the default alone")
    func kindOfApp() {
        let tones = ToneSettings(defaultTone: .refined).settingTone(.casual, for: .personalMessages)
        #expect(applied(tones, .personalMessages) == .casual)
        #expect(applied(tones, .other) == .refined)
    }

    @Test("an app's own choice wins over its kind and the default")
    func perApp() {
        let tones = ToneSettings(defaultTone: .professional).settingApp(.tone(.casual), bundleIDs: ["com.example.chat"])
        #expect(applied(tones, .personalMessages, bundleID: "com.example.chat") == .casual)
        #expect(applied(tones, .personalMessages, bundleID: "com.example.other") == .professional)
    }

    @Test("an AI app counts as Prompt only when the prompt register was really sent")
    func prompt() {
        let tones = ToneSettings(defaultTone: .casual)
        #expect(applied(tones, .aiPrompts, registerSent: true) == .prompt)
        #expect(applied(tones, .aiPrompts, registerSent: false) == .casual)   // ran with its place's tone
        #expect(applied(.standard, .aiPrompts, registerSent: false) == .refined)
    }

    @Test("a model that is not sent register lines still counts the tone the word-level pass applied")
    func registerNotSent() {
        #expect(applied(.standard, .email, registerSent: false) == .professional)
        #expect(applied(ToneSettings(defaultTone: .casual), .other, registerSent: false) == .casual)
    }

    @Test("a code editor or terminal is repaired for grammar with no tone, so it is Refined")
    func code() {
        #expect(applied(ToneSettings(defaultTone: .casual), .code) == .refined)
    }

    // MARK: counting

    @Test("each dictation counts once under its tone, and one that never ran cleanup counts under none")
    func counting() throws {
        let records = [
            F.record(.dictation(F.dictation(tone: .refined))), F.record(.dictation(F.dictation(tone: .refined))),
            F.record(.dictation(F.dictation(tone: .casual))), F.record(.dictation(F.dictation(tone: .asSpoken))),
            F.record(.dictation(F.dictation(tone: nil))),
        ]
        let batch = try #require(F.builder().close(records: records, environment: F.environment, now: F.noonOct4).closedBatches.first)
        let tones = try #require(batch.tones)
        #expect(tones[.refined] == 2 && tones[.casual] == 1 && tones[.asSpoken] == 1)
        #expect(tones[.professional] == 0 && tones[.prompt] == 0)
        #expect(tones.total == 4 && batch.combinedDictations.count == 5)
    }

    @Test("the batch encodes every tone as a plain count and nothing else about it")
    func encoding() throws {
        let batch = try F.fullyPopulatedBatch()
        let object = try #require(JSONSerialization.jsonObject(with: batch.encodedBody()) as? [String: Any])
        let tones = try #require(object["tones"] as? [String: Int])
        #expect(Set(tones.keys) == ["refined", "professional", "casual", "prompt", "asSpoken"])
        #expect(tones.values.allSatisfy { $0 >= 1 })
    }

    @Test("more tones than dictations is refused, building or decoding")
    func validation() throws {
        var table = MetricsCountTable<MetricsTone>()
        table.increment(.refined); table.increment(.casual)
        #expect(throws: MetricsValidationError.inconsistentTones) {
            try DailyMetricsBatch(
                batchID: UUID(), day: MetricsDay(year: 2026, month: 10, day: 3), appBuild: 1, environment: F.environment,
                dictationsByProfile: Self.oneDictation(), voiceActions: VoiceActionTotals(), meetings: MeetingTotals(),
                funnel: MetricsCountTable(), retention: MetricsRetention(daysSinceFirstRun: .day0, activeDaysLast7: 1), tones: table)
        }
        var object = try #require(JSONSerialization.jsonObject(with: F.simpleBatch().encodedBody()) as? [String: Any])
        object["tones"] = ["refined": 5]
        let bytes = try JSONSerialization.data(withJSONObject: object)
        #expect((try? JSONDecoder().decode(DailyMetricsBatch.self, from: bytes)) == nil)
        object["tones"] = ["refined": 1, "friendly": 1]                  // not a tone
        #expect((try? JSONDecoder().decode(DailyMetricsBatch.self, from: JSONSerialization.data(withJSONObject: object))) == nil)
    }

    private static func oneDictation() -> [DictationFeedback.CleanupModelProfile: DictationMetricTotals] {
        var totals = DictationMetricTotals()
        totals.record(F.dictation())
        return [.localFineTuned: totals]
    }

    // MARK: older data

    @Test("a version 2 batch from an older queue file decodes with no tones and re-encodes to the same bytes")
    func versionTwoUnchanged() throws {
        var object = try #require(JSONSerialization.jsonObject(with: F.simpleBatch().encodedBody()) as? [String: Any])
        object["schemaVersion"] = 2
        object["tones"] = nil
        object["editRate"] = nil
        let stored = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes])
        let decoded = try JSONDecoder().decode(DailyMetricsBatch.self, from: stored)
        #expect(decoded.schemaVersion == 2 && decoded.tones == nil)
        #expect(try decoded.encodedBody() == stored)
    }

    @Test("version and tones must agree: v3 needs tones, v2 must not carry them")
    func versionAndTonesAgree() throws {
        let base = try #require(JSONSerialization.jsonObject(with: F.simpleBatch().encodedBody()) as? [String: Any])
        func rejected(_ mutate: (inout [String: Any]) -> Void) -> Bool {
            var object = base
            mutate(&object)
            guard let data = try? JSONSerialization.data(withJSONObject: object) else { return false }
            return (try? JSONDecoder().decode(DailyMetricsBatch.self, from: data)) == nil
        }
        #expect(rejected { $0["tones"] = nil })
        #expect(rejected { $0["schemaVersion"] = 2 })
    }

    @Test("a journal line written before tones existed still reads, with no tone")
    func oldJournalLine() throws {
        let record = F.record(.dictation(F.dictation(tone: .casual)))
        var object = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(record)) as? [String: Any])
        func strip(_ any: Any) -> Any {
            if var dict = any as? [String: Any] { dict["tone"] = nil; return dict.mapValues(strip) }
            return any
        }
        object = try #require(strip(object) as? [String: Any])
        let decoded = try JSONDecoder().decode(MetricEventRecord.self, from: JSONSerialization.data(withJSONObject: object))
        guard case .dictation(let event) = decoded.event else { Issue.record("not a dictation"); return }
        #expect(event.tone == nil)
        guard case .dictation(let kept) = record.event.normalized else { Issue.record("not a dictation"); return }
        #expect(kept.tone == .casual)
    }

    @Test("the edit verdict keeps the tone")
    func editKeepsTone() throws {
        let event = F.dictation(tone: .professional)
        let edited = try #require(event.withEdit(observation: .edited, coverage: .observed))
        #expect(edited.tone == .professional)
        let input = DictationMetricInput(
            result: .pasted, modelOutcome: .used, backend: .apple, cleanupLevel: .clean, mode: nil, wordCount: 10, audioSeconds: 2,
            speechMilliseconds: 100, cleanupMilliseconds: 200, releaseToDeliveryMilliseconds: 500, tone: .prompt)
        #expect(try input.event().tone == .prompt)
        #expect(try input.withEdit(observation: .kept, coverage: .observed).event().tone == .prompt)
    }

    // MARK: what the person is shown

    @Test("the sheet lists the tones as counts, with an example line")
    func disclosure() throws {
        let batch = try F.fullyPopulatedBatch()
        let sections = MetricsDisclosure.sections(for: batch, isPreview: true)
        let tone = try #require(sections.first { $0.title == "Tone" })
        let line = try #require(tone.lines.first)
        let tones = try #require(batch.tones)
        #expect(line.hasPrefix("Tone used: "))
        for key in MetricsTone.allCases { #expect(line.contains("\(key.disclosureLabel) \(tones[key])")) }
        #expect(MetricsDisclosure.SummaryBullet.counts.text.contains("tone"))
        #expect(MetricsDisclosure.summaryBulletForField["tones"] == .counts)
        // Nothing but the five tone names and counts: no app, no word.
        #expect(Set(MetricsTone.allCases.map(\.disclosureLabel)) == ["Refined", "Professional", "Casual", "Prompt", "As spoken"])
    }

    @Test("a batch with no tone at all still says so, rather than leaving the line out")
    func disclosureWhenEmpty() throws {
        let batch = try F.simpleBatch()
        let tone = try #require(MetricsDisclosure.sections(for: batch, isPreview: true).first { $0.title == "Tone" })
        #expect(tone.lines == ["Tone used: none"])
    }
}
