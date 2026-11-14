import Foundation
import MurmurCore
import Testing

@testable import murmur_eval

/// The scoring rules behind `murmur-eval tones` and the shape of the tones development set.
/// Pure text logic, so none of this needs a model.
@Suite("Tone eval checks")
struct ToneEvalChecksTests {
    typealias Checks = ToneEvalChecks

    private static var datasetURL: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Evals").appendingPathComponent(TonesRunner.defaultCases)
    }

    private func expectation(_ json: String) throws -> Checks.ToneExpectation {
        try JSONDecoder().decode(Checks.ToneExpectation.self, from: Data(json.utf8))
    }

    private func faithful(
        _ tone: DictationTone, content: [String], permitted: [String] = [], base: String, output: String
    ) throws -> Checks.Score {
        let list: (([String]) -> String) = { "[" + $0.map { "\"\($0)\"" }.joined(separator: ",") + "]" }
        let item = try expectation(
            "{\"faithfulness\":{\"contentWords\":\(list(content)),\"permittedIntroductions\":\(list(permitted))}}")
        return Checks.score(tone: tone, expectation: item, base: base, output: output)
    }

    // MARK: Exact and checks

    @Test("an exact match is reported on its own and is case- and punctuation-sensitive")
    func exactMatch() throws {
        let item = try expectation(#"{"exact":"I'm ready.","faithfulness":{"contentWords":[],"permittedIntroductions":[]}}"#)
        #expect(Checks.score(tone: .casual, expectation: item, base: "I am ready.", output: "I'm ready.").exactMatch == true)
        #expect(Checks.score(tone: .casual, expectation: item, base: "I am ready.", output: "I'm ready").exactMatch == false)
        #expect(Checks.score(tone: .casual, expectation: item, base: "I am ready.", output: "i'm ready.").exactMatch == false)
    }

    @Test("exact is nil when the case defines none")
    func exactAbsent() throws {
        let item = try expectation(#"{"faithfulness":{"contentWords":[],"permittedIntroductions":[]}}"#)
        let score = Checks.score(tone: .refined, expectation: item, base: "Ok.", output: "Ok.")
        #expect(score.exactMatch == nil)
        #expect(score.checksPassed == nil)
        #expect(!score.meetsExpectation)
    }

    @Test("checks pass or fail as a group and use the dev-message check rules")
    func checksGroup() throws {
        let item = try expectation(
            #"{"checks":{"mustContain":["want to"],"mustNotContain":["wanna"]},"faithfulness":{"contentWords":[],"permittedIntroductions":[]}}"#)
        let good = Checks.score(tone: .professional, expectation: item, base: "I wanna go.", output: "I want to go.")
        #expect(good.checksPassed == true)
        #expect(good.meetsExpectation)
        let bad = Checks.score(tone: .professional, expectation: item, base: "I wanna go.", output: "I wanna go.")
        #expect(bad.checksPassed == false)
        #expect(!bad.meetsExpectation)
        #expect(bad.failedChecks.count == 2)
    }

    @Test("an exact match alone, or passing checks alone, meets the expectation")
    func eitherMeetsExpectation() throws {
        let both = try expectation(
            #"{"exact":"We are ready.","checks":{"mustContain":["are ready"]},"faithfulness":{"contentWords":[],"permittedIntroductions":[]}}"#)
        let byExact = Checks.score(tone: .professional, expectation: both, base: "x", output: "We are ready.")
        #expect(byExact.meetsExpectation)
        let byChecks = Checks.score(tone: .professional, expectation: both, base: "x", output: "Yes, we are ready.")
        #expect(byChecks.exactMatch == false)
        #expect(byChecks.checksPassed == true)
        #expect(byChecks.meetsExpectation)
        let neither = Checks.score(tone: .professional, expectation: both, base: "x", output: "Ready.")
        #expect(!neither.meetsExpectation)
    }

    @Test("tone required terms are case-insensitive whole terms")
    func requiredTerms() throws {
        let item = try expectation(
            #"{"checks":{"mustContain":["send"]},"faithfulness":{"contentWords":[],"permittedIntroductions":[]}}"#)
        #expect(Checks.score(tone: .refined, expectation: item, base: "send", output: "Send it.").checksPassed == true)
        #expect(Checks.score(tone: .refined, expectation: item, base: "send", output: "Resend it.").checksPassed == false)
    }

    @Test("required alternatives accept one whole term and forbidden alternatives reject either")
    func termAlternatives() throws {
        let item = try expectation(
            #"{"mustContainOneOf":[["13","thirteen"]],"mustNotContainOneOf":[["12","twelve"]],"faithfulness":{"contentWords":[],"contentWordsOneOf":[["13","thirteen"]],"permittedIntroductions":[]}}"#)
        let good = Checks.score(tone: .refined, expectation: item, base: "thirteen", output: "13 samples.")
        #expect(good.checksPassed == true)
        #expect(good.missingContent.isEmpty)
        let wrong = Checks.score(tone: .refined, expectation: item, base: "thirteen", output: "12 and thirteen samples.")
        #expect(wrong.checksPassed == false)
        #expect(!wrong.meetsExpectation)
        let embedded = Checks.score(tone: .refined, expectation: item, base: "thirteen", output: "112 samples.")
        #expect(embedded.checksPassed == false)
    }

    @Test("accepted exact strings preserve the preferred exact metric")
    func acceptedExact() throws {
        let item = try expectation(
            #"{"exact":"I am ready.","acceptedExact":["I'm ready.","I am ready"],"faithfulness":{"contentWords":[],"permittedIntroductions":[]}}"#)
        #expect(Checks.score(tone: .casual, expectation: item, base: "I am ready", output: "I'm ready.").exactMatch == true)
        #expect(Checks.score(tone: .casual, expectation: item, base: "I am ready", output: "I am ready").exactMatch == true)
        #expect(Checks.score(tone: .casual, expectation: item, base: "I am ready", output: "I'm ready").exactMatch == false)
    }

    @Test("an exact match cannot hide a forbidden term")
    func forbiddenOverridesExact() throws {
        let item = try expectation(
            #"{"exact":"Keep twelve.","checks":{"mustNotContain":["twelve"]},"faithfulness":{"contentWords":[],"permittedIntroductions":[]}}"#)
        let score = Checks.score(tone: .refined, expectation: item, base: "Keep twelve.", output: "Keep twelve.")
        #expect(score.exactMatch == true)
        #expect(score.checksPassed == false)
        #expect(!score.meetsExpectation)
    }

    @Test("email greeting needs its own line and a blank line before the body")
    func greetingLayout() throws {
        let item = try expectation(
            #"{"greetingBodySeparated":true,"faithfulness":{"contentWords":[],"permittedIntroductions":[]}}"#)
        #expect(Checks.score(tone: .casual, expectation: item, base: "hi", output: "Hi Ana,\n\nThe patch is ready.").checksPassed == true)
        #expect(Checks.score(tone: .casual, expectation: item, base: "hi", output: "Hi Ana, the patch is ready.").checksPassed == false)
    }

    @Test("a spoken email closing stays in its own paragraph")
    func closingLayout() throws {
        let item = try expectation(
            #"{"closingOnOwnLine":"Regards","faithfulness":{"contentWords":[],"permittedIntroductions":[]}}"#)
        #expect(Checks.score(tone: .casual, expectation: item, base: "regards", output: "Hi Ana,\n\nReady.\n\nRegards").checksPassed == true)
        #expect(Checks.score(tone: .casual, expectation: item, base: "regards", output: "Hi Ana,\n\nReady. Regards").checksPassed == false)
    }

    // MARK: Faithfulness

    @Test("every content word must survive, multi-word phrases included, ignoring case")
    func contentWords() throws {
        let kept = try faithful(.refined, content: ["Nerys", "signs off"], base: "Wait until nerys signs off.", output: "Wait until Nerys signs off.")
        #expect(kept.missingContent.isEmpty)
        #expect(kept.faithful)
        let lost = try faithful(.refined, content: ["Nerys", "signs off"], base: "Wait until nerys signs off.", output: "Wait until Nerys.")
        #expect(lost.missingContent == ["signs off"])
        #expect(!lost.faithful)
    }

    @Test("an unspoken word that is not permitted fails faithfulness")
    func unpermittedIntroduction() throws {
        let score = try faithful(.refined, content: [], base: "I am gonna go.", output: "I am going to go.")
        #expect(score.unexpectedIntroductions == ["going", "to"])
        #expect(!score.faithful)
    }

    @Test("permitted introductions are allowed, and only for the words listed")
    func permittedIntroduction() throws {
        let score = try faithful(
            .refined, content: [], permitted: ["going", "to"], base: "I am gonna go.", output: "I am going to go.")
        #expect(score.faithful)
        let extra = try faithful(
            .refined, content: [], permitted: ["going"], base: "I am gonna go.", output: "I am going to go.")
        #expect(extra.unexpectedIntroductions == ["to"])
    }

    @Test("the tone's own closed set of words is always allowed")
    func closedSetAllowed() throws {
        let professional = try faithful(.professional, content: [], base: "I'm sure we can't.", output: "I am sure we cannot.")
        #expect(professional.faithful)
        let casual = try faithful(.casual, content: [], base: "I am sure we are not.", output: "I'm sure we aren't.")
        #expect(casual.faithful)
        // The same rewrite is an unspoken-word failure for Refined, which has no closed set.
        let refined = try faithful(.refined, content: [], base: "I'm sure we can't.", output: "I am sure we cannot.")
        #expect(!refined.faithful)
    }

    @Test("words recombined from spoken text are not introductions, and removing words is not one either")
    func recombinationAndRemoval() throws {
        let score = try faithful(.casual, content: [], base: "Is it um fine to go?", output: "Is it fine to go?")
        #expect(score.unexpectedIntroductions.isEmpty)
    }

    // MARK: Aggregation

    @Test("the split into contested and non-contested cases adds up to the total")
    func splitAddsUp() throws {
        let item = try expectation(#"{"exact":"Go.","faithfulness":{"contentWords":[],"permittedIntroductions":[]}}"#)
        func record(_ id: String, contested: Bool, output: String) -> Checks.Record {
            Checks.Record(
                id: id, tone: .refined, contested: contested,
                score: Checks.score(tone: .refined, expectation: item, base: "go", output: output))
        }
        let records = [
            record("a", contested: true, output: "Go."), record("b", contested: true, output: "Stop."),
            record("c", contested: false, output: "Go."), record("d", contested: false, output: "Go."),
        ]
        let breakdown = Checks.breakdown(records, tone: .refined)
        #expect(breakdown.all.total == 4)
        #expect(breakdown.all.meetsExpectation == 3)
        #expect(breakdown.contested.total == 2)
        #expect(breakdown.contested.meetsExpectation == 1)
        #expect(breakdown.uncontested.total == 2)
        #expect(breakdown.uncontested.meetsExpectation == 2)
        #expect(breakdown.all.exact == 3)
        #expect(breakdown.all.faithful == 3)  // "Stop." introduces an unspoken word
        let other = Checks.breakdown(records, tone: .casual)
        #expect(other.all.total == 0)
    }

    // MARK: The development set itself

    @Test("the development set loads, has unique ids and covers all three tones in every case", .enabled(if: PrivateFiles.present("Evals/tones-dev.json"), "needs a private file: Evals/tones-dev.json"))
    func datasetShape() throws {
        let set = try TonesRunner.loadCases(Self.datasetURL)
        #expect(set.format == "hushy.tones/v2")
        #expect(set.cases.count == 30)
        #expect(set.cases.filter { $0.contested == true }.count == 14)
        for item in set.cases {
            #expect(Set(item.toneExpectations.keys) == Set(DictationTone.allCases.map(\.rawValue)), "\(item.id)")
            for tone in DictationTone.allCases {
                #expect(item.toneExpectations[tone.rawValue]?.exact != nil || item.toneExpectations[tone.rawValue]?.checks != nil, "\(item.id) \(tone)")
            }
        }
    }

    @Test("a v1 case set still decodes and loads", .enabled(if: PrivateFiles.present("Evals/tones-dev.json"), "needs a private file: Evals/tones-dev.json"))
    func v1Decoding() throws {
        let data = try Data(contentsOf: Self.datasetURL)
        var object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        object["format"] = "hushy.tones/v1"
        var cases = try #require(object["cases"] as? [[String: Any]])
        for index in cases.indices {
            cases[index].removeValue(forKey: "pendingFounderRuling")
            var tones = try #require(cases[index]["toneExpectations"] as? [String: [String: Any]])
            for tone in Array(tones.keys) {
                tones[tone]?.removeValue(forKey: "acceptedExact")
                tones[tone]?.removeValue(forKey: "mustContainOneOf")
                tones[tone]?.removeValue(forKey: "mustNotContainOneOf")
                tones[tone]?.removeValue(forKey: "greetingBodySeparated")
                tones[tone]?.removeValue(forKey: "closingOnOwnLine")
                var faith = try #require(tones[tone]?["faithfulness"] as? [String: Any])
                faith.removeValue(forKey: "contentWordsOneOf")
                tones[tone]?["faithfulness"] = faith
            }
            cases[index]["toneExpectations"] = tones
        }
        object["cases"] = cases
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".json")
        defer { try? FileManager.default.removeItem(at: url) }
        try JSONSerialization.data(withJSONObject: object).write(to: url)
        #expect(try TonesRunner.loadCases(url).cases.count == 30)
    }
}
