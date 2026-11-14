import Testing
@testable import MurmurCore

@Suite("AmericanSpelling")
struct AmericanSpellingTests {
    @Test("British spellings become American, keeping case", arguments: [
        ("The colour of the programme was grey.", "The color of the program was gray."),
        ("Colour matters. Organisation too.", "Color matters. Organization too."),
        ("We cancelled the travelling budget.", "We canceled the traveling budget."),
        ("I'm reorganising the favourite list.", "I'm reorganizing the favorite list."),
        ("PROGRAMME update", "PROGRAM update"),
        ("- Centre stage\n- Theatre tickets", "- Center stage\n- Theater tickets"),
    ])
    func rewrites(input: String, expected: String) {
        #expect(AmericanSpelling.apply(input) == expected)
    }

    @Test("names and words American English also spells this way are left alone", arguments: [
        "Order the Earl Grey from Lincoln Centre.",
        "Keep the dialogue short and the aesthetic clean.",
        "Burn it to a disc.",
        "Nothing British here at all.",
    ])
    func leavesAlone(input: String) {
        #expect(AmericanSpelling.apply(input) == input)
    }

    @Test func offByDefaultAndOnlyAtCleanWhenEnabled() {
        let text = "The colour is fine."
        #expect(TextCleaner(options: CleanupOptions()).clean(text).text.contains("colour"))
        #expect(TextCleaner(options: CleanupOptions(americanSpelling: true)).clean(text).text.contains("color"))
        #expect(TextCleaner(options: CleanupOptions(level: .verbatim, americanSpelling: true)).clean(text).text.contains("colour"))
        #expect(TextCleaner(options: CleanupOptions(isCodeContext: true, americanSpelling: true)).clean(text).text.contains("colour"))
    }

    @Test func curatedListDropsOnlyTheKeepList() {
        #expect(AmericanSpelling.map.count == BritishAmericanSpellings.map.count
            - AmericanSpelling.keepAsIs.filter { BritishAmericanSpellings.map[$0] != nil }.count)
        #expect(AmericanSpelling.map["dialogue"] == nil)
        #expect(AmericanSpelling.map["colour"] == "color")
    }
}
