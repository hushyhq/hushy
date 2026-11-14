import Foundation
import MurmurCore
import Testing

@testable import murmur_eval

@Suite("Voice Lab gate 3")
struct VoiceLabGateTests {
    private func take(_ style: VoiceLabPrompt.Style, spoken: String, raw: String, dict: String? = nil) -> VoiceLabGate.Take {
        VoiceLabGate.Take(style: style, spoken: spoken, raw: raw, withDictionary: dict ?? raw)
    }

    @Test func splitsNormalAndNoisyFromWhisperAndAppliesLimits() {
        let takes = [
            take(.normal, spoken: "ship the release notes today", raw: "ship the release notes today"),
            take(.noisy, spoken: "call priya about the invoice", raw: "call pria about the invoice", dict: "call priya about the invoice"),
            take(.whisper, spoken: "do not merge until review is done", raw: "do not merge until review is gone"),
        ]
        let m = VoiceLabGate.measure(takes, dictionaryTerms: 1)
        #expect(m.normalNoisyCount == 2 && m.whisperCount == 1)
        #expect(abs(m.rawWER - 1.0 / 10.0) < 0.001)
        #expect(m.dictionaryWER == 0)
        #expect(abs(m.whisperWER - 1.0 / 7.0) < 0.001)
        #expect(!m.rawPasses)
        #expect(m.dictionaryPasses)
        #expect(!m.whisperPasses)
        #expect(!m.passes)
    }

    @Test func passesWhenEveryRateIsWithinItsLimit() {
        var takes: [VoiceLabGate.Take] = []
        for index in 0..<40 {
            takes.append(take(.normal, spoken: "word one two three four five", raw: index == 0 ? "word one two three four six" : "word one two three four five"))
        }
        takes.append(take(.whisper, spoken: "a b c d e f g h i j", raw: "a b c d e f g h i x"))
        let m = VoiceLabGate.measure(takes, dictionaryTerms: 0)
        #expect(m.rawPasses && m.dictionaryPasses && m.whisperPasses && m.passes)
    }

    @Test func noWhisperTakesIsUnmeasuredNotAFailure() {
        let m = VoiceLabGate.measure([take(.normal, spoken: "hello there", raw: "hello there")], dictionaryTerms: 0)
        #expect(m.whisperCount == 0 && m.whisperPasses && m.passes)
        #expect(VoiceLabGate.markdown(m).contains("unmeasured"))
    }

    @Test func spokenTextStripsTheStageDirectionLikeTheVoiceLabScreen() {
        let prompt = VoiceLabPrompt(
            id: "n-cmd-05", category: "command", style: .normal,
            prompt: "Say this exactly, keeping 'press enter' as literal text describing a UI action, not a command: To submit the form, press enter on your keyboard.",
            expected: "To submit the form, press enter on your keyboard.")
        #expect(VoiceLabGate.spokenText(of: prompt) == "To submit the form, press enter on your keyboard.")
        let bare = VoiceLabPrompt(id: "x", category: "plain", style: .normal, prompt: "No colon here.", expected: "No colon here.")
        #expect(VoiceLabGate.spokenText(of: bare) == "No colon here.")
    }

    @Test func dictionaryFileParsesTermsAndOptionalSoundsLike() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("dict-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        try #"[{"term": "Hushy", "soundsLike": ["hushi"]}, {"term": "Supabase"}, {"term": "  "}]"#.write(to: url, atomically: true, encoding: .utf8)
        let entries = try VoiceLabDictionaryFile.load(from: url)
        #expect(entries.map(\.term) == ["Hushy", "Supabase"])
        #expect(entries[0].soundsLike == ["hushi"] && entries[1].soundsLike.isEmpty)
    }
}
