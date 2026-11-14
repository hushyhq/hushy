import Foundation
import MurmurCore
import Testing

@testable import murmur_eval

/// The scoring rules behind `murmur-eval dev-messages` and the shape of the development set.
@Suite("Developer messages checks")
struct DevMessageChecksTests {
    typealias Checks = DevMessageChecks

    private static var datasetURL: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Evals").appendingPathComponent(DevMessagesRunner.defaultCases)
    }

    private func expectations(_ json: String) throws -> Checks.Expectations {
        try JSONDecoder().decode(Checks.Expectations.self, from: Data(json.utf8))
    }

    private func outcomes(_ json: String, raw: String = "x", output: String) throws -> [Checks.Outcome] {
        Checks.evaluate(try expectations(json), raw: raw, output: output)
    }

    private func allPass(_ list: [Checks.Outcome]) -> Bool { list.allSatisfy { $0.passed } }
    private func anyFail(_ list: [Checks.Outcome]) -> Bool { list.contains { !$0.passed } }

    // MARK: Text helpers

    @Test("word delta counts a multiset difference and ignores punctuation and case")
    func wordDelta() {
        let delta = Checks.wordDelta(raw: "um so the the auth service is down", output: "So the auth service is down.")
        #expect(delta.added == 0)
        #expect(delta.removed == 2)
        let reworded = Checks.wordDelta(raw: "re run it", output: "Re-run it please")
        #expect(reworded.added == 1)
        #expect(reworded.removed == 0)
    }

    @Test("forbidden terms match whole words, not substrings")
    func containsTermBoundaries() {
        #expect(Checks.containsTerm("um, okay", "um"))
        #expect(!Checks.containsTerm("the umbrella forum", "um"))
        #expect(Checks.containsTerm("Hey there", "hey"))
        #expect(Checks.containsTerm("see you ASAP.", "asap"))
        #expect(!Checks.containsTerm("", "um"))
    }

    @Test("capital check skips leading punctuation and accepts digits")
    func capital() {
        #expect(Checks.startsWithCapital("Fixed it"))
        #expect(!Checks.startsWithCapital("fixed it"))
        #expect(Checks.startsWithCapital("\"Fixed\" it"))
        #expect(Checks.startsWithCapital("3 tests failed"))
        #expect(!Checks.startsWithCapital("..."))
    }

    @Test("terminal punctuation ignores closing quotes and brackets")
    func terminal() {
        #expect(Checks.endsWithTerminalPunctuation("Done."))
        #expect(Checks.endsWithTerminalPunctuation("Done (really.)"))
        #expect(Checks.endsWithTerminalPunctuation("He said \"go!\""))
        #expect(!Checks.endsWithTerminalPunctuation("Done"))
        #expect(!Checks.endsWithTerminalPunctuation("Done,"))
        #expect(!Checks.endsWithTerminalPunctuation(""))
    }

    @Test("line counting ignores blank lines")
    func lines() {
        #expect(Checks.nonEmptyLineCount("Hi Priya,\n\nBody.\n\nThanks,\nSam") == 4)
        #expect(Checks.nonEmptyLineCount("one line") == 1)
    }

    // MARK: Evaluation

    @Test("literals are case-sensitive and one-of groups need one member")
    func literals() throws {
        let json = #"{"mustContain":["OAuth"],"mustContainOneOf":[["auth-service","auth service"]]}"#
        let result = try outcomes(json, output: "The OAuth auth-service is down.")
        #expect(allPass(result))
        let wrong = try outcomes(json, output: "The oauth thing is down.")
        #expect(wrong.count == 2)
        #expect(!allPass(wrong))
        #expect(wrong.map(\.kind).allSatisfy { $0 == .literal })
    }

    @Test("forbidden strings fail when present")
    func forbidden() throws {
        let json = #"{"mustNotContain":["gonna"]}"#
        let result = try outcomes(json, output: "I am going to fix it.")
        #expect(allPass(result))
        let hit = try outcomes(json, output: "I'm Gonna fix it.")
        #expect(anyFail(hit))
        #expect(hit[0].kind == .forbidden)
    }

    @Test("word bounds produce one outcome each and fail past the limit")
    func wordBounds() throws {
        let json = #"{"maxWordsAdded":1,"maxWordsRemoved":2}"#
        let ok = try outcomes(json, raw: "um we ship it", output: "We ship it now.")
        #expect(ok.count == 2)
        #expect(allPass(ok))
        let bad = try outcomes(json, raw: "we ship it", output: "We will ship it to production today.")
        #expect(bad.first { $0.label == "added" }?.passed == false)
    }

    @Test("unchanged compares whitespace-collapsed text exactly")
    func unchanged() throws {
        let json = #"{"unchanged":true}"#
        let result = try outcomes(json, raw: "Looks good to me.", output: "Looks  good to me.\n")
        #expect(allPass(result))
        let changed = try outcomes(json, raw: "Looks good to me.", output: "Looks good to me")
        #expect(anyFail(changed))
    }

    @Test("layout needs the minimum number of non-empty lines and counts as a format check")
    func layout() throws {
        let json = #"{"minLines":3}"#
        let flat = try outcomes(json, output: "Hi Priya, thanks, Sam")
        #expect(flat.count == 1)
        #expect(!flat[0].passed)
        #expect(flat[0].kind.isFormat)
        let result = try outcomes(json, output: "Hi Priya,\nThanks\nSam")
        #expect(allPass(result))
    }

    @Test("capital and terminal outcomes are format kinds, literal and word checks are not")
    func formatKinds() {
        #expect(Checks.Kind.capital.isFormat)
        #expect(Checks.Kind.terminal.isFormat)
        #expect(!Checks.Kind.literal.isFormat)
        #expect(!Checks.Kind.wordDelta.isFormat)
        #expect(!Checks.Kind.unchanged.isFormat)
    }

    // MARK: Attribution

    private func failure(_ kind: Checks.Kind, _ label: String) -> Checks.Outcome {
        Checks.Outcome(kind: kind, label: label, passed: false, detail: "")
    }

    private func pass(_ kind: Checks.Kind, _ label: String) -> Checks.Outcome {
        Checks.Outcome(kind: kind, label: label, passed: true, detail: "")
    }

    @Test("a wrong context that changes the shape is a classification failure")
    func attributeClassification() {
        let cause = Checks.attribute(
            failed: [failure(.terminal, "terminal")], rulesOutcomes: [failure(.terminal, "terminal")],
            configMatchesExpected: false, modelRan: true)
        #expect(cause == .classification)
    }

    @Test("a wrong context does not explain a failed literal")
    func attributeIgnoresContextForWords() {
        let cause = Checks.attribute(
            failed: [failure(.literal, "literal:OAuth")], rulesOutcomes: [failure(.literal, "literal:OAuth")],
            configMatchesExpected: false, modelRan: false)
        #expect(cause == .missingFeature)
    }

    @Test("a check the rules draft passed but the final output fails is a model regression")
    func attributeModelRegression() {
        let cause = Checks.attribute(
            failed: [failure(.literal, "literal:OAuth")], rulesOutcomes: [pass(.literal, "literal:OAuth")],
            configMatchesExpected: true, modelRan: true)
        #expect(cause == .model)
    }

    @Test("a shape failure with the right context is the formatter")
    func attributeFormatter() {
        let cause = Checks.attribute(
            failed: [failure(.layout, "layout")], rulesOutcomes: [failure(.layout, "layout")],
            configMatchesExpected: true, modelRan: true)
        #expect(cause == .formatter)
    }

    @Test("an unfixed word failure is the model when it ran and a missing feature when it did not")
    func attributeModelOrMissing() {
        let failed = [failure(.literal, "literal:v2.14.3")]
        #expect(Checks.attribute(failed: failed, rulesOutcomes: failed, configMatchesExpected: true, modelRan: true) == .model)
        #expect(Checks.attribute(failed: failed, rulesOutcomes: failed, configMatchesExpected: true, modelRan: false) == .missingFeature)
    }

    // MARK: Mirrored app settings

    @Test("the mirrored settings follow the category like the app")
    func mirroredSettings() {
        let slack = DevMessagesRunner.pipelineSettings(for: .workMessages, level: .clean)
        #expect(slack.cleanupOptions.isCasualContext)
        #expect(!slack.cleanupOptions.isCodeContext)
        #expect(slack.style?.0 == StyleContext.from(.workMessages))
        let code = DevMessagesRunner.pipelineSettings(for: .code, level: .polished)
        #expect(code.cleanupOptions.isCodeContext)
        #expect(code.style == nil)
        #expect(DevMessagesRunner.config(for: .email).isCasual == false)
    }

    // MARK: The development set

    private static func loadSet() throws -> Checks.CaseSet { try DevMessagesRunner.loadCases(datasetURL) }

    @Test("the dev set loads with unique ids, all seven categories and the already-fine cases", .enabled(if: PrivateFiles.present("Evals/developer-messages-dev.json"), "needs a private file: Evals/developer-messages-dev.json"))
    func datasetShape() throws {
        let set = try Self.loadSet()
        #expect(set.cases.count >= 55)
        #expect(Set(set.cases.map(\.id)).count == set.cases.count)
        let categories = Set(set.cases.map(\.category))
        #expect(categories == [
            "slack-teammate", "slack-manager-or-team", "incident-status", "pr-review", "ticket-comment",
            "email-colleague", "email-external",
        ])
        let fine = set.cases.filter { $0.checks.unchanged == true }
        #expect(fine.count >= 6)
        for item in fine {
            #expect(item.ideal == item.raw, "\(item.id): an already-fine case must have ideal == raw")
        }
    }

    @Test("every ideal passes its own checks, so the checks are satisfiable", .enabled(if: PrivateFiles.present("Evals/developer-messages-dev.json"), "needs a private file: Evals/developer-messages-dev.json"))
    func idealsPassTheirChecks() throws {
        let set = try Self.loadSet()
        for item in set.cases {
            let failures = Checks.evaluate(item.checks, raw: item.raw, output: item.ideal).filter { !$0.passed }
            #expect(failures.isEmpty, "\(item.id): \(failures.map(\.detail).joined(separator: "; "))")
        }
    }

    @Test("every case has at least one check and a raw input that is not already the ideal, unless already fine", .enabled(if: PrivateFiles.present("Evals/developer-messages-dev.json"), "needs a private file: Evals/developer-messages-dev.json"))
    func casesAreMeaningful() throws {
        let set = try Self.loadSet()
        for item in set.cases {
            let checks = Checks.evaluate(item.checks, raw: item.raw, output: item.ideal)
            #expect(!checks.isEmpty, "\(item.id): no checks")
            if item.checks.unchanged != true {
                #expect(item.raw != item.ideal, "\(item.id): raw equals ideal but case is not marked unchanged")
            }
        }
    }

    @Test("a rejected format or split is refused")
    func loaderRejects() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("dev-msgs-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("set.json")
        try Data(#"{"format":"hushy.developer-messages/v1","name":"x","split":"heldout","cases":[]}"#.utf8).write(to: url)
        #expect(throws: (any Error).self) { try DevMessagesRunner.loadCases(url) }
    }
}
