import Foundation
import MurmurCore
import Testing

@testable import murmur_eval

/// The tone rubric's state and the calibration tables. No network: only the pure parts.
@Suite("Tone Jev rubric and calibration")
struct ToneJevCalibrationTests {
    @Test("the tone read never sees the requested tone; the fault request carries the tone and its rules")
    func stateShape() throws {
        let read = ToneJevRubric.readState(spoken: "a", output: "b")
        let fit = ToneJevRubric.fitState(tone: .casual, spoken: "a", output: "b")
        guard case .object(let readFields) = read, case .object(let fitFields) = fit else { Issue.record("not objects"); return }
        #expect(Set(readFields.keys) == ["spoken", "output"])
        #expect(Set(fitFields.keys) == ["requested_tone", "tone_rules", "spoken", "output"])
        #expect(ToneJevRubric.readQuestions["tone_read"]?.type == .choice)
        #expect(Set(ToneJevRubric.fitQuestions.keys) == ["tone_rule_broken", "tone_overreach"])
        #expect(ToneJevRubric.fitQuestions.values.allSatisfy { $0.type == .noul })
    }

    @Test("the three rule texts differ and each names its tone")
    func rules() {
        let texts = DictationTone.allCases.map(ToneJevRubric.rules(for:))
        #expect(Set(texts).count == 3)
        for (tone, text) in zip(DictationTone.allCases, texts) { #expect(text.hasPrefix(tone.title)) }
    }

    @Test("the tone rubric has its own version and cache keys, apart from the cleanup rubric")
    func separateFromV2() {
        let state = ToneJevRubric.readState(spoken: "a", output: "b")
        let key = ToneJevRubric.cacheKey(state: state, questions: ToneJevRubric.readQuestions)
        #expect(key.contains("tone-v1"))
        #expect(!key.contains("__v2__"))
        #expect(JevRubric.version == "v2")
        #expect(ToneJevRubric.model == JevRubric.model)
    }

    private func sample(_ id: String, _ refined: String?, _ casual: String?, _ professional: String?) -> ToneJevCalibration.Sample {
        var texts: [DictationTone: String] = [:]
        if let refined { texts[.refined] = refined }
        if let casual { texts[.casual] = casual }
        if let professional { texts[.professional] = professional }
        return .init(id: id, spoken: "um i am gonna go", texts: texts, source: .expected)
    }

    @Test("a text with the same words in every tone is acceptable as any tone and as unclear; one with other words only as itself")
    func readItems() throws {
        let items = ToneJevCalibration.readItems([
            sample("same", "I am going.", "I am going", "I am going."),
            sample("diff", "I am gonna go.", "I'm gonna go", "I am going to go."),
            sample("lone", "Hi.", nil, nil),
        ])
        #expect(items.count == 7)
        let same = try #require(items.first { $0.caseID == "same" && $0.intended == .casual })
        #expect(same.kind == .shared)
        #expect(same.acceptable == ["refined", "casual", "professional", "unclear"])
        let diff = try #require(items.first { $0.caseID == "diff" && $0.intended == .casual })
        #expect(diff.kind == .distinct)
        #expect(diff.acceptable == ["casual"])
        #expect(try #require(items.first { $0.caseID == "lone" }).kind == .single)
    }

    @Test("pairs are marked by what differs: nothing, the words, or only the layout")
    func fitItems() throws {
        let items = ToneJevCalibration.fitItems([
            sample("same", "I am going.", "I am going", "I am going."),
            sample("diff", "I am gonna go.", "I'm gonna go", "I am going to go."),
        ])
        let same = items.filter { $0.caseID == "same" }
        #expect(same.filter { $0.difference == .none }.count == 3)
        #expect(same.filter { $0.difference == .layout }.count == 4)
        #expect(same.allSatisfy { !$0.expectedBroken })
        let diff = items.filter { $0.caseID == "diff" }
        #expect(diff.count == 9)
        #expect(diff.filter(\.expectedBroken).count == 6)
        #expect(diff.filter { $0.difference == .none }.allSatisfy { $0.from == $0.requested })
    }

    @Test("words are compared without case, punctuation or the apostrophe style")
    func wordComparison() {
        #expect(ToneJevCalibration.words("I’m going, Thursday.") == ToneJevCalibration.words("i'm going thursday"))
        #expect(ToneJevCalibration.words("I am") != ToneJevCalibration.words("I'm"))
    }

    @Test("rule-made samples keep only cases whose tone outputs differ in words, and respect the limit")
    func ruleMade() throws {
        func make(_ id: String, ideal: String) throws -> ToneEvalChecks.Case {
            let json = """
            {"id":"\(id)","category":"x","tags":[],"raw":"raw","target":{"bundleID":"com.tinyspeck.slackmacgap","windowTitle":null,"expectedCategory":"workMessages"},
             "ideal":"\(ideal)","toneExpectations":{}}
            """
            return try JSONDecoder().decode(ToneEvalChecks.Case.self, from: Data(json.utf8))
        }
        let cases = [try make("a", ideal: "The build is green."), try make("b", ideal: "I am gonna go and we do not mind."),
                     try make("c", ideal: "We do not know. I am gonna ask.")]
        let all = ToneJevCalibration.ruleMadeSamples(cases, limit: 10)
        #expect(all.map(\.id) == ["rule:b", "rule:c"])
        #expect(all[0].texts[.casual]?.contains("I'm") == true)
        #expect(all[0].texts[.professional]?.contains("going to") == true)
        #expect(ToneJevCalibration.ruleMadeSamples(cases, limit: 1).count == 1)
    }

    @Test("the confusion table counts strict and acceptable reads")
    func tables() throws {
        let items = ToneJevCalibration.readItems([sample("diff", "I am gonna go.", "I'm gonna go", "I am going to go.")])
        let reads: [(item: ToneJevCalibration.ReadItem, read: ToneRead)] = items.map { item in
            (item, ToneRead(choice: item.intended == .casual ? "refined" : item.intended.rawValue, probabilities: [:]))
        }
        let table = ToneJevCalibration.readTable(reads, kind: .distinct)
        #expect(table.total == 3)
        #expect(table.strictCorrect == 2)
        #expect(table.counts[.casual]?["refined"] == 1)
        let text = ToneJevCalibration.formatReadTable(table, title: "t")
        #expect(text.contains("| casual | 1 | 0 | 0 | 0 |"))
        #expect(text.contains("|---|---:|---:|---:|---:|"))
    }

    @Test("fault summary separates own-tone false alarms, caught word mismatches and layout-only pairs")
    func faultSummary() throws {
        let items = ToneJevCalibration.fitItems([sample("diff", "I am gonna go.", "I'm gonna go", nil), sample("lay", "Go.", "Go", nil)])
        let results: [(item: ToneJevCalibration.FitItem, fit: ToneFit)] = items.map { item in
            (item, ToneFit(ruleBroken: item.difference == .words ? 0.9 : 0.1, overreach: 0.0))
        }
        let summary = ToneJevCalibration.fitSummary(results)
        #expect(summary.ownTotal == 4)
        #expect(summary.ownFlagged == 0)
        #expect(summary.wordsTotal == 2)
        #expect(summary.wordsFlagged == 2)
        #expect(summary.layoutTotal == 2)
        #expect(summary.layoutFlagged == 0)
        #expect(summary.pairs["refined->casual"] == [1, 1])
    }
}
