import CryptoKit
import Foundation
import Testing
@testable import HushyModelsMLX
@testable import MurmurCore

@Suite("Intent cleanup prompt")
struct IntentPromptTests {
    @Test("intent model receives the current system and whole-transcript user turn")
    func exactPrompt() {
        let hash = SHA256.hash(data: Data(IntentCleanupPrompt.system.utf8))
            .map { String(format: "%02x", $0) }.joined()
        #expect(IntentCleanupPrompt.version == "intent-call-v4")
        #expect(hash == "afb865635942e6ec871dc039cb04ec05dcc67e3e0b5f738a7c13c73985f4a2d3")
        #expect(IntentCleanupPrompt.user(transcript: "First. Second.") == "Transcript: First. Second.\nOutput:")
        #expect(MLXLanguageModel.systemText(instructions: "Level: Clean", schema: SmartCleaner.cleanedSchema, profile: .intent)
            == IntentCleanupPrompt.system)
    }

    @Test("Cleaned JSON parses; the 2B compact prompt remains its own")
    func jsonAndCompact() throws {
        let answer = try JSONDecoder().decode(SmartCleaner.Cleaned.self, from: Data(#"{"text":"The final message."}"#.utf8))
        #expect(answer.text == "The final message.")
        let instructions = SmartCleaner.cleanupInstructions(confidenceGuided: false)
        #expect(MLXLanguageModel.systemText(instructions: instructions, schema: SmartCleaner.cleanedSchema, profile: .compact)
            == CompactCleanupPrompt.systemText(level: .clean))
        #expect(ModelRegistry.entry(id: ModelRegistry.hushyCleanup2B)?.promptProfile == .compact)
    }
}

@Suite("Intent cleanup prompt register variants")
struct IntentPromptRegisterTests {
    private func sha(_ text: String) -> String {
        SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    @Test("the system prompt with each register line has a fixed hash; none is today's v4 prompt")
    func registerHashes() {
        #expect(IntentCleanupPrompt.version == "intent-call-v4")
        #expect(sha(IntentCleanupPrompt.system(register: nil)) == "afb865635942e6ec871dc039cb04ec05dcc67e3e0b5f738a7c13c73985f4a2d3")
        #expect(sha(IntentCleanupPrompt.system(register: .casual)) == "8bf34c8694bdc3c0b0b2176c5487ad924eb173e6069443a2d539523850adeb99")
        #expect(sha(IntentCleanupPrompt.system(register: .professional)) == "4470829f0cf695d6c1a4e5d8e83ec9ac807365fd28a3e8d4d829367936d72e2d")
        #expect(sha(IntentCleanupPrompt.system(register: .prompt)) == "40538e9f525e5474150297689af80315964b7bf40ba55fa7fd98c21d1ad2bd38")
    }

    @Test("the model sees the register line when the instructions carry it, and today's prompt otherwise")
    func systemTextFollowsInstructions() {
        let plain = SmartCleaner.cleanupInstructions(confidenceGuided: false)
        #expect(MLXLanguageModel.systemText(instructions: plain, schema: SmartCleaner.cleanedSchema, profile: .intent)
            == IntentCleanupPrompt.system)
        for register in IntentRegister.allCases {
            #expect(MLXLanguageModel.systemText(
                instructions: plain + "\n" + register.line, schema: SmartCleaner.cleanedSchema, profile: .intent)
                == IntentCleanupPrompt.system(register: register))
        }
    }
}
