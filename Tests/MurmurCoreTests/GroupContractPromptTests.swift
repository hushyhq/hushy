import CryptoKit
import Foundation
import Testing
@testable import MurmurCore

@Suite("CompactCleanupPrompt group contract")
struct GroupContractPromptTests {
    private struct ContextRow: Decodable { let previous: String?; let context: String }
    private struct Turn: Decodable { let role: String; let content: String }
    private struct GroupRow: Decodable { let previous: String?; let draft: String; let messages: [Turn] }

    private func fixture<T: Decodable>(_ name: String, as type: T.Type = T.self) throws -> T {
        let url = URL(fileURLWithPath: "Tests/MurmurCoreTests/Fixtures/\(name)")
        return try JSONDecoder().decode(type, from: Data(contentsOf: url))
    }

    @Test func pythonLeftContextFixture() throws {
        let rows: [ContextRow] = try fixture("group-left-context.json")
        #expect(rows.count >= 25)
        for row in rows {
            #expect(CompactCleanupPrompt.leftContext(previousDraft: row.previous) == row.context)
        }
    }

    @Test func pythonGroupRowsFixture() throws {
        let rows: [GroupRow] = try fixture("group-rows.json")
        #expect(rows.count >= 10)
        let file = try String(contentsOfFile: "Evals/finetune-prompts/group-call-system.txt", encoding: .utf8)
        let system = try #require(file.components(separatedBy: "--- system turn ---\n").dropFirst().first?
            .components(separatedBy: "\n--- user turn ---").first?.trimmingCharacters(in: .whitespacesAndNewlines))
        #expect(CompactCleanupPrompt.systemText(level: .clean, version: .groupContract) == system)
        for row in rows {
            #expect(row.messages[0].content == system)
            #expect(CompactCleanupPrompt.groupUserPrompt(draft: row.draft, previousDraft: row.previous) == row.messages[1].content)
        }
    }

    @Test func answerParsingDefaultsAndMissingText() throws {
        let decoder = JSONDecoder()
        for json in [#"{"text":"hello"}"#, #"{"text":"hello","new_paragraph":"yes"}"#,
                     #"{"text":"hello","new_paragraph":null}"#] {
            let answer = try decoder.decode(SmartCleaner.GroupCleaned.self, from: Data(json.utf8))
            #expect(answer.text == "hello")
            #expect(!answer.newParagraph)
        }
        let trueAnswer = try decoder.decode(SmartCleaner.GroupCleaned.self,
                                            from: Data(#"{"text":"hello","new_paragraph":true}"#.utf8))
        #expect(trueAnswer.newParagraph)
        let reordered = try decoder.decode(SmartCleaner.GroupCleaned.self,
            from: Data(#"{"new_paragraph":true,"extra":4,"text":"hello\nworld"}"#.utf8))
        #expect(reordered.newParagraph)
        #expect(reordered.text == "hello\nworld")
        #expect(throws: Error.self) {
            try decoder.decode(SmartCleaner.GroupCleaned.self, from: Data(#"{"text":"hello""#.utf8))
        }
        #expect(throws: Error.self) {
            try decoder.decode(SmartCleaner.GroupCleaned.self, from: Data(#"{"new_paragraph":true}"#.utf8))
        }
    }

    @Test func shippedPromptOracle() {
        // These digests describe the off-path prompt source at commit f829321d, before the group contract.
        let expected: [String: String] = [
            "compact-v2/verbatim": "ad765d8c34d191b3a581a9cdeb8246afb331f948a3d5bb230d4ff5eccbc1b655",
            "compact-v2/clean": "ad765d8c34d191b3a581a9cdeb8246afb331f948a3d5bb230d4ff5eccbc1b655",
            "compact-v2/polished": "5dac2e05957fd5b2a2c5e25ea600bfd33bdf4aba479a724db5ad26199fbf8445",
            "compact-v3/verbatim": "aa8b4efc30c4e4bd1c21218558a262eb0a03bcc270a12df5cf4a99de1d6ea977",
            "compact-v3/clean": "aa8b4efc30c4e4bd1c21218558a262eb0a03bcc270a12df5cf4a99de1d6ea977",
            "compact-v3/polished": "5dac2e05957fd5b2a2c5e25ea600bfd33bdf4aba479a724db5ad26199fbf8445",
            "compact-v4/verbatim": "073bbb768b0ef227d191138027f65be4f3035bd096f800075d96c6932f016d4e",
            "compact-v4/clean": "073bbb768b0ef227d191138027f65be4f3035bd096f800075d96c6932f016d4e",
            "compact-v4/polished": "5dac2e05957fd5b2a2c5e25ea600bfd33bdf4aba479a724db5ad26199fbf8445",
            "compact-v4-polished-bridge/verbatim": "0b0317dfbb8fe141af313aa1cec76180fd6c716e7cb7429efbc894691ff6729e",
            "compact-v4-polished-bridge/clean": "0b0317dfbb8fe141af313aa1cec76180fd6c716e7cb7429efbc894691ff6729e",
            "compact-v4-polished-bridge/polished": "5dac2e05957fd5b2a2c5e25ea600bfd33bdf4aba479a724db5ad26199fbf8445",
            "compact-v2-context/verbatim": "3e5c98de01b14ba3e46e5f3b156baeedb1221db79afa6e1bfcb10aebd17c63a6",
            "compact-v2-context/clean": "3e5c98de01b14ba3e46e5f3b156baeedb1221db79afa6e1bfcb10aebd17c63a6",
            "compact-v2-context/polished": "69de8843e35782d53a239cf27abafa0b5ba1a58c18294aee948d0039fbc79d82",
            "compact-v2-paragraphs/verbatim": "a46171fb78f30ab6a20860b546b3552a2c6453dad756e2331b7bb0532a7c4d43",
            "compact-v2-paragraphs/clean": "a46171fb78f30ab6a20860b546b3552a2c6453dad756e2331b7bb0532a7c4d43",
            "compact-v2-paragraphs/polished": "4a21b7d5aa43489bd7e4472d6ed657519a7693a498101349a4fddef7c032b79a",
        ]
        let draft = "A fixed draft: café, 12:30, and a quote \"hello\"."
        for version in CompactCleanupPrompt.Version.allCases where version != .groupContract {
            for level in [CleanupLevel.verbatim, .clean, .polished] {
                let value = CompactCleanupPrompt.systemText(level: level, version: version)
                let digest = SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
                #expect(digest == expected["\(version.rawValue)/\(level.rawValue)"])
            }
        }
        let userDigest = SHA256.hash(data: Data(CompactCleanupPrompt.userPrompt(draft: draft).utf8))
            .map { String(format: "%02x", $0) }.joined()
        #expect(userDigest == "fed3af36807c4e86a15902c6d82bf294ae666d38e37b935d4d812087a4756503")
    }

    @Test func malformedModelJSONFailsCall() async {
        let result = await SmartCleaner.askGroup(model: MalformedGroupModel(), draft: "Hello.",
            previousDraft: nil, budget: .seconds(1))
        guard case .failure = result else {
            Issue.record("Malformed model JSON must fail the call")
            return
        }
    }
}

private struct MalformedGroupModel: LanguageModel {
    var identifier: String { "malformed-group" }
    var availability: LanguageModelAvailability { .available }
    func supportsLanguage(_ languageCode: String) -> Bool { true }
    func prewarm(instructions: String) {}
    func prefixCache(instructions: String) async {}
    func respond(instructions: String, prompt: String, schema: GenerationSchemaSpec,
        options: LanguageModelOptions) async throws -> String { #"{"text":"Hello.""# }
}
