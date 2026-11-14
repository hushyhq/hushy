import Foundation
import Testing
@testable import MurmurCore

/// The edit rate after paste: how it is worked out, counted per tone and kind of app, held until the edit
/// watcher reports, and sent. Counts only; older data still reads.
@Suite("Usage metrics: edit rate", .timeLimit(.minutes(1)))
struct MetricsEditRateTests {
    typealias F = UsageMetricsFixtures

    // MARK: vocabulary

    @Test("every kind of app in the app maps to one on the wire, and the wire names no app")
    func appKinds() {
        for category in AppCategory.allCases { #expect(MetricsAppKind(category).rawValue == category.rawValue, "\(category)") }
        #expect(MetricsAppKind.allCases.count == AppCategory.allCases.count)
    }

    @Test("verdicts: kept, edited, a field found empty, and everything else is not checked")
    func verdicts() {
        #expect(MetricsEditVerdict(observation: .kept, coverage: .observed) == .kept)
        #expect(MetricsEditVerdict(observation: .edited, coverage: .observed) == .edited)
        #expect(MetricsEditVerdict(observation: .unknown, coverage: .fieldCleared) == .fieldCleared)
        for coverage in DictationFeedback.EditCoverage.allCases where coverage != .fieldCleared && coverage != .observed {
            #expect(MetricsEditVerdict(observation: .unknown, coverage: coverage) == .unknown, "\(coverage)")
        }
    }

    @Test("edit sizes: 1 to 2 words, 3 to 10, more; an edit is never smaller than the first bucket")
    func sizes() {
        for (words, size) in [(-5, MetricsEditSize.words1to2), (0, .words1to2), (1, .words1to2), (2, .words1to2), (3, .words3to10),
                              (10, .words3to10), (11, .wordsMore), (500, .wordsMore)] {
            #expect(MetricsEditSize.forEdit(wordsChanged: words) == size, "\(words)")
        }
        #expect(MetricsEditSize.forEdit(wordsChanged: 0) != MetricsEditSize.none)
    }

    @Test("a size goes with an edit and only with an edit")
    func keyRule() throws {
        _ = try MetricsEditRateKey(tone: .casual, appKind: .email, verdict: .edited, size: .words3to10)
        for verdict in [MetricsEditVerdict.kept, .unknown, .fieldCleared] {
            _ = try MetricsEditRateKey(tone: .casual, appKind: .email, verdict: verdict, size: .none)
            #expect(throws: MetricsValidationError.inconsistentEditRate) {
                try MetricsEditRateKey(tone: .casual, appKind: .email, verdict: verdict, size: .words1to2)
            }
        }
        #expect(throws: MetricsValidationError.inconsistentEditRate) {
            try MetricsEditRateKey(tone: .casual, appKind: .email, verdict: .edited, size: .none)
        }
    }

    // MARK: counting

    private func paste(
        tone: MetricsTone?, kind: MetricsAppKind?, edit: DictationFeedback.EditObservation = .kept,
        coverage: DictationFeedback.EditCoverage? = nil, size: MetricsEditSize? = nil,
        delivery: DictationFeedback.Delivery = .succeeded
    ) -> MetricEventRecord {
        let feedback = F.feedback(delivery: delivery, edit: delivery == .succeeded ? edit : .unknown, coverage: coverage,
                                  releaseToDelivery: delivery == .succeeded ? 900 : nil)
        return F.record(.dictation(F.dictation(feedback, tone: tone, appKind: kind, editSize: size)))
    }

    private func batch(_ records: [MetricEventRecord]) throws -> DailyMetricsBatch {
        try #require(F.builder().close(records: records, environment: F.environment, now: F.noonOct4).closedBatches.first)
    }

    @Test("pasted dictations are counted per tone, kind of app, verdict and size")
    func perCell() throws {
        let rate = try #require(batch([
            paste(tone: .casual, kind: .email), paste(tone: .casual, kind: .email),
            paste(tone: .casual, kind: .email, edit: .edited, size: .words1to2),
            paste(tone: .casual, kind: .code, edit: .edited, size: .wordsMore),
            paste(tone: .professional, kind: .email, edit: .unknown, coverage: .fieldCleared),
            paste(tone: .professional, kind: .email, edit: .unknown, coverage: .fieldUnreadable),
            paste(tone: .professional, kind: .email, edit: .unknown, coverage: .notAttempted),
        ]).editRate)
        func count(_ tone: MetricsTone, _ kind: MetricsAppKind, _ verdict: MetricsEditVerdict, _ size: MetricsEditSize = .none) throws -> Int {
            rate[try MetricsEditRateKey(tone: tone, appKind: kind, verdict: verdict, size: size)]
        }
        #expect(try count(.casual, .email, .kept) == 2)
        #expect(try count(.casual, .email, .edited, .words1to2) == 1)
        #expect(try count(.casual, .code, .edited, .wordsMore) == 1)
        #expect(try count(.professional, .email, .fieldCleared) == 1)
        #expect(try count(.professional, .email, .unknown) == 2)
        #expect(rate.total == 7 && rate.total(verdict: .kept) == 2 && rate.total(verdict: .edited) == 2)
        #expect(rate.total(tone: .casual) == 4 && rate.total(tone: .casual, appKind: .email) == 3)
    }

    @Test("a dictation that was not pasted, has no tone or no kind of app, or is an edit of unknown size is left out")
    func leftOut() throws {
        let kept = paste(tone: .refined, kind: .documents)
        let rate = try #require(batch([
            kept,
            paste(tone: .refined, kind: .documents, delivery: .copied),      // copied, never pasted
            paste(tone: .refined, kind: .documents, delivery: .failed),
            paste(tone: nil, kind: .documents),                                // cleanup never ran
            paste(tone: .refined, kind: nil),                                  // recorded by an older build
            paste(tone: .refined, kind: .documents, edit: .edited, size: nil), // edited, size not measured
        ]).editRate)
        #expect(rate.total == 1 && rate.total(verdict: .kept) == 1)
    }

    @Test("a size given to a dictation that was not edited is dropped, not counted")
    func sizeOnlyOnEdits() throws {
        let event = F.dictation(F.feedback(edit: .kept), tone: .casual, appKind: .email, editSize: .wordsMore)
        #expect(event.editSize == nil)
        let rate = try #require(batch([F.record(.dictation(event))]).editRate)
        #expect(rate.total == 1 && rate.total(verdict: .kept) == 1)
    }

    @Test("a busy day split into several batches counts each dictation once, and the totals add up")
    func splitBatches() throws {
        let records = (0..<(MetricsLimits.maximumEventsPerBatch + 3)).map { _ in paste(tone: .casual, kind: .email) }
        let result = try F.builder().close(records: records, environment: F.environment, now: F.noonOct4)
        #expect(result.closedBatches.count == 2)
        let sum = result.closedBatches.compactMap(\.editRate).reduce(0) { $0 + $1.total }
        #expect(sum == records.count)
    }

    // MARK: the batch

    @Test("the table encodes as sorted rows with only closed words and a count, the same bytes every time")
    func encoding() throws {
        let rate = try #require(batch([
            paste(tone: .professional, kind: .email, edit: .edited, size: .words3to10), paste(tone: .casual, kind: .code),
            paste(tone: .casual, kind: .code), paste(tone: .casual, kind: .aiPrompts),
        ]).editRate)
        let data = try JSONEncoder().encode(rate)
        let rows = try #require(JSONSerialization.jsonObject(with: data) as? [[String: Any]])
        #expect(rows.count == 3)
        for row in rows { #expect(Set(row.keys) == ["tone", "appKind", "verdict", "size", "count"]) }
        #expect(rows.map { $0["tone"] as? String } == ["casual", "casual", "professional"])
        #expect(rows.map { $0["appKind"] as? String } == ["aiPrompts", "code", "email"])
        #expect(rows[1]["count"] as? Int == 2)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        #expect(try encoder.encode(rate) == encoder.encode(JSONDecoder().decode(MetricsEditRateTable.self, from: data)))
    }

    private func row(_ overrides: [String: Any] = [:]) -> [String: Any] {
        ["tone": "casual", "appKind": "email", "verdict": "kept", "size": "none", "count": 1].merging(overrides) { $1 }
    }

    private func decodes(_ rows: [[String: Any]]) -> Bool {
        guard let data = try? JSONSerialization.data(withJSONObject: rows) else { return false }
        return (try? JSONDecoder().decode(MetricsEditRateTable.self, from: data)) != nil
    }

    @Test("decoding is strict: unknown words, extra keys, bad counts, a size that does not fit, duplicates")
    func strictDecoding() throws {
        #expect(decodes([row()]))
        #expect(decodes([]))
        #expect(!decodes([row(["tone": "friendly"])]))
        #expect(!decodes([row(["appKind": "com.apple.mail"])]))
        #expect(!decodes([row(["verdict": "deleted"])]))
        #expect(!decodes([row(["size": "words11"])]))
        #expect(!decodes([row(["count": 0])]))
        #expect(!decodes([row(["count": -1])]))
        #expect(!decodes([row(["count": MetricsLimits.maximumCount + 1])]))
        #expect(!decodes([row(["count": 1.5])]))
        #expect(!decodes([row(["app": "Mail"])]))                                   // an extra key
        #expect(!decodes([row(["verdict": "kept", "size": "words1to2"])]))          // a size on a dictation that was not edited
        #expect(!decodes([row(["verdict": "edited", "size": "none"])]))             // an edit with no size
        #expect(!decodes([row(), row()]))                                           // a cell twice
        var missing = row(); missing["count"] = nil
        #expect(!decodes([missing]))
    }

    @Test("a batch built now is version 4, a version 3 batch reads without it and re-encodes to the same bytes")
    func versions() throws {
        let current = try batch([paste(tone: .casual, kind: .email)])
        #expect(current.schemaVersion == 4 && current.editRate != nil)
        var object = try #require(JSONSerialization.jsonObject(with: current.encodedBody()) as? [String: Any])
        object["schemaVersion"] = 3
        object["editRate"] = nil
        let stored = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes])
        let decoded = try JSONDecoder().decode(DailyMetricsBatch.self, from: stored)
        #expect(decoded.schemaVersion == 3 && decoded.editRate == nil)
        #expect(try decoded.encodedBody() == stored)
    }

    @Test("version and the edit rate must agree")
    func versionAgreement() throws {
        let base = try #require(JSONSerialization.jsonObject(with: batch([paste(tone: .casual, kind: .email)]).encodedBody()) as? [String: Any])
        func rejected(_ mutate: (inout [String: Any]) -> Void) -> Bool {
            var object = base
            mutate(&object)
            guard let data = try? JSONSerialization.data(withJSONObject: object) else { return false }
            return (try? JSONDecoder().decode(DailyMetricsBatch.self, from: data)) == nil
        }
        #expect(rejected { $0["editRate"] = nil })                    // version 4 needs it
        #expect(rejected { $0["schemaVersion"] = 3 })                 // version 3 must not carry it
        #expect(rejected { $0["editRate"] = [["tone": "casual"]] })
    }

    @Test("rows that claim more than the batch's dictations is refused, building or decoding")
    func consistency() throws {
        var rate = MetricsEditRateTable()
        let key = try MetricsEditRateKey(tone: .casual, appKind: .email, verdict: .edited, size: .words1to2)
        rate.increment(key)
        // One dictation, kept: an edited row has no dictation behind it.
        var totals = DictationMetricTotals()
        totals.record(F.dictation(F.feedback(edit: .kept), tone: .casual, appKind: .email))
        var tones = MetricsCountTable<MetricsTone>()
        tones.increment(.casual)
        #expect(throws: MetricsValidationError.inconsistentEditRate) {
            try DailyMetricsBatch(
                batchID: UUID(), day: MetricsDay(year: 2026, month: 10, day: 3), appBuild: 1, environment: F.environment,
                dictationsByProfile: [.localFineTuned: totals], voiceActions: VoiceActionTotals(), meetings: MeetingTotals(),
                funnel: MetricsCountTable(), retention: MetricsRetention(daysSinceFirstRun: .day0, activeDaysLast7: 1), tones: tones,
                editRate: rate)
        }
        // A tone nobody ran with.
        var other = MetricsEditRateTable()
        other.increment(try MetricsEditRateKey(tone: .prompt, appKind: .email, verdict: .kept, size: .none))
        #expect(throws: MetricsValidationError.inconsistentEditRate) {
            try DailyMetricsBatch(
                batchID: UUID(), day: MetricsDay(year: 2026, month: 10, day: 3), appBuild: 1, environment: F.environment,
                dictationsByProfile: [.localFineTuned: totals], voiceActions: VoiceActionTotals(), meetings: MeetingTotals(),
                funnel: MetricsCountTable(), retention: MetricsRetention(daysSinceFirstRun: .day0, activeDaysLast7: 1), tones: tones,
                editRate: other)
        }
        // And the same lie told in bytes.
        var object = try #require(JSONSerialization.jsonObject(with: batch([paste(tone: .casual, kind: .email)]).encodedBody()) as? [String: Any])
        object["editRate"] = [row(["count": 5])]
        let bytes = try JSONSerialization.data(withJSONObject: object)
        #expect((try? JSONDecoder().decode(DailyMetricsBatch.self, from: bytes)) == nil)
    }

    @Test("the fully populated batch carries every kind of app, verdict and size, and stays small")
    func populated() throws {
        let populated = try F.fullyPopulatedBatch()
        let rate = try #require(populated.editRate)
        #expect(Set(rate.counts.keys.map(\.appKind)) == Set(MetricsAppKind.allCases))
        #expect(Set(rate.counts.keys.map(\.verdict)) == Set(MetricsEditVerdict.allCases))
        #expect(Set(rate.counts.keys.map(\.size)) == Set(MetricsEditSize.allCases))
        #expect(try populated.encodedBody().count < MetricsLimits.maximumEncodedBatchBytes)
    }

    @Test("every possible cell at the most the app can count still fits the planned ingest size")
    func worstCaseSize() throws {
        var rate = MetricsEditRateTable()
        for tone in MetricsTone.allCases { for kind in MetricsAppKind.allCases { for verdict in MetricsEditVerdict.allCases {
            for size in MetricsEditSize.allCases {
                guard let key = try? MetricsEditRateKey(tone: tone, appKind: kind, verdict: verdict, size: size) else { continue }
                for _ in 0..<2 { rate.increment(key) }
            }
        } } }
        #expect(rate.counts.count == MetricsEditRateTable.maximumRows)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        #expect(try encoder.encode(rate).count < 24 * 1024)
    }

    // MARK: waiting for the verdict

    @Test("a held dictation is released with the edit's size, and a verdict on another day or a repeat adds none")
    func pending() throws {
        var held = PendingDictationMetrics(calendar: F.utc)
        let input = DictationMetricInput(
            result: .pasted, modelOutcome: .used, backend: .apple, cleanupLevel: .clean, mode: nil, wordCount: 10, audioSeconds: 2,
            speechMilliseconds: 100, cleanupMilliseconds: 200, releaseToDeliveryMilliseconds: 500, tone: .casual, appKind: .email)
        let id = held.hold(input, at: F.noonOct3)
        let first = held.resolve(id, observation: .edited, coverage: .observed, size: .words3to10, at: F.noonOct3.addingTimeInterval(9))
        let released = try #require(first)
        #expect(released.event.editSize == .words3to10 && released.event.appKind == .email && released.event.tone == .casual)
        let repeated = held.resolve(id, observation: .kept, coverage: .observed, at: F.noonOct3)
        #expect(repeated == nil)

        let late = held.hold(input, at: F.noonOct3)
        let rolled = held.resolve(late, observation: .edited, coverage: .observed, size: .wordsMore, at: F.noonOct4)
        let nextDay = try #require(rolled)
        #expect(nextDay.event.editSize == nil && nextDay.event.feedback.editObservation == .unknown)

        _ = held.hold(input, at: F.noonOct3)
        let expired = held.expire(at: F.noonOct3.addingTimeInterval(PendingDictationMetrics.window + 1))
        #expect(expired.count == 1 && expired[0].event.editSize == nil && expired[0].event.appKind == .email)
    }

    @Test("the edit watcher's verdict keeps the kind of app, and a size comes only with an edit")
    func inputKeepsKind() throws {
        let input = DictationMetricInput(
            result: .pasted, modelOutcome: .used, backend: .apple, cleanupLevel: .clean, mode: nil, wordCount: 10, audioSeconds: 2,
            speechMilliseconds: 100, cleanupMilliseconds: 200, releaseToDeliveryMilliseconds: 500, tone: .professional, appKind: .code)
        #expect(try input.event().appKind == .code)
        let edited = try input.withEdit(observation: .edited, coverage: .observed, size: .words1to2).event()
        #expect(edited.appKind == .code && edited.editSize == .words1to2 && edited.tone == .professional)
        let kept = try input.withEdit(observation: .kept, coverage: .observed, size: .words1to2).event()
        #expect(kept.editSize == nil)
    }

    @Test("a journal line written before the edit rate existed still reads, with no kind of app and no size")
    func oldJournalLine() throws {
        let record = F.record(.dictation(F.dictation(tone: .casual, appKind: .email)))
        var object = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(record)) as? [String: Any])
        func strip(_ any: Any) -> Any {
            if var dict = any as? [String: Any] { dict["appKind"] = nil; dict["editSize"] = nil; return dict.mapValues(strip) }
            return any
        }
        object = try #require(strip(object) as? [String: Any])
        let decoded = try JSONDecoder().decode(MetricEventRecord.self, from: JSONSerialization.data(withJSONObject: object))
        guard case .dictation(let event) = decoded.event else { Issue.record("not a dictation"); return }
        #expect(event.appKind == nil && event.editSize == nil && event.tone == .casual)
        guard case .dictation(let kept) = record.event.normalized else { Issue.record("not a dictation"); return }
        #expect(kept.appKind == .email)
    }

    // MARK: what the person is shown

    @Test("the sheet's example is a real row, and says only counts")
    func example() throws {
        let data = Data("[\(EditRateDisclosure.exampleRow)]".utf8)
        let table = try JSONDecoder().decode(MetricsEditRateTable.self, from: data)
        #expect(table.total == 4)
        let key = try MetricsEditRateKey(tone: .professional, appKind: .email, verdict: .edited, size: .words1to2)
        #expect(table[key] == 4)
        #expect(EditRateDisclosure.summary.contains("\(Int(LearningReadSchedule.verdictOffset)) seconds"))
        #expect(EditRateDisclosure.summary.contains("only a count"))
        #expect(EditRateDisclosure.exampleMeaning.contains("never says which app"))
    }

    @Test("the summary bullets name the kind of app and the edit, in under a hundred characters")
    func bullets() {
        #expect(MetricsDisclosure.SummaryBullet.counts.text.contains("kind of app"))
        #expect(MetricsDisclosure.SummaryBullet.outcomes.text.contains("edited"))
        for bullet in MetricsDisclosure.SummaryBullet.allCases { #expect(bullet.text.count < 100) }
    }

    @Test("an empty edit rate is still shown, as none")
    func emptyShown() throws {
        let batch = try F.simpleBatch()
        let section = try #require(MetricsDisclosure.sections(for: batch, isPreview: true).first { $0.title == MetricsDisclosure.editRateTitle })
        #expect(section.lines == ["\(MetricsDisclosure.editRateTitle): none"])
    }
}
