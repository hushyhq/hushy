import Testing
@testable import MurmurCore

/// Number reading in meeting lines must never trap on what a transcript or a typed note holds.
@Suite("Meeting words numbers")
struct MeetingWordsTests {
    @Test("huge or non-numeric scaled tokens stay as written",
          arguments: ["99999999999999999999k", "1e400", "9223372036854775807m", "1e40k", "infk", "nanm", "0x10k"])
    func hugeScaledTokenStaysUnchanged(_ token: String) {
        #expect(MeetingWords.canonicalTokens("price is \(token) today") == ["price", "is", token, "today"])
    }

    @Test("a spoken multiplier that would overflow leaves both words as said")
    func overflowingMultiplierStaysUnchanged() {
        #expect(MeetingWords.canonicalTokens("9223372036854775807 thousand") == ["9223372036854775807", "thousand"])
        #expect(MeetingWords.canonicalTokens("9223372036854775807 million users").contains("million"))
    }

    @Test("ordinary amounts still scale")
    func ordinaryAmountsScale() {
        #expect(MeetingWords.scaled("4k") == "4000")
        #expect(MeetingWords.scaled("1.5m") == "1500000")
        #expect(MeetingWords.canonicalTokens("four thousand a month") == ["4000", "a", "month"])
        #expect(MeetingWords.scaled("k") == nil)
        #expect(MeetingWords.scaled(".5k") == nil)
    }

    @Test("a model line that restates the person's own line is dropped, the person's wording kept")
    func repeats() {
        #expect(MeetingWords.withoutRepeats(["who signs security at Acme?", "Who signs off on security at Acme?", "Is the EU team in?"])
            == ["who signs security at Acme?", "Is the EU team in?"])
    }
}
