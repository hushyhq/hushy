import Testing
@testable import murmur_eval

@Suite struct MemoryProbeTests {
    @Test func inventedDraftHasExactRequestedWordCount() {
        for count in [24, 150, 200] {
            #expect(MemoryProbe.draft(words: count).split(separator: " ").count == count)
        }
    }
}
