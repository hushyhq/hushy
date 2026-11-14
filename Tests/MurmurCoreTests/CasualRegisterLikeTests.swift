import Testing
@testable import MurmurCore

/// Hedge "like" is part of texting register: the rules keep it when the utterance carries texting
/// markers or the target is a chat app, and leave the call to the model; formal text still loses
/// it (founder policy, 2026-09-28). Cases written from scratch.
@Suite("Hedge like in casual register")
struct CasualRegisterLikeTests {
    @Test("texting markers keep hedge like", arguments: [
        ("gonna be there in like 20 mins", "Gonna be there in like 20 mins."),
        ("it was like literally the best show lol", "It was like literally the best show lol."),
        ("omg we like finally shipped it", "Omg we like finally shipped it."),
        ("like honestly idk what happened", "Like honestly idk what happened."),
        ("ngl that was like totally worth it", "Ngl that was like totally worth it."),
    ])
    func textingMarkersKeepLike(input: String, expected: String) {
        #expect(TextCleaner().clean(input).text == expected)
    }

    @Test("a chat-app target keeps hedge like without texting markers")
    func chatContextKeepsLike() {
        var options = CleanupOptions()
        options.isCasualContext = true
        #expect(TextCleaner(options: options).clean("we like finally shipped it").text == "We like finally shipped it.")
        #expect(TextCleaner(options: options).clean("spent like two hours on it").text.contains("like"))
    }

    @Test("formal register still drops hedge like", arguments: [
        ("It was like literally the best quarter we have had.", "It was literally the best quarter we have had."),
        ("We spent like two hours on the review.", "We spent two hours on the review."),
    ])
    func formalDropsLike(input: String, expected: String) {
        #expect(TextCleaner().clean(input).text == expected)
    }

    @Test("texting markers are whole words", arguments: [
        "The rnd budget is final.", "The lolly shop opens at 9.", "Gonnabe is not a word.",
    ])
    func markersAreWholeWords(input: String) {
        #expect(!TextingRegister.isCasual(input))
    }

    @Test("texting markers are recognised", arguments: [
        "gonna be late", "traffic is insane rn", "lol ok", "tbh not sure", "IDK", "wanna grab lunch",
    ])
    func markersRecognised(input: String) {
        #expect(TextingRegister.isCasual(input))
    }
}
