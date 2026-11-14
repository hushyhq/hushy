import Testing
@testable import MurmurCore

/// A credential or ID keyword followed by its value, whatever the value's token shape: the
/// fine-tune data builders (2026-09-28) found word-first secrets ("the wifi password is orange
/// kite 51") and ASR-shaped values ("my pin is 5 1 5 9", "sk live 1234…") passing the screen.
/// Cases written from scratch.
@Suite("SensitiveContentScreen: keyword + value")
struct SensitiveKeywordValueTests {
    @Test("flags a secret introduced by its keyword", arguments: [
        "the wifi password is orange kite 51",
        "text sam my password is maple syrup 42",
        "save a note the router passcode is blue heron 9",
        "the login is falcon 2207",
        "my debit card pin is 4 0 7 2",
        "the atm pin is 9 3 1 6",
        "the door code is 7 7 1 2",
        "the gate code is 2468",
        "the code is 4 4 1 9",
        "remind me the garage code is 5 5 0 1",
        "my social security number is 512 33 0981",
        "email kim my ssn 208 71 4432",
        "my aadhaar number is 5093 2211 8740",
        "my passport number is k7254410",
        "send ali the api key sk live 91kd83hs02",
        "our stripe secret key sk test 55190023",
    ])
    func flags(_ text: String) {
        #expect(SensitiveContentScreen.finding(in: text) != nil)
    }

    @Test("everyday sentences about passwords, pins and codes pass", arguments: [
        "the password reset email never arrived",
        "the code review is at 3",
        "the password is wrong again",
        "the password is at least 12 characters long",
        "the password is 8 characters",
        "the pin is 4 digits",
        "the code is ready for review at 5",
        "the code is on line 42",
        "the error code is 404",
        "the promo code is SPRING 20",
        "the login is down since 9",
        "my passport number is in the drawer",
        "the code is version 2 now",
        "the password is the same as last year 2023",
        "we changed the door code last week",
        "i forgot my pin again",
    ])
    func passes(_ text: String) {
        #expect(SensitiveContentScreen.finding(in: text) == nil)
    }
}
