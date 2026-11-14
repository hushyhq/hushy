import Foundation
import MurmurCore
import Testing

@testable import murmur_eval

/// Two guards on the tone eval: an empty check can never pass a case, and the remote judge only ever
/// reads the tone dev sets that ship in `Evals/`.
@Suite("Tone eval guards")
struct ToneEvalGuardsTests {
    private func expectation(_ json: String) throws -> ToneEvalChecks.ToneExpectation {
        try JSONDecoder().decode(ToneEvalChecks.ToneExpectation.self, from: Data(json.utf8))
    }

    private static let faith = #""faithfulness":{"contentWords":[],"permittedIntroductions":[]}"#

    // MARK: Vacuous checks

    @Test("an empty checks object, or empty lists, passes nothing and counts as no check")
    func emptyChecksAreNotAPass() throws {
        for json in ["{\"checks\":{},\(Self.faith)}",
                     "{\"checks\":{\"mustContain\":[],\"mustNotContain\":[]},\(Self.faith)}",
                     "{\"mustContainOneOf\":[],\(Self.faith)}",
                     "{\"checks\":{\"unchanged\":false},\(Self.faith)}",
                     "{\"checks\":{\"startsWithCapital\":false,\"endsWithTerminalPunctuation\":false},\(Self.faith)}",
                     "{\"mustNotContainOneOf\":[],\(Self.faith)}", "{\"greetingBodySeparated\":false,\(Self.faith)}",
                     "{\"exact\":\"\",\(Self.faith)}"] {
            let item = try expectation(json)
            #expect(!item.hasEffectiveCheck, "\(json)")
            let score = ToneEvalChecks.score(tone: .refined, expectation: item, base: "Ok.", output: "Anything at all.")
            #expect(score.checksPassed == nil, "\(json)")
            #expect(!score.meetsExpectation, "\(json)")
        }
    }

    @Test("empty terms and empty groups are refused when the file is read, and they never count as a check")
    func emptyTermsAreWritingProblems() throws {
        for json in ["{\"mustNotContainOneOf\":[[]],\(Self.faith)}", "{\"mustContainOneOf\":[[]],\(Self.faith)}",
                     "{\"checks\":{\"mustNotContain\":[\"\"]},\(Self.faith)}",
                     "{\"checks\":{\"mustContain\":[\"\"]},\(Self.faith)}",
                     "{\"checks\":{\"mustContainOneOf\":[[\"a\",\"\"]]},\(Self.faith)}",
                     "{\"mustNotContainOneOf\":[[\"\"]],\(Self.faith)}", "{\"closingOnOwnLine\":\"\",\(Self.faith)}",
                     "{\"exact\":\"\",\(Self.faith)}"] {
            #expect(try expectation(json).writingProblem != nil, "\(json)")
        }
        #expect(try expectation("{\"exact\":\"Ok.\",\"mustNotContainOneOf\":[[\"gonna\"]],\(Self.faith)}").writingProblem == nil)
    }

    @Test("an exact string or one real check is an effective check")
    func effectiveChecks() throws {
        for json in ["{\"exact\":\"Ok.\",\(Self.faith)}",
                     "{\"checks\":{\"mustContain\":[\"Ok\"]},\(Self.faith)}",
                     "{\"checks\":{\"startsWithCapital\":true},\(Self.faith)}",
                     "{\"mustNotContainOneOf\":[[\"gonna\"]],\(Self.faith)}",
                     "{\"greetingBodySeparated\":true,\(Self.faith)}"] {
            #expect(try expectation(json).hasEffectiveCheck, "\(json)")
        }
    }

