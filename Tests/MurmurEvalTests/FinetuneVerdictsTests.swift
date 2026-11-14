import Foundation
import MurmurCore
import Testing

@testable import murmur_eval

@Suite("finetune verdicts and the release route: the app's own options for the row's destination")
struct FinetuneVerdictsTests {
    @Test("verdict rows accept prose paragraphs only when requested")
    func paragraphVerdict() {
        let raw = "We finished the report this morning. The team reviewed every section before lunch."
        let target = "We finished the report this morning.\n\nThe team reviewed every section before lunch."
        let row: FinetuneJSONL.Row = ["raw": raw, "target": target]
        let route = ReleaseRoute(bundleID: "com.apple.mail")
        #expect(FinetuneVerdicts.verdictRow(row, route: route)["rejection"] as? String == "list-without-signal")
        #expect(FinetuneVerdicts.verdictRow(row, route: route, allowingParagraphBreaks: true)["rejection"] is NSNull)
    }

    @Test("the verdicts command forwards its paragraph flag")
    func paragraphVerdictCommand() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let input = directory.appendingPathComponent("pairs.jsonl").path
        let output = directory.appendingPathComponent("verdicts.jsonl").path
        try FinetuneJSONL.write([["id": "p", "raw": "We finished the report this morning. The team reviewed every section before lunch.",
                                  "target": "We finished the report this morning.\n\nThe team reviewed every section before lunch."]], to: input)
        try FinetuneVerdicts.run(Arguments(ArraySlice(["finetune", "verdicts", "--in", input, "--out", output,
                                                       "--allow-paragraph-breaks"])))
        let rows = try FinetuneJSONL.read(output)
        #expect(rows.count == 1 && rows[0]["rejection"] is NSNull)
    }
    private let claude = "com.anthropic.claudefordesktop"
    private let slack = "com.apple.MobileSMS"
    private let terminal = "com.apple.Terminal"

    @Test("the route is what forDictation gives: Polished, a code context only for a code editor, none for an AI app")
    func routes() {
        let agent = ReleaseRoute(bundleID: claude)
        #expect(agent.options.level == .polished && !agent.options.isCodeContext)
        #expect(ReleaseRoute(bundleID: terminal).options.isCodeContext)
        let chat = ReleaseRoute(bundleID: slack)
        #expect(chat.options.level == .polished && chat.options.isCasualContext && !chat.options.isCodeContext)
        #expect(ReleaseRoute(bundleID: claude, asSpoken: true).options.level == .verbatim)
    }

    @Test("groups with a bundle use the release options: a spoken file name is written as code in a code editor, not for the AI app or in a personal chat")
    func groupsFollowTheRoute() {
        let row: FinetuneJSONL.Row = ["id": "a", "text": "look at auth dot swift first"]
        let agent = FinetuneGroups.groupRow(row, options: ReleaseRoute(bundleID: terminal).options, textKey: "text", route: nil)
        let prompt = FinetuneGroups.groupRow(row, options: ReleaseRoute(bundleID: claude).options, textKey: "text", route: nil)
        let chat = FinetuneGroups.groupRow(row, options: ReleaseRoute(bundleID: slack).options, textKey: "text", route: nil)
        let agentDraft = (agent["groups"] as? [[String: Any]])?.first?["draft"] as? String ?? ""
        let chatDraft = (chat["groups"] as? [[String: Any]])?.first?["draft"] as? String ?? ""
        let promptDraft = (prompt["groups"] as? [[String: Any]])?.first?["draft"] as? String ?? ""
        #expect(agentDraft.contains("auth.swift"))
        #expect(!chatDraft.contains("auth.swift") && !promptDraft.contains("auth.swift"))
    }

    @Test("a plain pair is judged exactly; where the app context changes the draft the verdict says it is approximate")
    func verdicts() {
        let agent = ReleaseRoute(bundleID: claude)
        let work = ReleaseRoute(bundleID: "com.tinyspeck.slackmacgap")
        let plain = FinetuneVerdicts.verdictRow(["id": "p", "raw": "we need twenty five chairs", "target": "We need 25 chairs."],
                                                route: agent)
        #expect(plain["pairCheckDraftMatchesReleaseDraft"] as? Bool == true && plain["rejection"] is NSNull)
        let code = FinetuneVerdicts.verdictRow(
            ["id": "c", "raw": "please review pr four eighty two first", "target": "Please review PR 482 first."], route: work)
        #expect(code["pairCheckDraftMatchesReleaseDraft"] as? Bool == false)
        // The draft of an approximation is reported either way (the release draft passed as raw may be written again).
        #expect(code["approxDraftReproduced"] is Bool && code["approxRejection"] != nil)
        #expect(code["releaseDraft"] as? String != code["ownDraft"] as? String)
        #expect(FinetuneVerdicts.verdictRow(["id": "m"], route: agent)["error"] as? String == "missing raw/target")
    }

    @Test("a changed factual value is rejected by the pair check")
    func rejectedPair() {
        let row = FinetuneVerdicts.verdictRow(
            ["id": "reject", "raw": "We need 25 chairs.", "target": "We need 50 chairs."],
            route: ReleaseRoute(bundleID: claude))
        #expect(row["rejection"] is String)
        let malformed = FinetuneVerdicts.verdictRow(["id": "missing"], route: ReleaseRoute(bundleID: claude))
        let counts = FinetuneVerdicts.counts([row, malformed])
        #expect(counts.checked == 1)
        #expect(counts.malformed == 1)
        #expect(counts.rejected == 1)
    }
}
