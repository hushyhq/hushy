import Foundation
import MurmurCore
import Testing

@testable import murmur_eval

/// The tools-v1 case format, its loader and the dev set's shape (sizes, coverage, false-fire share).
@Suite("Tool eval set loader")
struct ToolEvalSetTests {
    private static var packageRoot: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    }

    private static var devURL: URL { packageRoot.appendingPathComponent(ToolsRunner.defaultDataset) }

    private static func loadDev() throws -> ToolEvalSet {
        try ToolEvalSet.load(devURL, access: .tuning(purpose: "test"))
    }

    private func write(_ json: String, name: String = "set.json") throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("tool-eval-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent(name)
        try Data(json.utf8).write(to: url)
        return url
    }

    private static let validCase = """
        {"id":"t-1","utterance":"remind me to call the plumber tomorrow at 9",
         "context":{"now":"2026-10-05T10:15:00+05:30","timeZone":"Asia/Kolkata","locale":"en_IN","frontmostApp":"Slack"},
         "category":"relative-datetime","tags":[],
         "expect":{"decision":"call","tool":"create_reminder","args":{"title":"call the plumber","when":"2026-10-06T09:00:00+05:30"},
                   "whenSpoken":["tomorrow at 9"]}}
        """

    private func set(_ cases: String) -> String {
        #"{"format":"hushy.tool-eval/v1","catalog":"tools-v1","name":"t","split":"dev","cases":["# + cases + "]}"
    }

    @Test("the dev set loads, validates and has about 500 cases with at least 35% false-fire negatives", .enabled(if: PrivateFiles.present("Evals/actions-tools-dev.json"), "needs a private file: Evals/actions-tools-dev.json"))
    func devSetShape() throws {
        let dev = try Self.loadDev()
        #expect(dev.split == "dev")
        #expect((480...560).contains(dev.cases.count))
        let negatives = dev.cases.filter(\.isNegative).count
        #expect(Double(negatives) / Double(dev.cases.count) >= 0.35)
        let falseFire = dev.cases.filter { $0.category == .falseFire }.count
        #expect(Double(falseFire) / Double(dev.cases.count) >= 0.35)
    }

    @Test("the dev set covers every category, every tool, both locales and the key phrasing tags", .enabled(if: PrivateFiles.present("Evals/actions-tools-dev.json"), "needs a private file: Evals/actions-tools-dev.json"))
    func devSetCoverage() throws {
        let dev = try Self.loadDev()
        #expect(Set(dev.cases.map(\.category)) == Set(ToolEvalCategory.allCases))
        #expect(Set(dev.cases.map(\.expect.tool)) == Set(VoiceToolCatalog.names))
        let indian = dev.cases.filter { $0.context.locale == "en_IN" }.count
        #expect(Double(indian) / Double(dev.cases.count) >= 0.25)
        let tags = Set(dev.cases.flatMap(\.tags))
        for tag in ["prepone", "lakh-crore", "day-first-date"] { #expect(tags.contains(tag), "missing \(tag)") }
        let decisions = Set(dev.cases.map(\.expect.decision))
        #expect(decisions == [.call, .noAction, .refuse])
        #expect(dev.cases.contains { $0.expect.split != nil })
    }

    @Test("every dev utterance is ASR-shaped and unique; every expected call is schema-valid", .enabled(if: PrivateFiles.present("Evals/actions-tools-dev.json"), "needs a private file: Evals/actions-tools-dev.json"))
    func devSetCases() throws {
        let dev = try Self.loadDev()
        #expect(Set(dev.cases.map(\.utterance)).count == dev.cases.count)
        #expect(dev.problems().isEmpty)
        for item in dev.cases where item.expect.decision == .call {
            #expect(item.expect.call.validationIssues().isEmpty, "\(item.id)")
        }
    }

    @Test("the request-intent dev set loads: polite requests (some punctuated like real transcripts) and lookalike negatives", .enabled(if: PrivateFiles.present("Evals/actions-intent-dev.json"), "needs a private file: Evals/actions-intent-dev.json"))
    func intentSetShape() throws {
        let url = Self.packageRoot.appendingPathComponent("Evals/actions-intent-dev.json")
        let intent = try ToolEvalSet.load(url, access: .tuning(purpose: "test"))
        #expect(intent.split == "dev")
        #expect(intent.problems().isEmpty)
        let negatives = intent.cases.filter(\.isNegative)
        #expect(intent.cases.count - negatives.count >= 35)
        #expect(negatives.count >= 30)
        // The shipping gate sees "?" and capitals; the set has to include them.
        let punctuated = intent.cases.filter { $0.tags.contains(ToolEvalCase.punctuatedTag) }
        #expect(punctuated.count >= 20)
        for item in punctuated {
            let hasMarks = item.utterance.contains { ".?".contains($0) }
            #expect(hasMarks || item.utterance != item.utterance.lowercased(), "\(item.id) is tagged punctuated but is bare")
        }
        // Reminders without a time are valid requests too (tools-v1 has no event without a start).
        #expect(intent.cases.contains { $0.tags.contains("no-time") && $0.expect.tool == "create_reminder" })
        // None of it is also in the main dev set (the cases are invented, not copied).
        let main = try Self.loadDev()
        #expect(Set(intent.cases.map { $0.utterance.lowercased() }).isDisjoint(with: Set(main.cases.map { $0.utterance.lowercased() })))
    }

    @Test("an unpunctuated-ASR case with capitals or a question mark is still rejected unless tagged punctuated")
    func punctuationNeedsTheTag() throws {
        let raw = Self.validCase.replacingOccurrences(of: "\"utterance\":\"remind me", with: "\"utterance\":\"Remind me?")
        let untagged = try write(set(raw))
        #expect(throws: (any Error).self) { _ = try ToolEvalSet.load(untagged, access: .tuning(purpose: "test")) }
        let tagged = try write(set(raw.replacingOccurrences(of: "\"tags\":[]", with: "\"tags\":[\"punctuated\"]")))
        _ = try ToolEvalSet.load(tagged, access: .tuning(purpose: "test"))
    }

    @Test("a valid minimal file loads")
    func minimal() throws {
        let url = try write(set(Self.validCase))
        let loaded = try ToolEvalSet.load(url, access: .tuning(purpose: "test"))
        #expect(loaded.cases.first?.expect.args["when"] == .string("2026-10-06T09:00:00+05:30"))
        #expect(loaded.cases.first?.context.promptLine() == "Now: Monday 2026-10-05 10:15 (Asia/Kolkata). Locale: en_IN. Frontmost app: Slack.")
    }

    @Test("invalid cases are rejected with readable problems")
    func invalid() throws {
        let bad = [
            (Self.validCase.replacingOccurrences(of: "remind me", with: "Remind me,"), "lowercase"),
            (Self.validCase.replacingOccurrences(of: "\"en_IN\"", with: "\"en_GB\""), "locale"),
            (Self.validCase.replacingOccurrences(of: "Asia/Kolkata\",\"locale", with: "Mars/Base\",\"locale"), "time zone"),
            (Self.validCase.replacingOccurrences(of: "\"create_reminder\"", with: "\"send_money\""), "unknown tool"),
            (Self.validCase.replacingOccurrences(of: "\"title\":\"call the plumber\",", with: ""), "missing title"),
            (Self.validCase.replacingOccurrences(of: "\"decision\":\"call\"", with: "\"decision\":\"refuse\""), "needs tool no_action"),
        ]
        for (json, expected) in bad {
            let url = try write(set(json))
            do {
                _ = try ToolEvalSet.load(url, access: .tuning(purpose: "test"))
                Issue.record("accepted a case with a \(expected) problem")
            } catch {
                #expect(error.localizedDescription.contains(expected), "\(error.localizedDescription)")
            }
        }
        let duplicate = try write(set(Self.validCase + "," + Self.validCase))
        #expect(throws: (any Error).self) { _ = try ToolEvalSet.load(duplicate, access: .tuning(purpose: "test")) }
        let wrongCatalog = try write(set(Self.validCase).replacingOccurrences(of: "tools-v1", with: "tools-v0"))
        #expect(throws: (any Error).self) { _ = try ToolEvalSet.load(wrongCatalog, access: .tuning(purpose: "test")) }
    }

    @Test("the loader refuses sealed names on tuning paths and non-pinned files on the held-out path")
    func guardOnLoad() throws {
        let sealedName = try write(set(Self.validCase), name: "actions-heldout.json")
        #expect(throws: SealedEvalGuard.Refusal.self) { _ = try ToolEvalSet.load(sealedName, access: .tuning(purpose: "test")) }
        #expect(throws: SealedEvalGuard.Refusal.self) { _ = try ToolEvalSet.load(Self.devURL, access: .sealedHeldout) }
    }

    @Test("murmur-eval refuses sealed paths in any argument except tools --heldout")
    func argumentGuard() throws {
        func args(_ items: String...) -> Arguments { Arguments(ArraySlice(items)) }
        #expect(throws: SealedEvalGuard.Refusal.self) { try args("tools", "--dataset", "Evals/actions-heldout.json").refuseSealedPaths() }
        #expect(throws: SealedEvalGuard.Refusal.self) { try args("actions", "--dataset", "x/actions-heldout.json").refuseSealedPaths() }
        #expect(throws: SealedEvalGuard.Refusal.self) {
            try args("judge", "--golden", "Evals/dictation-golden.json,Evals/actions-heldout.json").refuseSealedPaths()
        }
        #expect(throws: SealedEvalGuard.Refusal.self) { try args("cleanup", "heldout-v2.json").refuseSealedPaths() }
        #expect(throws: SealedEvalGuard.Refusal.self) { try args("actions", "--heldout", "actions-heldout.json").refuseSealedPaths() }
        #expect(throws: Never.self) { try args("tools", "--heldout", "/tmp/actions-heldout.json", "--backend", "none").refuseSealedPaths() }
        #expect(throws: Never.self) { try args("tools", "--dataset", "Evals/actions-tools-dev.json").refuseSealedPaths() }
    }
}