    @Test("a case file with a tone that has no effective check is an error, not a pass")
    func caseFileWithNoCheckIsRefused() throws {
        func file(tone: String) -> String {
            let good = "{\"exact\":\"Ok.\",\(Self.faith)}"
            let expectations = ["refined", "casual", "professional"]
                .map { "\"\($0)\":\($0 == "casual" ? tone : good)" }.joined(separator: ",")
            return """
            {"format":"hushy.tones/v2","name":"t","split":"dev","cases":[{"id":"c1","category":"x","tags":[],"raw":"ok",
            "target":{"bundleID":"com.apple.mail","windowTitle":"","expectedCategory":"email"},"ideal":"Ok.",
            "toneExpectations":{\(expectations)}}]}
            """
        }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("tone-guards-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        for (index, tone) in ["{\"checks\":{},\(Self.faith)}", "{\"checks\":{\"startsWithCapital\":false},\(Self.faith)}",
                              "{\"mustNotContainOneOf\":[[]],\(Self.faith)}",
                              "{\"checks\":{\"mustNotContain\":[\"\"]},\(Self.faith)}"].enumerated() {
            let bad = folder.appendingPathComponent("bad\(index).json")
            try Data(file(tone: tone).utf8).write(to: bad)
            #expect(throws: (any Error).self, "\(tone)") { try TonesRunner.loadCases(bad) }
        }
        let good = folder.appendingPathComponent("good.json")
        try Data(file(tone: "{\"exact\":\"Ok.\",\(Self.faith)}").utf8).write(to: good)
        #expect(try TonesRunner.loadCases(good).cases.count == 1)
    }

    @Test("every case in the shipped dev sets has an effective check for every tone", .enabled(if: PrivateFiles.present("Evals/tones-dev.json", "Evals/tones-dev-long.json"), "needs a private file: Evals/tones-dev.json, Evals/tones-dev-long.json"))
    func shippedSetsAreNotVacuous() throws {
        let evals = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Evals")
        for name in ToneJevSets.shipped.sorted() {
            let set = try TonesRunner.loadCases(evals.appendingPathComponent(name))
            for item in set.cases {
                for tone in DictationTone.allCases {
                    #expect(item.toneExpectations[tone.rawValue]?.hasEffectiveCheck == true, "\(name) \(item.id) \(tone)")
                }
            }
        }
    }

    // MARK: The judge only reads shipped sets

    private func evalsFolder() throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("tone-evals-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    @Test("a shipped tone dev set in Evals/ is accepted")
    func shippedAccepted() throws {
        let folder = try evalsFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        for name in ["tones-dev.json", "tones-dev-long.json"] {
            let url = folder.appendingPathComponent(name)
            #expect(ToneJevSets.isShipped(url, evalsFolder: folder))
            try ToneJevSets.requireShipped(url, evalsFolder: folder)
        }
    }

    @Test("any other file is refused with a clear message: another name, another folder, a link elsewhere")
    func othersRefused() throws {
        let folder = try evalsFolder()
        let elsewhere = try evalsFolder()
        defer { try? FileManager.default.removeItem(at: folder); try? FileManager.default.removeItem(at: elsewhere) }
        let custom = folder.appendingPathComponent("my-private-notes.json")
        let sameNameElsewhere = elsewhere.appendingPathComponent("tones-dev.json")
        let link = folder.appendingPathComponent("tones-dev-long.json")
        try Data("{}".utf8).write(to: elsewhere.appendingPathComponent("other.json"))
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: elsewhere.appendingPathComponent("other.json"))
        for url in [custom, sameNameElsewhere, link, folder.appendingPathComponent("tones-dev.json.bak"),
                    folder.appendingPathComponent("../tones-dev.json")] {
            #expect(!ToneJevSets.isShipped(url, evalsFolder: folder), "\(url.path)")
        }
        do {
            try ToneJevSets.requireShipped(custom, evalsFolder: folder)
            Issue.record("a custom file was accepted")
        } catch {
            let message = "\(error)"
            #expect(message.contains("only reads the tone dev sets that ship in Evals/"))
            #expect(message.contains("my-private-notes.json"))
        }
    }

    @Test("a folder pointed to by MURMUR_EVAL_HOME, or a same-named file anywhere else, is refused; the repository's own set is not", .enabled(if: PrivateFiles.present("Evals/tones-dev.json", "Evals/tones-dev-long.json"), "needs a private file: Evals/tones-dev.json, Evals/tones-dev-long.json"))
    func environmentCannotRedirectTheAllowlist() throws {
        let folder = try evalsFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let impostor = folder.appendingPathComponent("tones-dev.json")
        try Data("{}".utf8).write(to: impostor)
        let previous = ProcessInfo.processInfo.environment["MURMUR_EVAL_HOME"]
        setenv("MURMUR_EVAL_HOME", folder.path, 1)
        defer { if let previous { setenv("MURMUR_EVAL_HOME", previous, 1) } else { unsetenv("MURMUR_EVAL_HOME") } }
        // The environment now makes the eval tool's own root this folder ...
        #expect(Paths.root.resolvingSymlinksInPath().path == folder.resolvingSymlinksInPath().path)
        // ... and the judge still refuses it, with the usual message.
        #expect(!ToneJevSets.isShipped(impostor))
        do {
            try ToneJevSets.requireShipped(impostor)
            Issue.record("a same-named file in an environment-pointed folder was accepted")
        } catch {
            #expect("\(error)".contains("only reads the tone dev sets that ship in Evals/"))
        }
        // The real set, in this repository's Evals/, is accepted whatever the environment says.
        for name in ToneJevSets.shipped { #expect(ToneJevSets.isShipped(ToneJevSets.repositoryEvals.appendingPathComponent(name)), "\(name)") }
    }

    @Test("the dev sets that ship in the repo are exactly the ones the judge accepts", .enabled(if: PrivateFiles.present("Evals/tones-dev.json", "Evals/tones-dev-long.json"), "needs a private file: Evals/tones-dev.json, Evals/tones-dev-long.json"))
    func shippedNamesMatchTheRepo() {
        let evals = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Evals")
        for name in ToneJevSets.shipped {
            #expect(FileManager.default.fileExists(atPath: evals.appendingPathComponent(name).path), "\(name)")
            #expect(ToneJevSets.isShipped(evals.appendingPathComponent(name), evalsFolder: evals), "\(name)")
            #expect(evals.resolvingSymlinksInPath().path == ToneJevSets.repositoryEvals.resolvingSymlinksInPath().path)
        }
    }
}
