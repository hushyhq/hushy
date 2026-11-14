import Testing
@testable import Murmur

@Suite("Voice and style navigation")
struct VoiceAndStyleNavigationTests {
    @Test("every section has a distinct title and a plain-language purpose")
    func sectionsExplainThemselves() {
        let tabs = VoiceAndStyleView.Tab.allCases
        #expect(tabs.count == 5)
        #expect(Set(tabs.map(\.title)).count == 5)
        #expect(tabs.allSatisfy { !$0.subtitle.isEmpty && !$0.symbol.isEmpty })
        #expect(VoiceAndStyleView.Tab.dictionary.subtitle.contains("words"))
        #expect(VoiceAndStyleView.Tab.snippets.subtitle.contains("phrases"))
    }

    @Test("section bar keeps titles readable in a 510-point content column")
    func compactSectionBar() {
        #expect(!VoiceAndStyleView.showsSectionSymbols(at: 510))
        #expect(VoiceAndStyleView.showsSectionSymbols(at: 700))
    }
}
