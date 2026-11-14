import Foundation
import Testing

@testable import MurmurCore

@Suite("Dictation tone")
struct DictationToneTests {
    @Test("the three tones come in the order the picker shows them, Refined first")
    func order() {
        #expect(DictationTone.allCases == [.refined, .casual, .professional])
    }

    @Test("titles are the words people see")
    func titles() {
        #expect(DictationTone.refined.title == "Refined")
        #expect(DictationTone.casual.title == "Casual")
        #expect(DictationTone.professional.title == "Professional")
    }

    @Test("every tone has a one-line detail in plain words")
    func details() {
        for tone in DictationTone.allCases {
            #expect(!tone.detail.isEmpty)
            #expect(!tone.detail.contains("\n"))
            #expect(tone.detail.count <= 90, "\(tone.rawValue): \(tone.detail)")
        }
        #expect(Set(DictationTone.allCases.map(\.detail)).count == 3)
    }

    @Test("each tone reuses an existing layout style")
    func formattingStyle() {
        #expect(DictationTone.refined.formattingStyle == .formal)
        #expect(DictationTone.casual.formattingStyle == .casual)
        #expect(DictationTone.professional.formattingStyle == .formal)
    }

    @Test("identifiers and stored values are stable")
    func identity() throws {
        #expect(DictationTone.allCases.map(\.id) == ["refined", "casual", "professional"])
        let data = try JSONEncoder().encode(DictationTone.casual)
        #expect(String(decoding: data, as: UTF8.self) == "\"casual\"")
        #expect(try JSONDecoder().decode(DictationTone.self, from: Data("\"professional\"".utf8)) == .professional)
    }
}
